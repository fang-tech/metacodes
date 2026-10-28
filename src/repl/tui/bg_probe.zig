//! 启动期终端探测:一轮往返问清背景色(OSC 11)与 Kitty 键盘协议(`CSI ? u`),DA1 作哨兵(#327)。
//!
//! 机制:进 raw(保留已到的输入)→ 一次写出 `[OSC 11 ?][CSI ? u] CSI c` → 读应答直到 DA1
//! 回来或超时 → 还原 termios。每个终端都答 DA1(primary device attributes),而终端按顺序应答:
//! DA1 到了还没见到 Kitty 应答,就是确定的"不支持",不用等超时;OSC 11 同理。超时(~120ms)
//! 只是兜底——应答在路上太久(慢 SSH)或终端什么都不答,结果是"不知道",调用方沿用旧默认。
//! 背景色:`\x1b]11;rgb:RRRR/GGGG/BBBB\x07`(或 ST `\x1b\\` 结尾)→ 解析高字节 → BT.601 亮度判明暗。
//!
//! 同一批字节里不是应答的(探测期间敲的键、粘贴的文字)原样交还 stdin
//! (platform.terminal.replayInput):输入 parser 照常读到它们,应答本身不会被当成按键。
//!
//! 谨慎:① 只在交互 tty 启动期调一次;② 超时短不拖慢启动;③ 还原 termios;
//! ④ 管道/NO_PROBE/非 tty 由调用方跳过(本模块也自带非 tty 守卫)。
const std = @import("std");
const builtin = @import("builtin");
const platform_term = @import("platform").terminal;
const pfs = @import("platform").fs;
const util_time = @import("../../util/time.zig");
const log = @import("../../util/log.zig");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// BT.601 相对亮度 > 128 → 浅色背景(对齐 metacode color.zig is_light)。
pub fn isLight(c: Rgb) bool {
    const y = 0.299 * @as(f32, @floatFromInt(c.r)) +
        0.587 * @as(f32, @floatFromInt(c.g)) +
        0.114 * @as(f32, @floatFromInt(c.b));
    return y > 128.0;
}

/// 解析 OSC 11 响应里的 `rgb:RRRR/GGGG/BBBB`(各通道 1-4 hex,取高 8 位)。
/// 找不到/格式错 → null。容忍前后包裹(ESC]11; 前缀、BEL/ST 后缀)。
pub fn parseOsc11(resp: []const u8) ?Rgb {
    const marker = "rgb:";
    const idx = std.mem.indexOf(u8, resp, marker) orelse return null;
    var rest = resp[idx + marker.len ..];
    var ch: [3]u8 = undefined;
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const seg = if (n < 2)
            (rest[0 .. slash orelse return null])
        else blk: {
            // 第三段:到非 hex 字符(BEL/ESC/\)或串尾。
            var e: usize = 0;
            while (e < rest.len and isHex(rest[e])) : (e += 1) {}
            break :blk rest[0..e];
        };
        if (seg.len == 0 or seg.len > 4) return null;
        const v16 = std.fmt.parseInt(u16, seg, 16) catch return null;
        // 通道值按 hex 位宽归一到 8 位:1位→<<4|x、2位→原、4位→取高字节。
        ch[n] = switch (seg.len) {
            1 => @intCast((v16 << 4) | v16),
            2 => @intCast(v16 & 0xFF),
            3 => @intCast(v16 >> 4),
            4 => @intCast(v16 >> 8),
            else => unreachable,
        };
        if (n < 2) rest = rest[(slash.?) + 1 ..];
    }
    return Rgb{ .r = ch[0], .g = ch[1], .b = ch[2] };
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// ============================================================================
// 一轮探测
// ============================================================================

/// The questions a round asks. DA1 is always asked last: it is the sentinel.
pub const Want = struct {
    background: bool = false,
    keyboard: bool = false,

    pub fn any(self: Want) bool {
        return self.background or self.keyboard;
    }
};

pub const osc11_query = "\x1b]11;?\x07";
/// Kitty progressive enhancement: "which flags are set?". A terminal that
/// speaks the protocol answers `CSI ? flags u`; one that does not ignores it.
pub const kitty_query = "\x1b[?u";
/// Primary device attributes. Every terminal answers, after everything asked before it.
pub const da1_query = "\x1b[c";

