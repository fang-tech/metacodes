//! REPL 行编辑。
//!
//! 分两层：
//! 1. 底层：按键抽象（Key + KeyParser）+ termios raw mode 切换——从 M4.1 spike 正式化
//! 2. 中层：LineEditor——持 buffer + cursor + 多行 flag；接受 Key，输出 Action
//!
//! 渲染（repl/render.zig）是另一层。真 tty 驱动留给 runtime（M4.4 接入 repl/loop）。
//!
//! 测试策略：LineEditor 全部用 fake keystream 驱动。termios 只做 "不崩" 测试（真 tty 行为难在 CI 里验证）。

const std = @import("std");
const ppaths = @import("platform").paths;
const pfs = @import("platform").fs;
const platform_term = @import("platform").terminal;
const platform_signal = @import("platform").signal;
const process = @import("platform").process;
const shutdown = @import("../core/shutdown.zig");
const bg_probe = @import("tui/bg_probe.zig");

// ============================================================================
// Key 抽象
// ============================================================================

pub const Key = union(enum) {
    char: u8,
    enter,
    shift_enter, // 插入换行而非提交（CSI u: ESC [ 13;2 u）
    ctrl_enter, // 同上（CSI u: ESC [ 13;5 u）
    backspace,
    ctrl_a,
    ctrl_e,
    ctrl_u,
    ctrl_k,
    ctrl_w, // 删上一个词
    ctrl_y, // 粘回 yank ring
    ctrl_l, // 重绘屏幕
    ctrl_c,
    ctrl_d,
    alt_b, // 上一词
    alt_f, // 下一词
    up,
    down,
    left,
    right,
    home,
    end,
    delete,
    page_up, // ESC[5~（agent viewing 视口翻页）
    page_down, // ESC[6~
    esc,
    tab,
    shift_tab, // cycle 权限模式
    ctrl_r,
    ctrl_t, // 切换任务列表显示
    ctrl_o, // 打开 transcript viewer
    ctrl_b, // 生成期:把主对话转后台续跑(run in background)
    ctrl_x, // Ctrl+X 前缀(配合 Ctrl+K kill 后台)
    ctrl_g, // 外部编辑器编辑当前 buffer
    ctrl_underscore, // Ctrl+_ / Ctrl+Shift+- (0x1f): undo
    paste_begin, // 括号粘贴起始 ESC[200~
    paste_end, // 括号粘贴结束 ESC[201~
    unknown,
};

/// 按字节喂的 CSI 状态机解析器（见 M4.1 spike）。
///
/// 支持的 CSI 序列：
///   ESC [ A/B/C/D     ↑↓→←
///   ESC [ H / F       Home / End
///   ESC [ 3 ~         Delete
///   ESC [ <num>;<mod> u   CSI u（xterm modifyOtherKeys kitty 扩展）
///     - 13;2 u = Shift+Enter
///     - 13;5 u = Ctrl+Enter
/// 其它 CSI(私有前缀、更多参数段)整条吃掉、报一个 .unknown;OSC 应答(`ESC ] 11 ; … BEL`)
/// 同样整条吃掉——终端应答不会漏成字符。
pub const KeyParser = struct {
    state: State = .normal,
    num1: u32 = 0,
    num2: u32 = 0,
    // 一字节 feed 偶尔需吐多个键(ESC 后紧跟普通字符 = 孤立 ESC + 该字符;`ESC ]` 后不是
    // OSC 应答 = ESC + ']' + 数字 + 下一个键):feed 返回第一个,其余按序暂存这里,
    // 调用方 feed / flushEsc 后须 while(drain())|k| 排空。
    queued: [queue_capacity]Key = undefined,
    queued_head: u8 = 0,
    queued_len: u8 = 0,
    // `ESC ]` 之后的数字(OSC 编号,至多 3 位):不是应答时原样还成键。
    osc_digits: [3]u8 = undefined,
    osc_digits_len: u8 = 0,

    // ']' + 3 位数字 + 截断它的那个键。
    const queue_capacity = 5;

    // csi_skip:一个认不出的 CSI(私有前缀 `?`/`<`/`>`/`=`、三段以上参数、`:` 子参数),
    // 吃到它的终结字节(0x40-0x7E)为止,整条报一个 .unknown。终端应答(DA1 `ESC[?62c`、
    // Kitty flags `ESC[?1u`)晚于启动探测才到、xterm 式 `ESC[27;2;13~` 都走这里——
    // 否则后半截会被当成敲进来的字符("62c" 进了输入框)。
    // osc_seen/osc_ps/osc_body/osc_st:`ESC ] Ps ; Pt (BEL | ESC \)`,终端的 OSC 应答(探测问的
    // 背景色 `ESC]11;rgb:…`)。只认数字编号 + `;` 开头的形状:Alt+] 之后敲别的(包括什么都不敲、
    // 等到 ESC 超时)仍是原来那几个键。迟到的背景色应答以前会变成 Esc、字符、Esc——两次 Esc
    // 连按清空了输入框。
    const State = enum { normal, esc_seen, csi_seen, csi_num1, csi_semi, csi_num2, csi_skip, osc_seen, osc_ps, osc_body, osc_st };

    /// CSI 的参数/中间字节(0x20-0x3F):数字、`;`、`:`、私有前缀 `<=>?`、空格../。
    fn csiParam(b: u8) bool {
        return b >= 0x20 and b <= 0x3f;
    }

    /// 数字参数之后的 `$`:rxvt 系(urxvt、Eterm、aterm)Shift 组合键的终结字节(Shift+Delete
    /// `ESC[3$`、Shift+Home/End `ESC[7$`/`ESC[8$`、Shift+F11 `ESC[23$`)。按标准它是中间字节,
    /// 当成中间字节的话 parser 会把用户接着敲的字母当终结字节吃掉。
    fn rxvtShiftFinal(b: u8) bool {
        return b == '$';
    }

    /// 是否正读到一个序列中间(已收 ESC,等后续字节),包括 CSI 参数和 OSC 正文。
    /// 调用方(watcher)在 read 超时时若此为 true,应调 flushEsc():终端一次写出整个序列,
    /// 等一个读周期都没来的后半截不会再来了(被下一次进 raw 的 TCSAFLUSH 丢了,或根本是
    /// 用户按的 Esc)。
    pub fn pendingEsc(self: *const KeyParser) bool {
        return self.state != .normal;
    }

    /// 取出 feed / flushEsc 暂存的下一个键(若有)。调用方每次 feed 后循环 drain 至 null。
    /// 用于 ESC + 普通字符这类一次 feed 产出多键的场景(否则后面的字符被吞)。
    pub fn drain(self: *KeyParser) ?Key {
        if (self.queued_len == 0) return null;
        const k = self.queued[self.queued_head];
        self.queued_head = (self.queued_head + 1) % queue_capacity;
        self.queued_len -= 1;
        return k;
    }

    fn push(self: *KeyParser, k: Key) void {
        // 一次 feed 至多产出 queue_capacity 个键,调用方排空后才再喂:装不下 = 调用方漏了排空,
        // 宁丢这个键也不越界。
        std.debug.assert(self.queued_len < queue_capacity);
        if (self.queued_len == queue_capacity) return;
        self.queued[(self.queued_head + self.queued_len) % queue_capacity] = k;
        self.queued_len += 1;
    }

    /// 读周期超时、序列的后半截没来(见 pendingEsc):兑现读到的部分,parser 回到 normal。
    /// - 孤立 ESC → .esc;`ESC ]`(Alt+])及其后的数字 → .esc,']' 与数字随后 drain 出;
    ///   OSC 正文里的 ESC 等不来 `\` → 那个 ESC 是用户按的 Esc,返回 .esc。
    /// - CSI 参数、OSC 正文读到一半 → 整条作废,返回 null(不产生键)。
    /// 不在序列中间返 null。
    pub fn flushEsc(self: *KeyParser) ?Key {
        const key: ?Key = switch (self.state) {
            .normal => return null,
            .esc_seen, .osc_st => .esc,
            .osc_seen, .osc_ps => blk: {
                self.queueOscPrefix();
                break :blk .esc;
            },
            .csi_seen, .csi_num1, .csi_semi, .csi_num2, .csi_skip, .osc_body => null,
        };
        self.state = .normal;
        return key;
    }

    /// `ESC ]` 和其后的数字不是 OSC 应答:']' 和数字作为键排队(.esc 由调用方返回)。
    fn queueOscPrefix(self: *KeyParser) void {
        self.push(.{ .char = ']' });
        for (self.osc_digits[0..self.osc_digits_len]) |d| self.push(.{ .char = d });
    }

    pub fn feed(self: *KeyParser, b: u8) ?Key {
        switch (self.state) {
            .normal => {
                if (b == 0x1b) {
                    self.state = .esc_seen;
                    return null;
                }
                return byteToKey(b);
            },
            .esc_seen => {
                if (b == '[') {
                    self.state = .csi_seen;
                    self.num1 = 0;
                    self.num2 = 0;
                    return null;
                }
                if (b == ']') {
                    self.state = .osc_seen;
                    self.osc_digits_len = 0;
                    return null;
                }
                self.state = .normal;
                // Alt+key:ESC 后紧跟字母(meta)。Alt+B / Alt+F 词导航——是单个组合键,不拆。
                switch (b) {
                    'b', 'B' => return .alt_b,
                    'f', 'F' => return .alt_f,
                    else => {},
                }
                // ESC ESC:第二个 ESC 重新开始一个待定序列。兑现第一个 .esc,自身回 esc_seen
                // 等后续字节(否则双击 Esc 的第二下会被当 .unknown 丢掉)。
                if (b == 0x1b) {
                    self.state = .esc_seen;
                    return .esc;
                }
                // 其它字符:这是"孤立 ESC + 该字符"两个独立键(用户极快连打,或终端把
                // 两次按键合批送来)。兑现 ESC 为本次返回值,该字符的键暂存 pending,
                // 调用方 while(drain()) 取出——否则该字符被吞(早期 bug)。
                self.push(byteToKey(b));
                return .esc;
            },
            .csi_seen => {
                if (b >= '0' and b <= '9') {
                    self.num1 = b - '0';
                    self.state = .csi_num1;
                    return null;
                }
                if (csiParam(b)) {
                    self.state = .csi_skip;
                    return null;
                }
                self.state = .normal;
                return switch (b) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    'Z' => .shift_tab, // ESC [ Z = Shift+Tab(backtab)
                    else => .unknown,
                };
            },
            .csi_num1 => {
                if (b >= '0' and b <= '9') {
                    self.num1 = self.num1 * 10 + (b - '0');
                    return null;
                }
                if (b == ';') {
                    self.state = .csi_semi;
                    return null;
                }
                if (rxvtShiftFinal(b)) {
                    self.state = .normal;
                    return .unknown;
                }
                if (csiParam(b)) {
                    self.state = .csi_skip;
                    return null;
                }
                // 终结字符
                self.state = .normal;
                if (b == '~') {
                    return switch (self.num1) {
                        3 => .delete,
                        5 => .page_up,
                        6 => .page_down,
                        200 => .paste_begin,
                        201 => .paste_end,
                        else => .unknown,
                    };
                }
                // 无 modifier 的 CSI-u(ESC[<cp>u,无 ;mod):Kitty disambiguate 模式下
                // Enter/Esc/纯文本也可能编成 CSI-u。还原成对应键,避免被当 .unknown 吞掉。
                if (b == 'u') {
                    return switch (self.num1) {
                        13 => .enter, // 无 mod Enter
                        27 => .esc, // 无 mod Esc
                        // ASCII 可打印 → char(兼容把纯文本也 CSI-u 编码的终端)。
                        0x20...0x7e => Key{ .char = @intCast(self.num1) },
                        else => .unknown,
                    };
                }
                return .unknown;
            },
            .csi_semi => {
                if (b >= '0' and b <= '9') {
                    self.num2 = b - '0';
                    self.state = .csi_num2;
                    return null;
                }
                if (rxvtShiftFinal(b)) {
                    self.state = .normal;
                    return .unknown;
                }
                if (csiParam(b)) {
                    self.state = .csi_skip;
                    return null;
                }
                self.state = .normal;
                return .unknown;
            },
            .csi_num2 => {
                if (b >= '0' and b <= '9') {
                    self.num2 = self.num2 * 10 + (b - '0');
                    return null;
                }
                if (rxvtShiftFinal(b)) {
                    self.state = .normal;
                    return .unknown;
                }
                if (csiParam(b)) {
                    self.state = .csi_skip;
                    return null;
                }
                self.state = .normal;
                // CSI u：<key_codepoint>;<mod> u。
                //   key=13 = Enter
                //   key=99 = 'c'（Ctrl+C 编成 99;5u）
                //   key=100 = 'd'（Ctrl+D 编成 100;5u）
                //   key=27 = Esc
                // 其他组合不识别，返 .unknown（状态已重置，不会污染后续）
                if (b == 'u') {
                    // Enter 特化
                    if (self.num1 == 13) {
                        return switch (self.num2) {
                            2 => .shift_enter,
                            5 => .ctrl_enter,
                            else => .enter,
                        };
                    }
                    // 带修饰的 Esc(Shift/Ctrl+Esc)仍是 Esc:取消、关闭对它的每个使用方都一样
                    // (反向搜索、transcript viewer 旧的自解码 CSI-u 就只看 codepoint 27)。
                    if (self.num1 == 27) return .esc;
                    // Ctrl+字母：mod=5 表示 Ctrl。Kitty disambiguate 模式下某些终端/tmux 会把
                    // 普通 Ctrl+letter 也编成 CSI-u(非仅歧义键)→ 必须覆盖 app 用到的全部 Ctrl 组合,
                    // 否则该键在这些终端上静默丢(实测 bug:Ctrl+O 在发 CSI-u 的终端无反应)。
                    // 与 byteToKey 的 0x01-0x1f 控制字节集保持一致。
                    if (self.num2 == 5) {
                        return switch (self.num1) {
                            99, 67 => .ctrl_c, // 'c' / 'C'
                            100, 68 => .ctrl_d, // 'd'
                            97, 65 => .ctrl_a,
                            101, 69 => .ctrl_e,
                            107, 75 => .ctrl_k,
                            117, 85 => .ctrl_u,
                            111, 79 => .ctrl_o, // 'o' — transcript viewer(实测漏)
                            98, 66 => .ctrl_b, // 'b' — 转后台(run in background)
                            114, 82 => .ctrl_r, // 'r' — reverse search
                            116, 84 => .ctrl_t, // 't' — task panel toggle
                            103, 71 => .ctrl_g, // 'g'
                            120, 88 => .ctrl_x, // 'x' — Ctrl+X 前缀
                            108, 76 => .ctrl_l, // 'l' — external edit
                            119, 87 => .ctrl_w, // 'w'
                            121, 89 => .ctrl_y, // 'y'
                            95 => .ctrl_underscore, // '_' — undo
                            else => .unknown,
                        };
                    }
                    // Alt+字母:mod=3。Kitty disambiguate 把 Alt+B/Alt+F 编成 CSI-u(旧编码 ESC b
                    // 与"ESC 再按 b"有歧义),不认的话开了协议的终端上词跳转就没了。
                    if (self.num2 == 3) {
                        return switch (self.num1) {
                            98, 66 => .alt_b,
                            102, 70 => .alt_f,
                            else => .unknown,
                        };
                    }
                    return .unknown;
                }
                return .unknown;
            },
            .csi_skip => {
                if (csiParam(b)) return null;
                self.state = .normal;
                if (b >= 0x40 and b <= 0x7e) return .unknown; // 终结字节:整条认不出的序列
                // 不是 CSI 的字节,序列到此为止:这个字节是下一个键(ESC 开新序列,控制键照常)。
                if (b == 0x1b) {
                    self.state = .esc_seen;
                    return .unknown;
                }
                return byteToKey(b);
            },
            .osc_seen, .osc_ps => {
                if (b >= '0' and b <= '9' and self.osc_digits_len < self.osc_digits.len) {
                    self.osc_digits[self.osc_digits_len] = b;
                    self.osc_digits_len += 1;
                    self.state = .osc_ps;
                    return null;
                }
                if (b == ';' and self.state == .osc_ps) {
                    self.state = .osc_body;
                    return null;
                }
                // 不是 OSC 应答:Alt+](和其后敲的数字)是键,b 是下一个键。
                self.queueOscPrefix();
                self.state = .normal;
                if (self.feed(b)) |k| self.push(k);
                return .esc;
            },
            .osc_body => switch (b) {
                0x07 => {
                    self.state = .normal;
                    return .unknown; // BEL 结尾:整条应答
                },
                0x1b => {
                    self.state = .osc_st;
                    return null;
                },
                // 应答里不会有的控制字节:序列到此为止,这个字节是下一个键(Enter、Ctrl+C 照常)。
                0x00...0x06, 0x08...0x1a, 0x1c...0x1f => {
                    self.state = .normal;
                    return byteToKey(b);
                },
                else => return null,
            },
            .osc_st => {
                if (b == '\\') {
                    self.state = .normal;
                    return .unknown; // ST 结尾:整条应答
                }
                // ESC 开了别的序列:应答就此作废,ESC + b 照常解析。
                self.state = .esc_seen;
                return self.feed(b);
            },
        }
    }
};