/// What a round writes for `want`: one write, so the answers come back in one burst.
pub fn queryFor(want: Want) []const u8 {
    if (want.background and want.keyboard) return osc11_query ++ kitty_query ++ da1_query;
    if (want.background) return osc11_query ++ da1_query;
    if (want.keyboard) return kitty_query ++ da1_query;
    return "";
}

/// Whether the terminal speaks the Kitty keyboard protocol.
pub const Keyboard = enum {
    /// It answered the flags query.
    supported,
    /// DA1 came back first: terminals answer in order, so it never will.
    unsupported,
    /// Not asked, or the round ended on its deadline before DA1.
    unknown,
};

pub const Result = struct {
    /// Null when not asked, not answered, or malformed.
    background: ?Rgb = null,
    keyboard: Keyboard = .unknown,
    /// DA1 ended the round, not the deadline.
    sentinel: bool = false,
};

/// Splits what the terminal sent during a round into its answers and the
/// rest. The rest — keys typed and text pasted while the round waited — keeps
/// its bytes and their order exactly, so handing it back to stdin leaves the
/// input parser a stream that looks as if no probe had run.
///
/// A byte is typed input unless it belongs to one of the answer shapes:
/// `ESC ] 11 ; … (BEL | ESC \)`, `ESC [ ? digits u` (Kitty flags) and
/// `ESC [ ? digits/semicolons c` (DA1). No key produces those: keys send
/// `ESC [` with no `?`, and Alt+] typed by hand is followed by anything but
/// `11;`. A sequence still open when the round ends is typed input as well.
pub const Scanner = struct {
    want: Want,
    result: Result = .{},
    state: State = .ground,
    /// The sequence begun with ESC, until it is known to be an answer or not.
    seq: [seq_capacity]u8 = undefined,
    seq_len: usize = 0,
    /// Every byte that was not an answer, in arrival order.
    typed: [typed_capacity]u8 = undefined,
    typed_len: usize = 0,

    const State = enum { ground, esc, csi, osc, osc_esc };
    /// Longer than any answer: Windows Terminal's DA1 is 42 bytes. A longer
    /// sequence is typed input (or an answer the input parser then skips).
    pub const seq_capacity = 128;
    pub const typed_capacity = platform_term.replay_capacity;
    const osc11_prefix = "11;";

    pub fn init(want: Want) Scanner {
        return .{ .want = want };
    }

    /// Each byte adds at most one to typed + seq, so `room` bytes always fit.
    pub fn room(self: *const Scanner) usize {
        return typed_capacity - self.typed_len - self.seq_len;
    }

    pub fn feed(self: *Scanner, bytes: []const u8) void {
        std.debug.assert(bytes.len <= self.room());
        for (bytes) |b| self.step(b);
    }

    /// Whether DA1 came back: every answer asked for has arrived.
    pub fn done(self: *const Scanner) bool {
        return self.result.sentinel;
    }

    /// The round is over: a sequence still open goes out as typed.
    pub fn finish(self: *Scanner) void {
        self.flushSeq();
    }

    pub fn typedBytes(self: *const Scanner) []const u8 {
        return self.typed[0..self.typed_len];
    }

    fn step(self: *Scanner, b: u8) void {
        switch (self.state) {
            .ground => if (b == 0x1b) self.begin() else self.type1(b),
            .esc => switch (b) {
                '[' => self.advance(b, .csi),
                ']' => self.advance(b, .osc),
                else => self.abort(b),
            },
            .csi => switch (b) {
                0x20...0x3f => self.advance(b, .csi), // parameters, intermediates
                0x40...0x7e => if (self.take(b)) self.endCsi() else self.abort(b),
                else => self.abort(b),
            },
            .osc => {
                const at = self.seq_len - 2; // bytes after `ESC ]`
                if (at < osc11_prefix.len) {
                    if (b == osc11_prefix[at]) self.advance(b, .osc) else self.abort(b);
                    return;
                }
                switch (b) {
                    0x07 => self.endOsc(),
                    0x1b => self.advance(b, .osc_esc),
                    0x20...0x7e => self.advance(b, .osc),
                    else => self.abort(b),
                }
            },
            .osc_esc => {
                if (b == '\\') return self.endOsc();
                // Not ST: the OSC was cut short. What came before the ESC was
                // typed; the ESC begins whatever follows.
                self.seq_len -= 1;
                self.flushSeq();
                self.begin();
                self.step(b);
            },
        }
    }

    fn type1(self: *Scanner, b: u8) void {
        self.typed[self.typed_len] = b;
        self.typed_len += 1;
    }

    fn begin(self: *Scanner) void {
        self.seq[0] = 0x1b;
        self.seq_len = 1;
        self.state = .esc;
    }

    fn take(self: *Scanner, b: u8) bool {
        if (self.seq_len == seq_capacity) return false;
        self.seq[self.seq_len] = b;
        self.seq_len += 1;
        return true;
    }

    fn advance(self: *Scanner, b: u8, next: State) void {
        if (!self.take(b)) return self.abort(b);
        self.state = next;
    }

    /// `b` cannot continue the open sequence: the sequence was typed, and `b`
    /// starts over from the ground state.
    fn abort(self: *Scanner, b: u8) void {
        self.flushSeq();
        self.step(b);
    }

    fn flushSeq(self: *Scanner) void {
        @memcpy(self.typed[self.typed_len..][0..self.seq_len], self.seq[0..self.seq_len]);
        self.typed_len += self.seq_len;
        self.seq_len = 0;
        self.state = .ground;
    }

    fn endCsi(self: *Scanner) void {
        const final = self.seq[self.seq_len - 1];
        const params = self.seq[2 .. self.seq_len - 1];
        const private = params.len >= 2 and params[0] == '?';
        if (private and final == 'u' and allIn(params[1..], "0123456789")) {
            if (self.want.keyboard) self.result.keyboard = .supported;
        } else if (private and final == 'c' and allIn(params[1..], "0123456789;")) {
            self.result.sentinel = true;
            if (self.want.keyboard and self.result.keyboard == .unknown) self.result.keyboard = .unsupported;
        } else return self.flushSeq();
        self.seq_len = 0;
        self.state = .ground;
    }

    fn endOsc(self: *Scanner) void {
        if (self.want.background) self.result.background = parseOsc11(self.seq[0..self.seq_len]);
        self.seq_len = 0;
        self.state = .ground;
    }
};