fn byteToKey(b: u8) Key {
    return switch (b) {
        '\r', '\n' => .enter,
        0x09 => .tab,
        0x12 => .ctrl_r,
        0x14 => .ctrl_t,
        0x0f => .ctrl_o,
        0x02 => .ctrl_b, // 生成期转后台(run in background)
        0x18 => .ctrl_x,
        0x07 => .ctrl_g,
        0x7f, 0x08 => .backspace,
        0x01 => .ctrl_a,
        0x03 => .ctrl_c,
        0x04 => .ctrl_d,
        0x05 => .ctrl_e,
        0x0b => .ctrl_k,
        0x15 => .ctrl_u,
        0x17 => .ctrl_w,
        0x19 => .ctrl_y,
        0x0c => .ctrl_l,
        0x1f => .ctrl_underscore, // Ctrl+_ / Ctrl+Shift+- : undo
        // 可打印 ASCII：0x20-0x7E
        // UTF-8 多字节：0x80+（首字节 0xC0-0xFF，延续字节 0x80-0xBF）——逐字节作为 .char 透传
        // 终端在显示时会把完整 UTF-8 序列组合成一个字符
        else => if (b >= 0x20) Key{ .char = b } else .unknown,
    };
}

// ============================================================================
// Raw mode（termios）
// ============================================================================

/// SIGCONT is handled asynchronously by publishing this bit.  The next
/// foreground input poll performs the actual terminal IO in normal context.
var g_resume_requested = std.atomic.Value(bool).init(false);

fn onContinue() void {
    g_resume_requested.store(true, .release);
}

/// Install the process-wide resume hook used by both input phases.
pub fn installResumeHandler() void {
    platform_signal.installContinue(onContinue);
}

/// Consume a pending SIGCONT and restore the intended raw/escape state.
/// Re-entering raw mode is idempotent; the saved cooked mode belongs to the
/// surrounding input phase and is never replaced by this reconciliation.
pub fn reconcileAfterResume(fd: c_int) bool {
    if (!g_resume_requested.swap(false, .acquire)) return false;
    if (reconcileModes(fd)) return true;
    // Keep the request pending if the descriptor was transiently unavailable;
    // the next poll gets another chance to restore the interactive state.
    g_resume_requested.store(true, .release);
    return false;
}

/// Whether a raw-mode key read that returned < 0 only lost a race with a
/// signal: a terminal resize (SIGWINCH) or a resume (SIGCONT) interrupts a
/// blocked read with EINTR and carries no input, so the reader retries
/// (redrawing if it redraws per iteration) instead of taking the failure as
/// an answer. That is how a resize used to become "user declined" in the
/// permission dialog. A pending resume is reconciled first. A requested
/// process shutdown (SIGINT) still ends the reader. Call it right after the
/// failed read, before another call can overwrite errno. Windows has neither
/// signal, and its console read does not set errno, so a stale value there
/// is never taken for an interruption.
pub fn retryInterruptedRead(fd: c_int) bool {
    const interrupted = @import("builtin").os.tag != .windows and pfs.lastErrnoIs(.INTR);
    const resumed = reconcileAfterResume(fd);
    if (shutdown.requested()) return false;
    return interrupted or resumed;
}

/// How long a modal key loop waits for input before it looks again. A lone
/// ESC still pending when the wait runs out is the Esc key: terminals send a
/// sequence's bytes together, and the prompt's own loop uses the same tick.
const key_wait_ms: i32 = 200;

/// What `readKey` got.
pub const KeyRead = union(enum) {
    key: Key,
    /// A signal (a resize, a resume) cut the wait short. Nothing was lost:
    /// a sequence read halfway stays in the parser. Redraw, then read again.
    interrupted,
    /// End of input, a read error, or a requested shutdown.
    closed,
};

/// One key for a modal loop that owns the terminal in raw mode (transcript
/// viewer, reverse search). Bytes go through `parser`, so the rest of an
/// escape sequence is read like any other byte: a resize between ESC and `[`
/// no longer splits `ESC [ A` into Esc plus two typed characters, and a lone
/// Esc is reported once the wait runs out instead of waiting for another key.
pub fn readKey(fd: c_int, parser: *KeyParser) KeyRead {
    if (parser.drain()) |key| return .{ .key = key };
    while (true) {
        const rc = platform_term.waitReadable(fd, key_wait_ms);
        if (rc == 0) {
            if (parser.flushEsc()) |key| return .{ .key = key };
            continue;
        }
        if (rc < 0) return if (retryInterruptedRead(fd)) .interrupted else .closed;
        var b: [1]u8 = undefined;
        const n = platform_term.readInput(fd, &b);
        if (n < 0) return if (retryInterruptedRead(fd)) .interrupted else .closed;
        if (n == 0) return .closed;
        if (parser.feed(b[0])) |key| return .{ .key = key };
    }
}

/// Reconcile all terminal mode families with the intended interactive state.
/// This is deliberately shared by initial entry and SIGCONT recovery so a new
/// mode cannot be enabled in one path and forgotten in the other.
pub fn reconcileModes(fd: c_int) bool {
    if (platform_term.enterRaw(fd) == null) return false;
    emitEnableSequences(fd);
    return true;
}

fn emitEnableSequences(fd: c_int) void {
    // Dumb terminals do not understand private modes; keep their output clean.
    const term = std.c.getenv("TERM");
    const dumb = term == null or std.mem.eql(u8, std.mem.span(term.?), "dumb") or std.mem.span(term.?).len == 0;
    if (dumb) return;

    // Kitty keyboard + modifyOtherKeys are enabled only for the terminals that
    // are known, or answered the startup probe, to parse them.  The sequence
    // starts by popping stale Kitty state, making repeated reconciliation safe
    // even after shell changes.
    if (shouldEnableKittyKeyboard()) {
        _ = pfs.writeAll(fd, kbd_enable_seq);
    }
    const enable_paste = "\x1b[?2004h";
    _ = pfs.writeAll(fd, enable_paste);
}

/// 切 raw 模式，返回旧 termios；非 tty 或失败返 null。
/// 进 raw mode。返回原 termios(供 restoreMode 复原);非 tty 返 null。
/// 仅对**证明了能力的终端**(shouldEnableKittyKeyboard:认得出的、或启动探测答了 Kitty flags)
/// 启用 Kitty 键盘协议 / xterm modifyOtherKeys,以区分 Shift+Enter / Ctrl+Enter。deny-list 上的
/// (如 Apple Terminal)不发——它们会 honor 协议并发回 parser 处理不了的 codepoint(对齐真 cc
/// terminal.ts:167:无条件发是 #23350 踩过的坑)。
///
/// **键盘协议序列**(对齐真 cc ink.tsx:418,pop-before-push 防残留栈叠加):
///   `\x1b[<u`   DISABLE_KITTY_KEYBOARD —— 先 pop 清 Kitty 栈
///   `\x1b[>1u`  ENABLE_KITTY flags=1(disambiguate-only):歧义键(Shift/Ctrl+Enter、
///              Esc、功能键)编成 CSI-u,纯文本不编码 → Warp/iTerm/kitty/WezTerm/ghostty 用这条
///   `\x1b[>4;2m` ENABLE_MODIFY_OTHER_KEYS level 2:不支持 Kitty 的 xterm 系走这条
/// 实测:Warp 收到 `\x1b[>1u` 后 Shift+Enter 才发 `\x1b[13;2u`(否则退回裸 \n,被当 Enter)。
/// 不发协议的终端 Shift+Enter 发裸 \r/\n,换行改靠 backslash+return(见 LineEditor.handle .enter)。
pub const kbd_enable_seq = "\x1b[<u" ++ "\x1b[>1u" ++ "\x1b[>4;2m";
pub const kbd_disable_seq = "\x1b[<u" ++ "\x1b[>4m"; // DISABLE_KITTY(pop) + DISABLE_MODIFY_OTHER_KEYS

/// 怎样决定发不发 Kitty 键盘协议 / modifyOtherKeys(#327)。
pub const KeyboardPolicy = enum {
    /// 环境认得出、已知实现正确的终端(及 tmux):直接发,不问。
    enable,
    /// 已知会把协议用坏的终端(deny-list)、dumb 终端、问了也答不准的 multiplexer:不发,也不问。
    disable,
    /// 环境认不出:启动探测(tui/bg_probe.zig)问终端本身,答了 Kitty flags 才发;没答 → 不发。
    probe,
};

/// Kitty 键盘协议 **deny-list**:探测也不问,答了也不发(TERM 自己认得出的 kitty/Ghostty 除外,
/// 见 classifyKittyKeyboard)。
/// 真 cc 注释铁证(terminal.ts:167):此前无条件发(#23350)是 bug——某些终端(Apple Terminal/
/// SSH/xterm.js)会 honor enable 并发回 parser 处理不了的 codepoint(→ 各种键乱/乱码)。
/// 那次教训里点名的终端留在这里:Apple_Terminal;xterm.js 的宿主 vscode(VS Code 及其分支)、Hyper。
/// Apple Terminal 换行靠 backslash+return。SSH 不是终端,不在此列:远端认不出的终端正是探测
/// 要回答的问题(探测经 SSH 问到本地真正的终端)。
const kitty_deny_term_programs = [_][]const u8{ "Apple_Terminal", "vscode", "Hyper" };

/// 环境就能认出、已知正确实现 Kitty/modifyOtherKeys 的终端(对齐真 cc EXTENDED_KEYS_TERMINALS +
/// 实测追加 Warp):直接发,省一次往返,也不因探测改变它们已验证过的行为。
/// WarpTerminal 为 cc-zig 追加(用户实测:其默认未开 Kitty,需主动发 \x1b[>1u 才能 Shift+Enter 换行)。
const kitty_term_programs = [_][]const u8{ "iTerm.app", "WezTerm", "ghostty", "WarpTerminal" };

/// 会话跑在哪个终端复用器里。复用器自己应答查询,答的是它自己而不是外层终端,故不探测。
pub const Multiplexer = enum {
    none,
    /// tmux 接受 modifyOtherKeys 且不转发 Kitty 给外层(对齐真 cc):照旧直接发。
    tmux,
    /// GNU screen、zellij,或 TERM 是 screen*/tmux* 而本进程不在 tmux 里(经 SSH 从复用器里连过来):
    /// 照旧只看环境认不认得出终端。
    other,
};

/// 纯函数(便于纯单测,不依赖真 env):据 TERM_PROGRAM / TERM / 复用器定 Kitty 协议策略。
fn classifyKittyKeyboard(term_program: ?[]const u8, term: ?[]const u8, multiplexer: Multiplexer) KeyboardPolicy {
    // dumb 终端不懂私有模式:emitEnableSequences 什么都不发,提示文案也要与之一致。
    if (term == null or term.?.len == 0 or std.mem.eql(u8, term.?, "dumb")) return .disable;
    if (multiplexer == .tmux) return .enable;
    // TERM 是终端给自己起的 shell 设的;TERM_PROGRAM 会从外层继承(从 Terminal.app 或 VS Code
    // 里启动的 kitty 仍带着外层的 TERM_PROGRAM)。TERM 认得出就以它为准,先于 deny-list。
    if (kittyTerm(term.?)) return .enable;
    if (term_program) |tp| {
        for (kitty_deny_term_programs) |n| if (std.mem.eql(u8, tp, n)) return .disable;
        for (kitty_term_programs) |n| if (std.mem.eql(u8, tp, n)) return .enable;
    }
    return if (multiplexer == .other) .disable else .probe;
}

fn kittyTerm(term: []const u8) bool {
    if (std.mem.indexOf(u8, term, "kitty") != null) return true; // xterm-kitty 等
    return std.mem.eql(u8, term, "xterm-ghostty");
}

fn envValue(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}

fn nonEmptyEnv(name: [*:0]const u8) bool {
    return if (envValue(name)) |v| v.len > 0 else false;
}

/// 读真实 env 调 classifyKittyKeyboard。
pub fn keyboardPolicy() KeyboardPolicy {
    const term = envValue("TERM");
    const multiplexer: Multiplexer = if (nonEmptyEnv("TMUX"))
        .tmux
    else if (nonEmptyEnv("STY") or envValue("ZELLIJ") != null or
        (term != null and (std.mem.startsWith(u8, term.?, "screen") or std.mem.startsWith(u8, term.?, "tmux"))))
        .other
    else
        .none;
    return classifyKittyKeyboard(envValue("TERM_PROGRAM"), term, multiplexer);
}

/// 启动探测的答案:终端答了 Kitty flags 查询。进程内只在启动时、首次进 raw mode 之前写一次
/// (app.resolveInteractiveTerminal),此后 enable/restore/提示文案读到的恒是同一个值。
var g_kitty_answered = std.atomic.Value(bool).init(false);

pub fn recordKeyboardProbe(kitty_answered: bool) void {
    g_kitty_answered.store(kitty_answered, .release);
}

/// 发不发 Kitty 协议:策略 + (策略要探测时)启动探测的答案。同进程 env 不变、答案只写一次,
/// enterRawMode 与 restoreMode 的判定恒一致。
pub fn shouldEnableKittyKeyboard() bool {
    return switch (keyboardPolicy()) {
        .enable => true,
        .disable => false,
        .probe => g_kitty_answered.load(.acquire),
    };
}

/// 当前终端的换行方式提示(对齐真 cc getNewlineInstructions,但按 cc-zig 实际能力):
/// - 发了 Kitty 协议(认得出的终端、或探测答了)→ Shift+Enter 真换行 → "shift + ⏎ for newline"
/// - 没发(deny-list 的 Apple Terminal 等、探测说不支持或没答,Shift+Enter 发裸 \r=Enter 会提交)
///   → "\ + ⏎ for newline"(cc-zig 无 macOS 原生 modifier 检测,故 Apple Terminal 只能靠
///   backslash 续行,不能照抄真 cc 对 Apple 的 "shift+⏎" 文案——那会误导)。
pub fn newlineHint() []const u8 {
    return if (shouldEnableKittyKeyboard()) "shift + \xe2\x8f\x8e for newline" else "\\ + \xe2\x8f\x8e for newline";
}

pub fn enterRawMode(fd: c_int) ?platform_term.SavedMode {
    // 启动探测到期、应答还在路上时终端一直是安静模式(bg_probe.Late):接管它,返回探测前的
    // 模式供 restoreMode 复原(当前的安静模式不是要复原的那个)。
    const original = bg_probe.handOver(fd);
    // 模式切换走可移植 platform/terminal(POSIX termios / Windows console mode)。
    const orig = platform_term.enterRaw(fd) orelse {
        if (original) |o| platform_term.restoreModeKeepingInput(fd, o);
        return null;
    };
    emitEnableSequences(fd);
    return original orelse orig;
}

pub fn restoreMode(fd: c_int, orig: platform_term.SavedMode) void {
    // 关 bracketed paste(始终)+ 键盘协议(仅发过 enable 的——对称 enterRawMode,同进程 env 不变、
    // 探测答案只写一次,判定恒一致,不会发了 enable 没 disable;没发过的不发孤立 disable,避免
    // Apple Terminal honor 它出异常)。
    const disable_paste = "\x1b[?2004l";
    _ = pfs.writeAll(fd, disable_paste);
    if (shouldEnableKittyKeyboard()) {
        _ = pfs.writeAll(fd, kbd_disable_seq);
    }
    platform_term.restoreMode(fd, orig); // POSIX tcsetattr / Windows SetConsoleMode
}