fn allIn(bytes: []const u8, set: []const u8) bool {
    for (bytes) |b| if (std.mem.indexOfScalar(u8, set, b) == null) return false;
    return true;
}

/// What a round's transport reports when it waits for the terminal.
pub const Wait = enum { readable, timeout, interrupted, closed };

/// One round over `io`: write the query for `want`, then read until DA1 or
/// until `deadline_ms` has passed. `io` is the terminal (`TerminalIo`) or a
/// scripted one in tests: `sendQuery([]const u8) bool`, `wait(timeout_ms: u32)
/// Wait`, `read([]u8) isize`, `nowMs() i64`.
///
/// Reading stops while the typed bytes would overflow what stdin can be
/// handed back: anything after that stays with the terminal, in order.
pub fn runRound(io: anytype, want: Want, deadline_ms: u32) Scanner {
    var scanner = Scanner.init(want);
    if (!want.any() or !io.sendQuery(queryFor(want))) return scanner;
    const start = io.nowMs();
    while (!scanner.done()) {
        const elapsed = io.nowMs() - start;
        if (elapsed >= deadline_ms) break;
        var chunk: [256]u8 = undefined;
        const limit = @min(chunk.len, scanner.room());
        if (limit == 0) break;
        switch (io.wait(@intCast(@as(i64, deadline_ms) - elapsed))) {
            .readable => {},
            // A signal (a resize) cut the wait short; the deadline still bounds the loop.
            .interrupted => continue,
            .timeout, .closed => break,
        }
        const n = io.read(chunk[0..limit]);
        if (n <= 0) break;
        scanner.feed(chunk[0..@intCast(n)]);
    }
    scanner.finish();
    return scanner;
}

/// The deadline when DA1 does not come back. A local terminal answers in well
/// under a millisecond (Windows Terminal through ConPTY: ~0.1 ms); this is
/// for slow links, and for a pseudo terminal with nothing behind it.
pub const budget_ms: u32 = 120;