/// 把 `current` 写临时文件,开 $VISUAL/$EDITOR(前台阻塞)编辑,读回(owned,去尾换行)。
/// 调用方负责终端模式:本函数 spawn 的编辑器自管 termios,但调用方应在调用前退 raw / 调用后重进。
/// REPL 主循环(loop.zig Ctrl+G)和 AskUserQuestion preview note(ask_question.zig ctrl+g)共用。
pub fn externalEdit(allocator: std.mem.Allocator, current: []const u8) ![]u8 {
    const editor_env = std.c.getenv("VISUAL") orelse std.c.getenv("EDITOR") orelse return error.NoEditor;
    const editor_cmd = std.mem.span(editor_env);

    // 每进程一个缓冲文件,放平台临时目录(POSIX $TMPDIR/… 或 /tmp,Windows %TEMP%):
    // 固定的 /tmp/cc-zig-edit-buffer.txt 会让两个并行 REPL 互相覆盖对方正在编辑的内容,
    // 在 Windows 上还依赖当前驱动器根下的 \tmp 存在。
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintZ(&tmp_path_buf, "{s}/metacodes-edit-buffer-{d}.txt", .{ ppaths.tempDir(), process.currentPid() });
    {
        const fd = pfs.open(tmp_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.WriteFailed;
        defer _ = pfs.close(fd);
        if (current.len > 0) _ = pfs.write(fd, current[0..current.len]); // no EINTR: regular file
    }

    const path_z = try allocator.dupeZ(u8, tmp_path);
    defer allocator.free(path_z);
    var argv = [_]?[*:0]const u8{ "/bin/sh", "-c", undefined, null };
    const sh_cmd = try std.fmt.allocPrintSentinel(allocator, "{s} \"{s}\"", .{ editor_cmd, tmp_path }, 0);
    defer allocator.free(sh_cmd);
    argv[2] = sh_cmd.ptr;

    // $EDITOR 交互式:继承 stdio（编辑器接管终端）+ wait，走可移植 platform/process。
    // Windows 的 /bin/sh 依赖 git-bash（roadmap shell 决策 node 8871）。
    _ = process.runInherit(argv[0..], true) catch return error.ForkFailed;

    const rfd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (rfd < 0) return error.ReadFailed;
    defer _ = pfs.close(rfd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(rfd, buf[0..buf.len]); // no EINTR: regular file
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    pfs.unlinkPath(path_z.ptr) catch {};
    var result = try out.toOwnedSlice(allocator);
    if (result.len > 0 and result[result.len - 1] == '\n') {
        result = try allocator.realloc(result, result.len - 1);
    }
    return result;
}

// ============================================================================
// LineEditor：buffer + cursor，按 Key 产生 Action
// ============================================================================

pub const Action = enum {
    /// 继续（buffer 改变或 cursor 移动，调用方需重绘）
    redraw,
    /// 提交当前行（enter）
    commit,
    /// Ctrl+D on an empty buffer. The idle prompt confirms it with a second
    /// press in `ui.dispatch` before it gets here; only paths without that
    /// state (none today) would see it.
    eof,
    /// 无语义变化（如 unknown 键）
    none,
};

const Snapshot = struct {
    bytes: []u8, // owned(dupe);pop/丢弃/deinit 时 free
    cursor: usize,
};
const undo_max_depth = 50;

pub const LineEditor = struct {
    buf: std.ArrayList(u8),
    cursor: usize = 0,
    allocator: std.mem.Allocator,
    /// yank ring:Ctrl+W/K/U 删除的内容存这,Ctrl+Y 粘回。
    yank_buf: std.ArrayList(u8),
    /// undo 栈:破坏性编辑前快照 buf+cursor。深度上限 undo_max_depth,超了丢最旧。
    undo_stack: std.ArrayList(Snapshot),
    /// 去抖:上一次 handle 处理的 Key tag。连续 .char 只在段首 push 一次。
    last_op: ?std.meta.Tag(Key) = null,
    /// up/down 竖移的 sticky 目标显示列(visual col)。null=无竖移流。
    /// 任何经 handle 的键(非竖移)清空;竖移路径(loop 经 RenderRegion.tryVerticalMove)
    /// 直接维护此字段,故连续 up/down 保 goal column。详见 ui_compare/diff/INPUT_BEHAVIOR_DIFF_2026-06-11.md。
    goal_vcol: ?usize = null,
    // TODO(redo):redo 栈留待后续(CC 主要只做 undo,Ctrl+Y 已被 yank 占用)。

    pub fn init(allocator: std.mem.Allocator) LineEditor {
        return .{ .buf = .empty, .allocator = allocator, .yank_buf = .empty, .undo_stack = .empty };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buf.deinit(self.allocator);
        self.yank_buf.deinit(self.allocator);
        for (self.undo_stack.items) |s| self.allocator.free(s.bytes);
        self.undo_stack.deinit(self.allocator);
    }

    /// 输入一个 Key 并更新状态。返回对应 Action。
    pub fn handle(self: *LineEditor, key: Key) !Action {
        // 任何经 editor 的键都是非竖移键(up/down 在 dispatch 截获,永不入此)→ 终结竖移流。
        self.goal_vcol = null;

        // undo 去抖:破坏性编辑前 push 当前状态。char 连打只在段首压一次(last_op != char);
        // 其它破坏性操作每次都压。导航键不压但更新 last_op(使 char→left→char 在第二个 char 重新压)。
        {
            const tag = @as(std.meta.Tag(Key), key);
            switch (key) {
                .char => {
                    if (self.last_op != .char) self.pushUndo();
                },
                .backspace, .delete, .ctrl_u, .ctrl_w, .ctrl_y, .shift_enter => {
                    self.pushUndo();
                },
                .ctrl_d => {
                    // Ctrl+D deletes forward on a non-empty buffer (see below).
                    if (self.cursor < self.buf.items.len) self.pushUndo();
                },
                .ctrl_k => {
                    // Ctrl+K 单按 = kill-line(Ctrl+X Ctrl+K 序列已迁 dispatch,不到 editor)。
                    // 仅真截断才压 undo(末尾 Ctrl+K 是 no-op)。
                    if (self.cursor < self.buf.items.len) self.pushUndo();
                },
                else => {},
            }
            self.last_op = tag;
        }

        switch (key) {
            .char => |c| {
                try self.buf.insert(self.allocator, self.cursor, c);
                self.cursor += 1;
                return .redraw;
            },
            .enter => {
                // backslash + return 续行(对齐真 cc useTextInput.ts:247-267):光标前一字节是
                // ASCII '\'(0x5c)且处逻辑行尾(buffer 末尾或下一字节是 '\n')→ 删 '\' + 原位插 '\n'
                // + 不提交。非白名单终端(Apple Terminal)Shift+Enter 发裸 \r→.enter,靠此换行;
                // 白名单终端用 .shift_enter(13;2u)直接插 \n,不经此,两路径不冲突。
                // '\'=0x5c 是 ASCII,UTF-8 多字节字节均 >= 0x80,前一字节直接比安全。
                if (self.cursor > 0 and self.buf.items[self.cursor - 1] == '\\') {
                    const at_eol = self.cursor == self.buf.items.len or self.buf.items[self.cursor] == '\n';
                    if (at_eol) {
                        self.pushUndo(); // .enter 不在上方 pushUndo 白名单,续行改 buffer 须显式压栈
                        _ = self.buf.orderedRemove(self.cursor - 1); // 删 '\'
                        self.cursor -= 1;
                        try self.buf.insert(self.allocator, self.cursor, '\n'); // 原位插 '\n'
                        self.cursor += 1;
                        return .redraw;
                    }
                }
                return .commit;
            },
            .shift_enter => {
                try self.buf.insert(self.allocator, self.cursor, '\n');
                self.cursor += 1;
                return .redraw;
            },
            // Ctrl+Enter(CSI-u 13;5u):真 cc v2.1.172 实测**不换行**(整个序列被吞:既不插
            // \n 也不插字符),只 Shift+Enter 换行。对齐 → no-op。
            .ctrl_enter => return .none,
            .backspace => {
                if (self.cursor == 0) return .none;
                const start = prevCharBoundary(self.buf.items, self.cursor);
                const n = self.cursor - start;
                var i: usize = 0;
                while (i < n) : (i += 1) _ = self.buf.orderedRemove(start);
                self.cursor = start;
                return .redraw;
            },
            .delete => {
                if (self.cursor >= self.buf.items.len) return .none;
                const end = nextCharBoundary(self.buf.items, self.cursor);
                const n = end - self.cursor;
                var i: usize = 0;
                while (i < n) : (i += 1) _ = self.buf.orderedRemove(self.cursor);
                return .redraw;
            },
            .left => {
                if (self.cursor == 0) return .none;
                self.cursor = prevCharBoundary(self.buf.items, self.cursor);
                return .redraw;
            },
            .right => {
                if (self.cursor >= self.buf.items.len) return .none;
                self.cursor = nextCharBoundary(self.buf.items, self.cursor);
                return .redraw;
            },
            .home, .ctrl_a => {
                if (self.cursor == 0) return .none;
                self.cursor = 0;
                return .redraw;
            },
            .end, .ctrl_e => {
                if (self.cursor == self.buf.items.len) return .none;
                self.cursor = self.buf.items.len;
                return .redraw;
            },
            .ctrl_u => {
                if (self.cursor == 0) return .none;
                // 删除光标左边所有字符,先存入 yank ring(供 Ctrl+Y 粘回,对齐 cc)。
                try self.stashYank(self.buf.items[0..self.cursor]);
                self.buf.replaceRangeAssumeCapacity(0, self.cursor, &.{});
                self.cursor = 0;
                return .redraw;
            },
            .ctrl_k => {
                // Ctrl+K 单按 = kill-line(删到行尾)。Ctrl+X Ctrl+K 序列(杀后台)已迁 dispatch。
                if (self.cursor >= self.buf.items.len) return .none;
                try self.stashYank(self.buf.items[self.cursor..]); // 存 yank(Ctrl+Y 粘回)
                self.buf.items.len = self.cursor; // 截断
                return .redraw;
            },
            // Ctrl+C belongs to the prompt's double-press state (`ui.dispatch`)
            // and, during a reply, to the watcher's interrupt; the editor has
            // nothing of its own to do with it.
            .ctrl_c => return .none,
            .ctrl_d => {
                if (self.buf.items.len == 0) return .eof;
                // Non-empty: delete forward, as Claude Code (and iPython) do.
                if (self.cursor >= self.buf.items.len) return .none;
                const end = nextCharBoundary(self.buf.items, self.cursor);
                self.buf.replaceRangeAssumeCapacity(self.cursor, end - self.cursor, &.{});
                return .redraw;
            },
            // 全局快捷键(↑↓/Tab/Shift+Tab/Ctrl+R/T/O/G/X/L)已全部由 dispatch(ui.zig)拦截解析,
            // editor 永远收不到它们(dispatch 返回非 pass_to_editor)→ 此处不再处理,落 else=.none。
            // Ctrl+X Ctrl+K 序列也迁 dispatch(UiState.ctrl_x_armed),editor 只管 Ctrl+K 单按 kill-line。
            .ctrl_w => {
                // 删上一个词:从 cursor 往前跳过空白,再删到上一个词边界
                if (self.cursor == 0) return .none;
                var start = self.cursor;
                while (start > 0 and self.buf.items[start - 1] == ' ') start -= 1;
                while (start > 0 and self.buf.items[start - 1] != ' ') start -= 1;
                try self.stashYank(self.buf.items[start..self.cursor]);
                const n = self.cursor - start;
                var i: usize = 0;
                while (i < n) : (i += 1) _ = self.buf.orderedRemove(start);
                self.cursor = start;
                return .redraw;
            },
            .ctrl_y => {
                if (self.yank_buf.items.len == 0) return .none;
                try self.buf.insertSlice(self.allocator, self.cursor, self.yank_buf.items);
                self.cursor += self.yank_buf.items.len;
                return .redraw;
            },
            .ctrl_underscore => {
                // undo:pop 栈顶快照恢复 buf+cursor。空栈则无操作。
                const snap = self.undo_stack.pop() orelse return .none;
                defer self.allocator.free(snap.bytes);
                self.buf.clearRetainingCapacity();
                try self.buf.appendSlice(self.allocator, snap.bytes);
                self.cursor = if (snap.cursor <= self.buf.items.len) snap.cursor else self.buf.items.len;
                return .redraw;
            },
            .alt_b => {
                if (self.cursor == 0) return .none;
                var p = self.cursor;
                while (p > 0 and self.buf.items[p - 1] == ' ') p -= 1;
                while (p > 0 and self.buf.items[p - 1] != ' ') p -= 1;
                self.cursor = p;
                return .redraw;
            },
            .alt_f => {
                const len = self.buf.items.len;
                if (self.cursor >= len) return .none;
                var p = self.cursor;
                while (p < len and self.buf.items[p] == ' ') p += 1;
                while (p < len and self.buf.items[p] != ' ') p += 1;
                self.cursor = p;
                return .redraw;
            },
            // paste_begin/end 由驱动循环（loop.zig）直接处理，编辑器层忽略
            .paste_begin, .paste_end => return .none,
            // Esc is the prompt's double press (`ui.dispatch`: a second Esc
            // clears the draft) or, during a reply, the watcher's interrupt.
            .esc => return .none,
            // 全局快捷键(↑↓/Tab/Shift+Tab/Ctrl+R/T/O/G/X/L)由 dispatch(ui.zig)拦截,
            // editor 正常收不到;此处兜底返 .none(防御:vim/边界路径若漏到这不崩)。
            .up, .down, .tab, .shift_tab, .ctrl_r, .ctrl_t, .ctrl_o, .ctrl_b, .ctrl_g, .ctrl_x, .ctrl_l => return .none,
            .page_up, .page_down => return .none, // viewing 视口翻页键,editor 不处理(dispatch 拦截)
            .unknown => return .none,
        }
    }

    /// 把删除的内容存入 yank_buf(覆盖式,够用)。
    fn stashYank(self: *LineEditor, slice: []const u8) !void {
        self.yank_buf.clearRetainingCapacity();
        try self.yank_buf.appendSlice(self.allocator, slice);
    }

    /// 破坏性编辑前调用:把当前 buf+cursor 压入 undo 栈(dupe owned)。超上限丢最旧。
    /// void(非 !void):瞬时 OOM 只丢 undo 历史,不破坏编辑。
    fn pushUndo(self: *LineEditor) void {
        const snap = self.allocator.dupe(u8, self.buf.items) catch return;
        if (self.undo_stack.items.len >= undo_max_depth) {
            const oldest = self.undo_stack.orderedRemove(0);
            self.allocator.free(oldest.bytes);
        }
        self.undo_stack.append(self.allocator, .{ .bytes = snap, .cursor = self.cursor }) catch {
            self.allocator.free(snap); // append 失败:回收防泄漏
        };
    }

    /// 清空 undo 历史(reset/setLine/clear 时调:行已换,旧快照无意义)。
    fn clearUndo(self: *LineEditor) void {
        for (self.undo_stack.items) |s| self.allocator.free(s.bytes);
        self.undo_stack.clearRetainingCapacity();
        self.last_op = null;
        self.goal_vcol = null; // 整体替换 buffer(reset/setLine/clear)亦终结竖移流
    }

    /// 清空（用于 cancel / 历史覆盖写入）。
    pub fn reset(self: *LineEditor) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.clearUndo();
    }

    /// 把 buffer 整体替换为给定字节（用于历史导航写回）。
    pub fn setLine(self: *LineEditor, line: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, line);
        self.cursor = self.buf.items.len;
        self.clearUndo();
    }

    pub fn view(self: *const LineEditor) []const u8 {
        return self.buf.items;
    }

    /// yank ring 当前内容长度(供 UI 判断"是否有可粘贴的已删文本",对齐 cc Ctrl+Y 提示)。
    pub fn yankLen(self: *const LineEditor) usize {
        return self.yank_buf.items.len;
    }

    /// 清空编辑行(buf + cursor 归零)。生成期回车入队后清框用。
    pub fn clear(self: *LineEditor) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.clearUndo();
    }
};