const TerminalIo = struct {
    fd: c_int,

    pub fn sendQuery(self: *const TerminalIo, bytes: []const u8) bool {
        return pfs.writeAll(self.fd, bytes);
    }

    pub fn wait(self: *const TerminalIo, timeout_ms: u32) Wait {
        const rc = platform_term.waitReadable(self.fd, @intCast(timeout_ms));
        if (rc > 0) return .readable;
        if (rc == 0) return .timeout;
        return if (pfs.lastErrnoIs(.INTR)) .interrupted else .closed;
    }

    pub fn read(self: *const TerminalIo, buf: []u8) isize {
        return platform_term.readInput(self.fd, buf); // no EINTR: wait reported data
    }

    pub fn nowMs(_: *const TerminalIo) i64 {
        return util_time.nowMs();
    }
};

/// Ask the terminal what `want` names, in one round. The terminal is stdin's
/// when stdin is one (its answers arrive there, and so do keys typed
/// meanwhile, which go back to stdin), else stdout's, which is asked only for
/// its background: with no terminal on stdin no key reaches the REPL's parser.
/// No terminal, or nothing to ask → nothing known.
///
/// Windows console: not asked. Measured on Windows Terminal 1.24 under
/// Windows 11 26300: the console host (ConPTY) answers DA1 itself in about
/// 0.1 ms and never answers `CSI ? u`, not even after a push, so the keyboard
/// answer could only be "unsupported"; and the enable sequence, written to the
/// stdin descriptor, cannot reach a Windows console anyway. It does answer
/// OSC 11; the theme keeps its Windows default until that is wired.
pub fn probe(want: Want) Result {
    if (builtin.os.tag == .windows) return .{};
    var asked = want;
    const fd: c_int = if (platform_term.isatty(0)) 0 else 1;
    if (fd != 0) asked.keyboard = false;
    if (!asked.any() or !platform_term.isatty(fd)) return .{};
    const saved = platform_term.enterRawKeepingInput(fd) orelse return .{};
    defer platform_term.restoreModeKeepingInput(fd, saved);

    const started = util_time.nowNs();
    var io: TerminalIo = .{ .fd = fd };
    const round = runRound(&io, asked, budget_ms);
    if (fd == 0) platform_term.replayInput(0, round.typedBytes());
    log.debug("probe", "terminal answered in {d}us: sentinel={} keyboard={s} background={} typed={d}B", .{
        @divTrunc(util_time.nowNs() - started, std.time.ns_per_us),
        round.result.sentinel,
        @tagName(round.result.keyboard),
        round.result.background != null,
        round.typed_len,
    });
    return round.result;
}

// ============================================================================
// 测试
// ============================================================================
const testing = std.testing;

test "isLight: 黑→暗, 白→亮, 中灰边界" {
    try testing.expect(!isLight(.{ .r = 0, .g = 0, .b = 0 }));
    try testing.expect(isLight(.{ .r = 255, .g = 255, .b = 255 }));
    try testing.expect(!isLight(.{ .r = 30, .g = 30, .b = 30 })); // 典型暗终端
    try testing.expect(isLight(.{ .r = 240, .g = 240, .b = 240 })); // 典型亮终端
}

test "parseOsc11: 4-hex 各通道取高字节" {
    // 白:ffff/ffff/ffff → 255,255,255
    const w = parseOsc11("\x1b]11;rgb:ffff/ffff/ffff\x07").?;
    try testing.expectEqual(@as(u8, 255), w.r);
    try testing.expectEqual(@as(u8, 255), w.b);
    // 黑
    const b = parseOsc11("\x1b]11;rgb:0000/0000/0000\x1b\\").?;
    try testing.expectEqual(@as(u8, 0), b.r);
    // 典型暗背景 #1e1e1e → 1e1e/1e1e/1e1e
    const dark = parseOsc11("\x1b]11;rgb:1e1e/1e1e/1e1e\x07").?;
    try testing.expectEqual(@as(u8, 0x1e), dark.r);
    try testing.expect(!isLight(dark));
}

test "parseOsc11: 2-hex 通道" {
    const c = parseOsc11("rgb:ab/cd/ef").?;
    try testing.expectEqual(@as(u8, 0xab), c.r);
    try testing.expectEqual(@as(u8, 0xcd), c.g);
    try testing.expectEqual(@as(u8, 0xef), c.b);
}

test "parseOsc11: 畸形 → null" {
    try testing.expect(parseOsc11("garbage") == null);
    try testing.expect(parseOsc11("\x1b]11;rgb:zz/00/00\x07") == null);
    try testing.expect(parseOsc11("rgb:") == null);
}

const both: Want = .{ .background = true, .keyboard = true };

fn scan(want: Want, bytes: []const u8) Scanner {
    var s = Scanner.init(want);
    s.feed(bytes);
    return s;
}

test "queryFor: one write per round, DA1 last" {
    try testing.expectEqualStrings("\x1b]11;?\x07\x1b[?u\x1b[c", queryFor(both));
    try testing.expectEqualStrings("\x1b[?u\x1b[c", queryFor(.{ .keyboard = true }));
    try testing.expectEqualStrings("\x1b]11;?\x07\x1b[c", queryFor(.{ .background = true }));
    try testing.expectEqualStrings("", queryFor(.{}));
}

test "Scanner: a Kitty answer before DA1 is support; DA1 ends the round" {
    var s = scan(both, "\x1b]11;rgb:ffff/ffff/ffff\x1b\\\x1b[?0u\x1b[?62;22c");
    try testing.expect(s.done());
    try testing.expectEqual(Keyboard.supported, s.result.keyboard);
    try testing.expect(isLight(s.result.background.?));
    s.finish();
    try testing.expectEqualStrings("", s.typedBytes());
}

test "Scanner: DA1 without a Kitty answer is a definite no" {
    // Windows Terminal through ConPTY, as measured.
    const s = scan(.{ .keyboard = true }, "\x1b[?61;4;6;7;14;21;22;23;24;28;32;42;52c");
    try testing.expect(s.done());
    try testing.expectEqual(Keyboard.unsupported, s.result.keyboard);
    try testing.expect(s.result.background == null);
}

test "Scanner: an answer split across reads is still an answer" {
    var s = Scanner.init(both);
    const stream = "\x1b]11;rgb:1e1e/1e1e/2e2e\x07\x1b[?1u\x1b[?64;1c";
    for (0..stream.len) |i| {
        try testing.expect(!s.done());
        s.feed(stream[i .. i + 1]);
    }
    try testing.expect(s.done());
    try testing.expectEqual(Keyboard.supported, s.result.keyboard);
    try testing.expectEqual(@as(u8, 0x1e), s.result.background.?.r);
    try testing.expectEqualStrings("", s.typedBytes());
}

test "Scanner: keys typed between the answers keep their bytes and order" {
    // Text, an arrow key, Alt+x, a Kitty-encoded Shift+Enter, Enter and a
    // lone Esc, around and between the answers.
    var s = scan(both, "a\x1b]11;rgb:0/0/0\x07b\x1b[A\x1b[?1uc\x1bx\x1b[13;2u\r\x1b[?62c\x1b");
    try testing.expect(s.done());
    try testing.expectEqual(Keyboard.supported, s.result.keyboard);
    try testing.expectEqual(@as(u8, 0), s.result.background.?.r);
    s.finish();
    try testing.expectEqualStrings("ab\x1b[Ac\x1bx\x1b[13;2u\r\x1b", s.typedBytes());
}

test "Scanner: what only looks like the start of an answer is typed" {
    // Alt+] then text, Esc Esc, CSI with a private marker but another final,
    // a C0 control inside a sequence, an OSC that is not 11, an OSC 11 cut
    // short by another sequence.
    var s = scan(both, "\x1b]ab\x1b\x1b[?25h\x1b[?6\x03\x1b]10;x\x07\x1b]11;rgb\x1b[B");
    try testing.expect(!s.done());
    s.finish();
    try testing.expectEqualStrings("\x1b]ab\x1b\x1b[?25h\x1b[?6\x03\x1b]10;x\x07\x1b]11;rgb\x1b[B", s.typedBytes());
    try testing.expectEqual(Keyboard.unknown, s.result.keyboard);
    try testing.expect(s.result.background == null);
}

test "Scanner: an echo of the query itself is not an answer" {
    var s = scan(.{ .keyboard = true }, "\x1b[?u");
    s.finish();
    try testing.expectEqualStrings("\x1b[?u", s.typedBytes());
    try testing.expectEqual(Keyboard.unknown, s.result.keyboard);
}