/// UTF-8 continuation byte（高两位是 10）
inline fn isUtf8Continuation(b: u8) bool {
    return (b & 0b1100_0000) == 0b1000_0000;
}

/// 从 pos 向前找到前一个 UTF-8 字符起始位置。pos 必须在字符边界。
pub fn prevCharBoundary(bytes: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and isUtf8Continuation(bytes[p])) : (p -= 1) {}
    return p;
}

/// 从 pos 向后找到下一个 UTF-8 字符起始位置（即当前字符的末尾）。
fn nextCharBoundary(bytes: []const u8, pos: usize) usize {
    if (pos >= bytes.len) return bytes.len;
    var p = pos + 1;
    while (p < bytes.len and isUtf8Continuation(bytes[p])) : (p += 1) {}
    return p;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "KeyParser: ASCII char" {
    var p = KeyParser{};
    try testing.expect(p.feed('a').? == .char);
}

test "KeyParser: enter + backspace + ctrl" {
    var p = KeyParser{};
    try testing.expect(p.feed('\n').? == .enter);
    try testing.expect(p.feed(0x7f).? == .backspace);
    try testing.expect(p.feed(0x03).? == .ctrl_c);
    try testing.expect(p.feed(0x04).? == .ctrl_d);
}

test "KeyParser: arrow keys sequence" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('[') == null);
    try testing.expect(p.feed('A').? == .up);
}

test "KeyParser: lone ESC flushes via flushEsc (interrupt 用)" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null); // esc_seen,等后续字节
    try testing.expect(p.pendingEsc()); // 卡在 esc_seen
    try testing.expect(p.flushEsc().? == .esc); // 超时兑现孤立 ESC
    try testing.expect(!p.pendingEsc()); // 回 normal
    try testing.expect(p.flushEsc() == null); // 非 esc_seen 再 flush 无效
    // 兑现后状态干净:普通字符仍正常。
    const k = p.feed('x').?;
    try testing.expect(@as(std.meta.Tag(Key), k) == .char);
}

test "KeyParser: ESC followed by printable char yields two keys (esc + char, 不吞字符)" {
    var p = KeyParser{};
    // ESC 后紧跟 'x'(终端把两次快按合批送来,或用户极快连打):
    // feed(0x1b) 进 esc_seen 不出键;feed('x') 兑现 .esc 并把 'x' 暂存 pending。
    try testing.expect(p.feed(0x1b) == null);
    const first = p.feed('x').?;
    try testing.expect(first == .esc); // 第一个键 = 孤立 ESC
    const second = p.drain().?; // 第二个键 = 'x'(早期 bug:此字符被吞)
    try testing.expect(@as(std.meta.Tag(Key), second) == .char);
    try testing.expect(second.char == 'x');
    try testing.expect(p.drain() == null); // 排空后无残留
}

test "KeyParser: ESC + 'b'/'f' 仍是 Alt 组合键(不拆成两键)" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('b').? == .alt_b); // ESC b = Alt+B(词左),单个键
    try testing.expect(p.drain() == null); // 不产生第二个键
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('f').? == .alt_f); // ESC f = Alt+F(词右)
    try testing.expect(p.drain() == null);
}

test "KeyParser: ESC ESC — 第一个兑现,第二个重新待定" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed(0x1b).? == .esc); // 兑现第一个 ESC
    try testing.expect(p.drain() == null); // 第二个 ESC 不入 pending(它回到 esc_seen)
    try testing.expect(p.pendingEsc()); // 仍卡在 esc_seen(等第三字节)
    try testing.expect(p.flushEsc().? == .esc); // 超时兑现第二个 ESC
}

test "KeyParser: ESC + 控制键(Ctrl+A)— ESC 兑现 + 控制键不丢" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed(0x01).? == .esc); // 0x01 = Ctrl+A
    try testing.expect(p.drain().? == .ctrl_a); // 控制键也保留(不吞)
    try testing.expect(p.drain() == null);
}

test "KeyParser: delete (ESC [ 3 ~)" {
    var p = KeyParser{};
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('3');
    try testing.expect(p.feed('~').? == .delete);
}

test "KeyParser: page_up (ESC [ 5 ~) / page_down (ESC [ 6 ~)" {
    var p = KeyParser{};
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('5');
    try testing.expect(p.feed('~').? == .page_up);
    // 状态复位后可解析下一个序列。
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('6');
    try testing.expect(p.feed('~').? == .page_down);
}

test "LineEditor: insert chars" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'h' });
    _ = try ed.handle(Key{ .char = 'i' });
    try testing.expectEqualStrings("hi", ed.view());
    try testing.expect(ed.cursor == 2);
}

test "LineEditor: backspace" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'a' });
    _ = try ed.handle(Key{ .char = 'b' });
    _ = try ed.handle(.backspace);
    try testing.expectEqualStrings("a", ed.view());
    try testing.expect(ed.cursor == 1);
}

test "LineEditor: backspace at beginning no-op" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    const a = try ed.handle(.backspace);
    try testing.expect(a == .none);
}

test "LineEditor: cursor left/right" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("abc") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.left);
    try testing.expect(ed.cursor == 2);
    _ = try ed.handle(.left);
    _ = try ed.handle(.left);
    try testing.expect(ed.cursor == 0);
    const a = try ed.handle(.left);
    try testing.expect(a == .none);
    _ = try ed.handle(.right);
    try testing.expect(ed.cursor == 1);
}

test "LineEditor: home / end" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("hello") |c| _ = try ed.handle(Key{ .char = c });
    try testing.expect(ed.cursor == 5);
    _ = try ed.handle(.home);
    try testing.expect(ed.cursor == 0);
    _ = try ed.handle(.end);
    try testing.expect(ed.cursor == 5);
}

test "LineEditor: ctrl_a / ctrl_e" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("xyz") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.ctrl_a);
    try testing.expect(ed.cursor == 0);
    _ = try ed.handle(.ctrl_e);
    try testing.expect(ed.cursor == 3);
}

test "LineEditor: insert mid-line" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("ac") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.left);
    _ = try ed.handle(Key{ .char = 'b' });
    try testing.expectEqualStrings("abc", ed.view());
    try testing.expect(ed.cursor == 2);
}

test "LineEditor: delete" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("abc") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.home);
    _ = try ed.handle(.delete);
    try testing.expectEqualStrings("bc", ed.view());
    try testing.expect(ed.cursor == 0);
}

test "LineEditor: ctrl_u kills line to start" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("hello world") |c| _ = try ed.handle(Key{ .char = c });
    // cursor at end: position 11. 先左移到 6
    for (0..5) |_| _ = try ed.handle(.left);
    try testing.expect(ed.cursor == 6);
    _ = try ed.handle(.ctrl_u); // 删除 [0,6) → "world"
    try testing.expectEqualStrings("world", ed.view());
    try testing.expect(ed.cursor == 0);
}

test "LineEditor: ctrl_k kills to end" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("hello world") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.home);
    for (0..5) |_| _ = try ed.handle(.right);
    _ = try ed.handle(.ctrl_k); // 删 " world"
    try testing.expectEqualStrings("hello", ed.view());
}

test "LineEditor: enter -> commit" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'a' });
    const a = try ed.handle(.enter);
    try testing.expect(a == .commit);
}

test "LineEditor: ctrl_c leaves the buffer to the prompt state" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'a' });
    try testing.expect((try ed.handle(.ctrl_c)) == .none);
    try testing.expectEqualStrings("a", ed.view());
}

test "LineEditor: ctrl_d deletes forward on a non-empty buffer" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "héllo");
    _ = try ed.handle(.home);
    _ = try ed.handle(.right); // after 'h'
    try testing.expect((try ed.handle(.ctrl_d)) == .redraw);
    try testing.expectEqualStrings("hllo", ed.view()); // the two-byte é is removed whole
    _ = try ed.handle(.end);
    try testing.expect((try ed.handle(.ctrl_d)) == .none); // nothing ahead of the cursor
    try testing.expectEqualStrings("hllo", ed.view());
    _ = try ed.handle(.ctrl_underscore); // undo restores the deleted char
    try testing.expectEqualStrings("héllo", ed.view());
}

test "LineEditor: ctrl_d on an empty buffer is eof" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.ctrl_d)) == .eof);
}

test "LineEditor: ctrl_d empty -> eof" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    const a = try ed.handle(.ctrl_d);
    try testing.expect(a == .eof);
}

test "LineEditor: ctrl_d non-empty -> none" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'a' });
    const a = try ed.handle(.ctrl_d);
    try testing.expect(a == .none);
}

test "LineEditor: 全局键(↑↓/Tab/Shift+Tab/Ctrl+R/T/O/G/L)不再归 editor → .none(已迁 dispatch)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    // 这些键由 dispatch(ui.zig)拦截解析,editor 兜底返 .none(防御:误加回会被此测抓)。
    try testing.expect((try ed.handle(.up)) == .none);
    try testing.expect((try ed.handle(.down)) == .none);
    try testing.expect((try ed.handle(.tab)) == .none);
    try testing.expect((try ed.handle(.shift_tab)) == .none);
    try testing.expect((try ed.handle(.ctrl_r)) == .none);
    try testing.expect((try ed.handle(.ctrl_t)) == .none);
    try testing.expect((try ed.handle(.ctrl_o)) == .none);
    try testing.expect((try ed.handle(.ctrl_g)) == .none);
    try testing.expect((try ed.handle(.ctrl_l)) == .none);
    try testing.expect((try ed.handle(.ctrl_x)) == .none);
}

test "LineEditor: setLine / reset" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try ed.setLine("history line");
    try testing.expectEqualStrings("history line", ed.view());
    try testing.expect(ed.cursor == 12);
    ed.reset();
    try testing.expect(ed.view().len == 0);
    try testing.expect(ed.cursor == 0);
}

test "LineEditor: insert UTF-8 bytes (Chinese)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    // 你 = 0xE4 0xBD 0xA0（3 字节 UTF-8）
    for ([_]u8{ 0xE4, 0xBD, 0xA0 }) |b| _ = try ed.handle(Key{ .char = b });
    try testing.expectEqualStrings("你", ed.view());
    try testing.expect(ed.cursor == 3);
}

test "LineEditor: backspace removes whole UTF-8 char" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ([_]u8{ 0xE4, 0xBD, 0xA0 }) |b| _ = try ed.handle(Key{ .char = b }); // 你
    for ([_]u8{ 0xE5, 0xA5, 0xBD }) |b| _ = try ed.handle(Key{ .char = b }); // 好
    try testing.expectEqualStrings("你好", ed.view());
    try testing.expect(ed.cursor == 6);
    _ = try ed.handle(.backspace);
    try testing.expectEqualStrings("你", ed.view());
    try testing.expect(ed.cursor == 3);
}

test "LineEditor: left moves by whole UTF-8 char" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ([_]u8{ 0xE4, 0xBD, 0xA0 }) |b| _ = try ed.handle(Key{ .char = b });
    for ([_]u8{ 0xE5, 0xA5, 0xBD }) |b| _ = try ed.handle(Key{ .char = b });
    try testing.expect(ed.cursor == 6);
    _ = try ed.handle(.left);
    try testing.expect(ed.cursor == 3); // 跳过 "好" 的 3 字节
    _ = try ed.handle(.left);
    try testing.expect(ed.cursor == 0);
}

test "LineEditor: delete removes whole UTF-8 char" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ([_]u8{ 0xE4, 0xBD, 0xA0 }) |b| _ = try ed.handle(Key{ .char = b });
    for ([_]u8{ 0xE5, 0xA5, 0xBD }) |b| _ = try ed.handle(Key{ .char = b });
    _ = try ed.handle(.home);
    _ = try ed.handle(.delete);
    try testing.expectEqualStrings("好", ed.view());
}

test "KeyParser: UTF-8 byte passes through as .char" {
    var p = KeyParser{};
    // 中文 "啊" = 0xE5 0x95 0x8A
    const e5 = p.feed(0xE5).?;
    try testing.expect(@as(std.meta.Tag(Key), e5) == .char);
    try testing.expect(e5.char == 0xE5);
}

test "KeyParser: Shift+Enter via CSI u" {
    var p = KeyParser{};
    // ESC [ 1 3 ; 2 u
    for ([_]u8{ 0x1b, '[', '1', '3', ';', '2' }) |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed('u').? == .shift_enter);
}

test "KeyParser: Ctrl+Enter via CSI u" {
    var p = KeyParser{};
    for ([_]u8{ 0x1b, '[', '1', '3', ';', '5' }) |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed('u').? == .ctrl_enter);
}

test "KeyParser: 无 mod CSI-u 文本键还原(Kitty disambiguate)" {
    // ESC[97u(无 ;mod)= 'a' → .char='a'(兼容把纯文本也 CSI-u 编码的终端)。
    var p = KeyParser{};
    for ([_]u8{ 0x1b, '[', '9', '7' }) |b| try testing.expect(p.feed(b) == null);
    const k = p.feed('u').?;
    try testing.expect(@as(std.meta.Tag(Key), k) == .char);
    try testing.expect(k.char == 'a');
}

test "KeyParser: 无 mod CSI-u Enter/Esc 还原" {
    // ESC[13u → .enter(无 mod Enter,非 0x20-0x7e 范围,须显式)
    var p1 = KeyParser{};
    for ([_]u8{ 0x1b, '[', '1', '3' }) |b| try testing.expect(p1.feed(b) == null);
    try testing.expect(p1.feed('u').? == .enter);
    // ESC[27u → .esc
    var p2 = KeyParser{};
    for ([_]u8{ 0x1b, '[', '2', '7' }) |b| try testing.expect(p2.feed(b) == null);
    try testing.expect(p2.feed('u').? == .esc);
}

test "KeyParser: CSI-u Esc with a modifier is still Esc" {
    // ESC[27;5u(Ctrl+Esc)/ESC[27;2u(Shift+Esc):反向搜索与 transcript viewer 靠它取消/关闭。
    for ([_][]const u8{ "\x1b[27;5u", "\x1b[27;2u" }) |seq| {
        var p = KeyParser{};
        for (seq[0 .. seq.len - 1]) |b| try testing.expect(p.feed(b) == null);
        try testing.expect(p.feed('u').? == .esc);
    }
}

test "KeyParser: CSI Delete still works" {
    var p = KeyParser{};
    for ([_]u8{ 0x1b, '[', '3' }) |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed('~').? == .delete);
}

test "KeyParser: CSI u with unknown mod falls back to Enter" {
    var p = KeyParser{};
    // ESC [ 13 ; 3 u  (mod=3 = Alt，我们不关心)
    for ([_]u8{ 0x1b, '[', '1', '3', ';', '3' }) |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed('u').? == .enter);
}

test "LineEditor: shift_enter inserts newline without commit" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'a' });
    const action = try ed.handle(.shift_enter);
    try testing.expect(action == .redraw);
    try testing.expectEqualStrings("a\n", ed.view());
    _ = try ed.handle(Key{ .char = 'b' });
    try testing.expectEqualStrings("a\nb", ed.view());
    // 真 enter 才 commit
    try testing.expect((try ed.handle(.enter)) == .commit);
}

test "LineEditor: ctrl_enter is no-op (对齐真 cc:只 shift_enter 换行)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'x' });
    const action = try ed.handle(.ctrl_enter);
    try testing.expect(action == .none); // 不换行、不提交
    try testing.expectEqualStrings("x", ed.view()); // 缓冲不变,无 \n
}

test "LineEditor: no-op actions (esc / unknown)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.esc)) == .none);
    try testing.expect((try ed.handle(.unknown)) == .none);
}

fn typeStr(ed: *LineEditor, s: []const u8) !void {
    for (s) |c| _ = try ed.handle(Key{ .char = c });
}

test "LineEditor: ctrl_w deletes previous word" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "hello world foo");
    _ = try ed.handle(.ctrl_w);
    try testing.expectEqualStrings("hello world ", ed.view());
    _ = try ed.handle(.ctrl_w);
    try testing.expectEqualStrings("hello ", ed.view());
}

test "LineEditor: ctrl_y yanks back ctrl_w deletion" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "alpha beta");
    _ = try ed.handle(.ctrl_w); // 删 "beta"
    try testing.expectEqualStrings("alpha ", ed.view());
    _ = try ed.handle(.ctrl_y); // 粘回
    try testing.expectEqualStrings("alpha beta", ed.view());
}

test "LineEditor: alt_b / alt_f word navigation" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "one two three");
    // cursor 在末尾
    _ = try ed.handle(.alt_b); // 回到 "three" 开头
    try testing.expectEqual(@as(usize, 8), ed.cursor); // "one two " = 8
    _ = try ed.handle(.alt_b); // "two" 开头
    try testing.expectEqual(@as(usize, 4), ed.cursor);
    _ = try ed.handle(.alt_f); // 跳过 "two" 到下个词末
    try testing.expectEqual(@as(usize, 7), ed.cursor);
}