test "Scanner: a sequence longer than any answer is typed, and room never runs out" {
    var s = Scanner.init(.{ .keyboard = true });
    var long: [Scanner.seq_capacity + 10]u8 = undefined;
    @memset(&long, '1');
    long[0] = 0x1b;
    long[1] = '[';
    long[2] = '?';
    s.feed(&long);
    s.feed("c");
    s.finish();
    try testing.expect(!s.done());
    try testing.expectEqual(long.len + 1, s.typed_len);
}

test "Scanner: a Kitty answer not asked for is consumed but proves nothing" {
    const s = scan(.{ .background = true }, "\x1b[?1u\x1b[?62c");
    try testing.expect(s.done());
    try testing.expectEqual(Keyboard.unknown, s.result.keyboard);
    try testing.expectEqualStrings("", s.typedBytes());
}

/// A terminal played from a script: `(at_ms, bytes)` arrive at their times.
/// Time moves only when the round waits, so every run is the same.
const ScriptedTerminal = struct {
    events: []const Event,
    next: usize = 0,
    offset: usize = 0,
    now: i64 = 0,
    written: [64]u8 = undefined,
    written_len: usize = 0,
    write_ok: bool = true,

    const Event = struct { at_ms: i64, bytes: []const u8 };

    pub fn sendQuery(self: *ScriptedTerminal, bytes: []const u8) bool {
        @memcpy(self.written[self.written_len..][0..bytes.len], bytes);
        self.written_len += bytes.len;
        return self.write_ok;
    }

    pub fn wait(self: *ScriptedTerminal, timeout_ms: u32) Wait {
        if (self.next == self.events.len) {
            self.now += timeout_ms;
            return .timeout;
        }
        const at = self.events[self.next].at_ms;
        if (at > self.now + timeout_ms) {
            self.now += timeout_ms;
            return .timeout;
        }
        self.now = @max(self.now, at);
        return .readable;
    }

    pub fn read(self: *ScriptedTerminal, buf: []u8) isize {
        const ev = self.events[self.next];
        const n = @min(buf.len, ev.bytes.len - self.offset);
        @memcpy(buf[0..n], ev.bytes[self.offset..][0..n]);
        self.offset += n;
        if (self.offset == ev.bytes.len) {
            self.next += 1;
            self.offset = 0;
        }
        return @intCast(n);
    }

    pub fn nowMs(self: *const ScriptedTerminal) i64 {
        return self.now;
    }

    /// Bytes the round left unread, in order.
    fn unread(self: *const ScriptedTerminal, out: []u8) []const u8 {
        var len: usize = 0;
        var i = self.next;
        var off = self.offset;
        while (i < self.events.len) : (i += 1) {
            const rest = self.events[i].bytes[off..];
            @memcpy(out[len..][0..rest.len], rest);
            len += rest.len;
            off = 0;
        }
        return out[0..len];
    }
};

test "runRound: a positive answer ends the round when DA1 arrives" {
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 2, .bytes = "\x1b]11;rgb:ffff/ffff/ffff\x07\x1b[?1u" },
        .{ .at_ms = 3, .bytes = "\x1b[?62c" },
    } };
    const round = runRound(&term, both, budget_ms);
    try testing.expectEqualStrings(queryFor(both), term.written[0..term.written_len]);
    try testing.expect(round.result.sentinel);
    try testing.expectEqual(Keyboard.supported, round.result.keyboard);
    try testing.expect(isLight(round.result.background.?));
    // Finished at DA1, not at the deadline.
    try testing.expectEqual(@as(i64, 3), term.now);
}

test "runRound: DA1 alone is a negative at once, not after the deadline" {
    var term: ScriptedTerminal = .{ .events = &.{.{ .at_ms = 1, .bytes = "\x1b[?62;22c" }} };
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.unsupported, round.result.keyboard);
    try testing.expectEqual(@as(i64, 1), term.now);
}

test "runRound: a late answer within the budget still counts" {
    // A slow link: the answers take 100 ms of the 120.
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 100, .bytes = "\x1b[?1u" },
        .{ .at_ms = 110, .bytes = "\x1b[?62c" },
    } };
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.supported, round.result.keyboard);
    try testing.expect(round.result.sentinel);
}

test "runRound: no DA1 by the deadline is unknown, and what came is kept" {
    // The Kitty answer would prove support, but this terminal never gets
    // that far before the deadline; a typed key arrives meanwhile.
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 30, .bytes = "x" },
        .{ .at_ms = 300, .bytes = "\x1b[?1u\x1b[?62c" },
    } };
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expect(!round.result.sentinel);
    try testing.expectEqual(Keyboard.unknown, round.result.keyboard);
    try testing.expectEqualStrings("x", round.typedBytes());
    try testing.expectEqual(@as(i64, budget_ms), term.now);
}

test "runRound: an answer still arriving at the deadline is handed back with the keys" {
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 5, .bytes = "h\x1b[?62;" },
        .{ .at_ms = 500, .bytes = "22c" },
    } };
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.unknown, round.result.keyboard);
    // The input parser skips an unknown CSI as a whole once its tail arrives.
    try testing.expectEqualStrings("h\x1b[?62;", round.typedBytes());
}

test "runRound: keys typed before, between and after the answers come back in order" {
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 0, .bytes = "he" },
        .{ .at_ms = 1, .bytes = "\x1b[?1ul" },
        .{ .at_ms = 2, .bytes = "l\x1b[?62co\x1b[" },
    } };
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.supported, round.result.keyboard);
    // The `ESC [` after DA1 is half an arrow key: it goes back as is and the
    // terminal's next bytes complete it.
    try testing.expectEqualStrings("hello\x1b[", round.typedBytes());
}

test "runRound: interrupted waits retry within the deadline; a closed terminal ends it" {
    const Flaky = struct {
        inner: ScriptedTerminal,
        interruptions: u8 = 2,
        pub fn sendQuery(self: *@This(), bytes: []const u8) bool {
            return self.inner.sendQuery(bytes);
        }
        pub fn wait(self: *@This(), timeout_ms: u32) Wait {
            if (self.interruptions > 0) {
                self.interruptions -= 1;
                self.inner.now += 1;
                return .interrupted;
            }
            return self.inner.wait(timeout_ms);
        }
        pub fn read(self: *@This(), buf: []u8) isize {
            return self.inner.read(buf);
        }
        pub fn nowMs(self: *const @This()) i64 {
            return self.inner.now;
        }
    };
    var flaky: Flaky = .{ .inner = .{ .events = &.{.{ .at_ms = 10, .bytes = "\x1b[?62c" }} } };
    const round = runRound(&flaky, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.unsupported, round.result.keyboard);

    const Closed = struct {
        pub fn sendQuery(_: *@This(), _: []const u8) bool {
            return true;
        }
        pub fn wait(_: *@This(), _: u32) Wait {
            return .closed;
        }
        pub fn read(_: *@This(), _: []u8) isize {
            unreachable;
        }
        pub fn nowMs(_: *const @This()) i64 {
            return 0;
        }
    };
    var closed: Closed = .{};
    try testing.expectEqual(Keyboard.unknown, runRound(&closed, .{ .keyboard = true }, budget_ms).result.keyboard);
}

test "runRound: nothing asked, or the query not written, reads nothing" {
    var term: ScriptedTerminal = .{ .events = &.{.{ .at_ms = 0, .bytes = "k" }} };
    _ = runRound(&term, .{}, budget_ms);
    try testing.expectEqual(@as(usize, 0), term.written_len);
    term.write_ok = false;
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.unknown, round.result.keyboard);
    var rest: [8]u8 = undefined;
    try testing.expectEqualStrings("k", term.unread(&rest));
}

test "runRound: a paste larger than stdin can be handed stays with the terminal" {
    var paste: [Scanner.typed_capacity + 100]u8 = undefined;
    @memset(&paste, 'p');
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 0, .bytes = &paste },
        .{ .at_ms = 1, .bytes = "\x1b[?62c" },
    } };
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(@as(usize, Scanner.typed_capacity), round.typed_len);
    try testing.expectEqual(Keyboard.unknown, round.result.keyboard);
    var rest: [200]u8 = undefined;
    const left = term.unread(&rest);
    try testing.expectEqual(@as(usize, 100 + 6), left.len);
    try testing.expectEqualStrings("\x1b[?62c", left[100..]);
}

test "probe: no terminal, nothing asked → nothing known, nothing owed" {
    // The test runner's stdin is a pipe or /dev/null; asking nothing returns before any I/O.
    const nothing = probe(.{});
    try testing.expect(nothing.background == null and nothing.keyboard == .unknown and !nothing.sentinel);
}