test "LineEditor: Esc never edits the buffer (the prompt's double press clears)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.esc)) == .none);
    try typeStr(&ed, "hello");
    try testing.expect((try ed.handle(.esc)) == .none);
    try testing.expect((try ed.handle(.esc)) == .none);
    try testing.expectEqualStrings("hello", ed.view());
}

test "KeyParser: ctrl_t byte" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x14).? == .ctrl_t);
}

test "LineEditor: ctrl_k alone truncates (not kill)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "hello");
    ed.cursor = 2;
    try testing.expect((try ed.handle(.ctrl_k)) == .redraw);
    try testing.expectEqualStrings("he", ed.view());
}

test "KeyParser: ctrl_o / ctrl_x bytes" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x0f).? == .ctrl_o);
    try testing.expect(p.feed(0x18).? == .ctrl_x);
}

test "KeyParser: Ctrl+B byte + Kitty CSI-u(转后台键路径)" {
    // 裸字节 0x02 → .ctrl_b。
    var p = KeyParser{};
    try testing.expect(p.feed(0x02).? == .ctrl_b);
    // Kitty CSI-u 形式 ESC[98;5u(98='b',5=Ctrl)→ .ctrl_b(白名单终端会发这个而非 0x02)。
    var p2 = KeyParser{};
    inline for ("\x1b[98;5u") |c| {
        const k = p2.feed(c);
        if (c == 'u') try testing.expect(k.? == .ctrl_b);
    }
}

test "KeyParser: Ctrl+O via Kitty CSI-u (ESC[111;5u)" {
    // 实测 bug:Kitty disambiguate 模式下某些终端把 Ctrl+O 编成 CSI-u(111='o',5=Ctrl)
    // 而非裸 0x0f → 旧 CSI-u 表无 'o' → 返 .unknown → Ctrl+O 静默失效。覆盖该路径。
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('[') == null);
    try testing.expect(p.feed('1') == null);
    try testing.expect(p.feed('1') == null);
    try testing.expect(p.feed('1') == null);
    try testing.expect(p.feed(';') == null);
    try testing.expect(p.feed('5') == null);
    try testing.expect(p.feed('u').? == .ctrl_o);
    // 大写 'O'(79)同样映射(某些终端 Ctrl+Shift 变体)。
    var p2 = KeyParser{};
    inline for ("\x1b[79;5u") |c| {
        const k = p2.feed(c);
        if (c == 'u') try testing.expect(k.? == .ctrl_o);
    }
    // 其它新增覆盖键抽查:Ctrl+R(114) / Ctrl+T(116) 经 CSI-u 也能解。
    var p3 = KeyParser{};
    inline for ("\x1b[114;5u") |c| {
        const k = p3.feed(c);
        if (c == 'u') try testing.expect(k.? == .ctrl_r);
    }
}

test "KeyParser: ctrl_g byte" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x07).? == .ctrl_g);
}

test "KeyParser: shift_tab via ESC [ Z" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('[') == null);
    try testing.expect(p.feed('Z').? == .shift_tab);
}

test "KeyParser: alt_b / alt_f via ESC b / ESC f" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('b').? == .alt_b);
    var p2 = KeyParser{};
    try testing.expect(p2.feed(0x1b) == null);
    try testing.expect(p2.feed('f').? == .alt_f);
}

test "KeyParser: ctrl_w / ctrl_y / ctrl_l bytes" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x17).? == .ctrl_w);
    try testing.expect(p.feed(0x19).? == .ctrl_y);
    try testing.expect(p.feed(0x0c).? == .ctrl_l);
}

test "LineEditor: multi-key stream through KeyParser" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    var p = KeyParser{};
    const stream = "abc";
    for (stream) |b| {
        if (p.feed(b)) |k| _ = try ed.handle(k);
    }
    try testing.expectEqualStrings("abc", ed.view());
}

test "enterRawMode on non-tty returns null or restores cleanly" {
    const orig = enterRawMode(0);
    if (orig) |o| restoreMode(0, o);
}

test "an interrupted key read is retried unless the process is shutting down" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    defer shutdown.resetForTesting();
    // No resume is pending, so the fd is never touched.
    std.c._errno().* = @intFromEnum(std.c.E.INTR);
    try testing.expect(retryInterruptedRead(-1));
    // A real read failure still ends the reader.
    std.c._errno().* = @intFromEnum(std.c.E.IO);
    try testing.expect(!retryInterruptedRead(-1));
    // SIGINT asked the process to stop: the interrupted dialog ends as before.
    shutdown.request();
    std.c._errno().* = @intFromEnum(std.c.E.INTR);
    try testing.expect(!retryInterruptedRead(-1));
}

test "readKey assembles a sequence, reports a lone Esc once the wait runs out, and stops at end of input" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // pipe as the terminal
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    var parser = KeyParser{};
    try testing.expect(pfs.writeAll(fds[1], "\x1b[Aq\x1b"));
    try testing.expect(readKey(fds[0], &parser).key == .up);
    try testing.expectEqual(@as(u8, 'q'), readKey(fds[0], &parser).key.char);
    // Nothing follows the ESC: it is the Esc key, not the start of a sequence
    // that waits for the next key.
    try testing.expect(readKey(fds[0], &parser).key == .esc);
    _ = std.c.close(fds[1]);
    try testing.expect(readKey(fds[0], &parser) == .closed);
}

// The case #340 describes: the terminal's resize lands between ESC and `[`.
// The REPL's SIGWINCH handler has no SA_RESTART, so the wait for the rest of
// the sequence returns EINTR. It used to end the read (reverse search
// cancelled, viewer closed) and leave `[A` to be read as typed text.
test "a resize between ESC and [ interrupts readKey and leaves the sequence in the parser" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    defer shutdown.resetForTesting();
    var saved: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.WINCH, null, &saved);
    defer std.posix.sigaction(std.posix.SIG.WINCH, &saved, null);
    platform_signal.installResize(struct {
        fn onResize() void {}
    }.onResize);

    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try testing.expect(pfs.writeAll(fds[1], "\x1b"));

    const Reader = struct {
        fd: c_int,
        parser: KeyParser = .{},
        got: KeyRead = .closed,
        started: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.got = readKey(self.fd, &self.parser);
            self.finished.store(true, .release);
        }
    };
    var reader: Reader = .{ .fd = fds[0] };
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    while (!reader.started.load(.acquire)) std.Thread.yield() catch {};
    // Keep resizing until the reader is back: the first signal may land
    // before it blocks.
    var rounds: usize = 0;
    while (rounds < 100 and !reader.finished.load(.acquire)) : (rounds += 1) {
        @import("platform").sync.sleepMs(2);
        _ = std.c.pthread_kill(thread.getHandle(), std.posix.SIG.WINCH);
    }
    thread.join();
    try testing.expect(reader.got == .interrupted);
    try testing.expect(reader.parser.pendingEsc());

    try testing.expect(pfs.writeAll(fds[1], "[A"));
    try testing.expect(readKey(fds[0], &reader.parser).key == .up);
}

test "reconcileModes on a non-tty is a no-op" {
    if (@import("builtin").os.tag == .windows) return;
    const fd = pfs.openZ("/dev/null", .{ .ACCMODE = .RDONLY }, 0) catch unreachable;
    defer _ = pfs.close(fd);
    try testing.expect(!reconcileModes(fd));
}

test "键盘协议序列字节(接线:enter/restore 发的就是这些)" {
    // Kitty disambiguate(>1u)是 Warp/iTerm/kitty 等区分 Shift/Ctrl+Enter 的关键。
    // 实测:Warp 收到 \x1b[>1u 后 Shift+Enter 才发 \x1b[13;2u。
    try testing.expectEqualStrings("\x1b[<u\x1b[>1u\x1b[>4;2m", kbd_enable_seq);
    try testing.expectEqualStrings("\x1b[<u\x1b[>4m", kbd_disable_seq);
}

test "classifyKittyKeyboard:deny-list / 认得出 / 探测 分流矩阵" {
    const t = "xterm-256color";
    // deny-list(#23350 的教训):Apple Terminal、xterm.js 的宿主——不发也不问,探测答了也不算。
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard("Apple_Terminal", t, .none));
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard("vscode", t, .none));
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard("Hyper", t, .none));
    // 认得出的 TERM_PROGRAM(含实测追加的 Warp)→ 直接发,不问。
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("WarpTerminal", t, .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("iTerm.app", t, .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("WezTerm", t, .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("ghostty", t, .none));
    // TERM 子串命中(TERM_PROGRAM 可能不设,SSH 只带 TERM 过去)。
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard(null, "xterm-kitty", .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard(null, "xterm-ghostty", .none));
    // 认不出 → 问终端(SSH 远端、Linux 控制台、foot、Alacritty……)。
    try testing.expectEqual(KeyboardPolicy.probe, classifyKittyKeyboard(null, t, .none));
    try testing.expectEqual(KeyboardPolicy.probe, classifyKittyKeyboard("SomeNewTerminal", t, .none));
    try testing.expectEqual(KeyboardPolicy.probe, classifyKittyKeyboard(null, "linux", .none));
    // dumb / 没有 TERM(Windows console 常态)→ 什么都不发,也不问。
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard(null, null, .none));
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard(null, "", .none));
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard("iTerm.app", "dumb", .tmux));
    // TERM 认得出的终端先于 deny-list:从 Terminal.app / VS Code 里启动的 kitty、Ghostty 继承了
    // 外层的 TERM_PROGRAM,TERM 才是它自己设的。
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("Apple_Terminal", "xterm-kitty", .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("vscode", "xterm-ghostty", .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("Hyper", "xterm-kitty", .other));
    // tmux 照旧直接发;其它复用器照旧只看环境(答查询的是复用器自己,不问)。
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard(null, "screen-256color", .tmux));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("vscode", "tmux-256color", .tmux));
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard(null, "screen-256color", .other));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("ghostty", t, .other));
}

test "shouldEnableKittyKeyboard: 要探测的终端只在答了 Kitty flags 时才发,提示文案跟着走" {
    const saved = g_kitty_answered.load(.acquire);
    defer recordKeyboardProbe(saved);
    const shift = "shift + \xe2\x8f\x8e for newline";
    const backslash = "\\ + \xe2\x8f\x8e for newline";
    for ([_]bool{ true, false }) |answered| {
        recordKeyboardProbe(answered);
        const expected = switch (keyboardPolicy()) {
            .enable => true,
            .disable => false,
            .probe => answered,
        };
        try testing.expectEqual(expected, shouldEnableKittyKeyboard());
        try testing.expectEqualStrings(if (expected) shift else backslash, newlineHint());
    }
}

test "KeyParser: 迟到的终端应答整条吃掉,不漏成字符" {
    // DA1(Windows Terminal 实测的那条)、Kitty flags、OSC 之外的私有 CSI,以及 xterm 式
    // modifyOtherKeys 三段参数:每条报一个 .unknown,前后敲的字照常。
    var p = KeyParser{};
    const stream = "a\x1b[?61;4;6;7;14;21;22;23;24;28;32;42;52cb\x1b[?1uc\x1b[>4;2md\x1b[27;2;13~e\x1b[1;5Af";
    var chars: [8]u8 = undefined;
    var n_chars: usize = 0;
    var unknowns: usize = 0;
    for (stream) |b| {
        const k = p.feed(b) orelse continue;
        switch (k) {
            .char => |c| {
                chars[n_chars] = c;
                n_chars += 1;
            },
            .unknown => unknowns += 1,
            else => return error.TestUnexpectedResult,
        }
        try testing.expect(p.drain() == null);
    }
    try testing.expectEqualStrings("abcdef", chars[0..n_chars]);
    try testing.expectEqual(@as(usize, 5), unknowns);
}

/// 喂完 stream,按产出顺序收集全部键(含 drain 出的)。
fn parseAll(stream: []const u8, out: []Key) []Key {
    var p = KeyParser{};
    var n: usize = 0;
    for (stream) |b| {
        if (p.feed(b)) |k| {
            out[n] = k;
            n += 1;
        }
        while (p.drain()) |k| {
            out[n] = k;
            n += 1;
        }
    }
    if (p.flushEsc()) |k| {
        out[n] = k;
        n += 1;
        while (p.drain()) |k2| {
            out[n] = k2;
            n += 1;
        }
    }
    return out[0..n];
}

test "KeyParser: 迟到的背景色应答(OSC 11,BEL 或 ST 结尾)整条吃掉,前后的字照常" {
    var buf: [16]Key = undefined;
    const keys = parseAll("a\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\b\x1b]11;rgb:ffff/ffff/ffff\x07c", &buf);
    try testing.expectEqual(@as(usize, 5), keys.len);
    try testing.expectEqual(@as(u8, 'a'), keys[0].char);
    try testing.expect(keys[1] == .unknown);
    try testing.expectEqual(@as(u8, 'b'), keys[2].char);
    try testing.expect(keys[3] == .unknown);
    try testing.expectEqual(@as(u8, 'c'), keys[4].char);
}

test "KeyParser: Alt+] 后面不是 OSC 应答 → 还是 Esc、']' 和后面那几个键" {
    var buf: [16]Key = undefined;
    // Alt+] 后敲字母。
    var keys = parseAll("\x1b]x", &buf);
    try testing.expectEqual(@as(usize, 3), keys.len);
    try testing.expect(keys[0] == .esc);
    try testing.expectEqual(@as(u8, ']'), keys[1].char);
    try testing.expectEqual(@as(u8, 'x'), keys[2].char);
    // Alt+] 后敲数字再敲别的(数字原样还回来)。
    keys = parseAll("\x1b]12x", &buf);
    try testing.expectEqual(@as(usize, 5), keys.len);
    try testing.expect(keys[0] == .esc);
    try testing.expectEqualStrings("]12x", &[_]u8{ keys[1].char, keys[2].char, keys[3].char, keys[4].char });
    // Alt+] 后什么都不敲:等到 ESC 超时(flushEsc)兑现。
    var p = KeyParser{};
    for ("\x1b]") |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.pendingEsc());
    try testing.expect(p.flushEsc().? == .esc);
    try testing.expectEqual(@as(u8, ']'), p.drain().?.char);
    try testing.expect(p.drain() == null);
    // Alt+] 后 Alt+]:第二个 ESC 开新序列。
    keys = parseAll("\x1b]\x1b]", &buf);
    try testing.expectEqual(@as(usize, 4), keys.len);
    try testing.expect(keys[0] == .esc and keys[2] == .esc);
    try testing.expect(keys[1].char == ']' and keys[3].char == ']');
}

test "KeyParser: OSC 被控制键或别的序列截断 → 那个键照常" {
    var buf: [8]Key = undefined;
    var keys = parseAll("\x1b]11;rgb\r", &buf);
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expect(keys[0] == .enter);
    keys = parseAll("\x1b]11;rgb\x1b[A", &buf);
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expect(keys[0] == .up);
}

test "KeyParser: 读到一半的序列等不来后半截 → 超时兑现时丢掉,不吞下一个键" {
    // 探测到期时停在应答中间、或一个键被读切开,后半截被下一次进 raw 的 TCSAFLUSH 丢了:
    // 以前 parser 一直等终结字节,把用户接着敲的第一个字母当终结字节吃掉(`ls` → `s`)。
    const cut = [_][]const u8{ "\x1b[?62;", "\x1b]11;rgb:1e1e/", "\x1b[", "\x1b[1;5", "\x1b[12" };
    for (cut) |prefix| {
        var p = KeyParser{};
        for (prefix) |b| try testing.expect(p.feed(b) == null);
        try testing.expect(p.pendingEsc());
        try testing.expect(p.flushEsc() == null); // 序列作废,没有键
        try testing.expect(!p.pendingEsc());
        try testing.expectEqual(@as(u8, 'l'), p.feed('l').?.char);
        try testing.expectEqual(@as(u8, 's'), p.feed('s').?.char);
    }
    // OSC 里的 ESC 之后等不来 `\`:那个 ESC 是用户按的 Esc。
    var p = KeyParser{};
    for ("\x1b]11;x\x1b") |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.pendingEsc());
    try testing.expect(p.flushEsc().? == .esc);
    try testing.expectEqual(@as(u8, 'a'), p.feed('a').?.char);
}

test "KeyParser: rxvt 用 `$` 结尾的 Shift 组合键仍是一个键,不吞下一个键" {
    // urxvt/Eterm/aterm:Shift+Delete ESC[3$、Shift+Home/End ESC[7$/ESC[8$、Shift+F11/F12 ESC[23$/ESC[24$。
    for ([_][]const u8{ "\x1b[3$", "\x1b[7$", "\x1b[8$", "\x1b[23$", "\x1b[24$" }) |seq| {
        var buf: [8]Key = undefined;
        var stream: [16]u8 = undefined;
        @memcpy(stream[0..seq.len], seq);
        @memcpy(stream[seq.len..][0..3], " ab");
        const keys = parseAll(stream[0 .. seq.len + 3], &buf);
        try testing.expectEqual(@as(usize, 4), keys.len);
        try testing.expect(keys[0] == .unknown);
        try testing.expectEqualStrings(" ab", &[_]u8{ keys[1].char, keys[2].char, keys[3].char });
    }
}

test "KeyParser: Kitty 下的 Alt+B / Alt+F(CSI 98;3u / 102;3u)仍是词跳转" {
    var buf: [4]Key = undefined;
    var keys = parseAll("\x1b[98;3u\x1b[102;3u", &buf);
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expect(keys[0] == .alt_b and keys[1] == .alt_f);
    // 其它 Alt 组合认不出,整条一个 .unknown,不漏字符。
    keys = parseAll("\x1b[120;3u", &buf);
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expect(keys[0] == .unknown);
}

test "KeyParser: 被控制键或 ESC 截断的认不出 CSI 不吞那个键" {
    var p = KeyParser{};
    for ("\x1b[?6") |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed(0x03).? == .ctrl_c);
    for ("\x1b[?6") |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed(0x1b).? == .unknown);
    try testing.expect(p.pendingEsc());
    try testing.expect(p.feed('[') == null);
    try testing.expect(p.feed('A').? == .up);
}

test "newlineHint:返两种文案之一(随当前 env)" {
    // newlineHint 读真实 env;只断言它返回两种已知文案之一(避免依赖 CI env 具体值)。
    const h = newlineHint();
    const shift = "shift + \xe2\x8f\x8e for newline";
    const backslash = "\\ + \xe2\x8f\x8e for newline";
    try testing.expect(std.mem.eql(u8, h, shift) or std.mem.eql(u8, h, backslash));
    // 含义自洽:能发 Kitty ⇔ 显示 shift 方式。
    if (shouldEnableKittyKeyboard()) {
        try testing.expectEqualStrings(shift, h);
    } else {
        try testing.expectEqualStrings(backslash, h);
    }
}

test "LineEditor: backslash+return 行尾续行(Apple Terminal 换行)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("abc\\") |c| _ = try ed.handle(Key{ .char = c }); // 打 "abc\"
    const action = try ed.handle(.enter);
    try testing.expect(action == .redraw); // 不提交
    try testing.expectEqualStrings("abc\n", ed.view()); // 删 \ 插 \n
    try testing.expectEqual(@as(usize, 4), ed.cursor);
    // 续行后继续打字
    _ = try ed.handle(Key{ .char = 'd' });
    try testing.expectEqualStrings("abc\nd", ed.view());
}

test "LineEditor: 无尾 backslash 的 enter 仍提交" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("abc") |c| _ = try ed.handle(Key{ .char = c });
    try testing.expect((try ed.handle(.enter)) == .commit);
}

test "LineEditor: 行中 backslash 不触发续行" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try ed.setLine("a\\b"); // "a\b",cursor 在末尾
    ed.cursor = 2; // 光标在 '\' 后、'b' 前(行中,非行尾)
    try testing.expect((try ed.handle(.enter)) == .commit); // 不续行
}

test "LineEditor: backslash 续行可 undo" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("ab\\") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.enter); // 续行 → "ab\n"
    try testing.expectEqualStrings("ab\n", ed.view());
    _ = try ed.handle(.ctrl_underscore); // undo
    try testing.expectEqualStrings("ab\\", ed.view());
}

test "KeyParser: ctrl_underscore byte 0x1f" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1f).? == .ctrl_underscore);
}

test "LineEditor: undo 折叠 char 连打为一个单元" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "abc"); // 连续 char → 段首压一次快照(空串)
    try testing.expectEqualStrings("abc", ed.view());
    try testing.expect((try ed.handle(.ctrl_underscore)) == .redraw);
    try testing.expectEqualStrings("", ed.view()); // 整段回退到空
    try testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "LineEditor: undo 跨操作类型逐个回退" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "ab"); // 快照1:""(char 段首)
    _ = try ed.handle(.backspace); // 快照2:"ab" → 现 "a"
    try testing.expectEqualStrings("a", ed.view());
    try testing.expect((try ed.handle(.ctrl_underscore)) == .redraw);
    try testing.expectEqualStrings("ab", ed.view()); // undo backspace
    try testing.expect((try ed.handle(.ctrl_underscore)) == .redraw);
    try testing.expectEqualStrings("", ed.view()); // undo char 段
}

test "LineEditor: undo 空栈返回 none" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.ctrl_underscore)) == .none);
}

test "LineEditor: undo 栈深上限不下溢不泄漏" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    // 交替 char/backspace 制造 >50 个破坏性操作(每个都压快照)。
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        _ = try ed.handle(.{ .char = 'x' });
        _ = try ed.handle(.backspace);
    }
    // undo 到底:不下溢、不泄漏(testing.allocator 会抓泄漏)。
    var n: usize = 0;
    while (n < 130) : (n += 1) {
        if ((try ed.handle(.ctrl_underscore)) == .none) break;
    }
    try testing.expect((try ed.handle(.ctrl_underscore)) == .none); // 已见底
}

test "LineEditor: reset 清 undo 历史" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "hello");
    ed.reset();
    try testing.expect((try ed.handle(.ctrl_underscore)) == .none); // 历史已清
}
