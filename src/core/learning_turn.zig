//! Learning turn: after a grounded host verdict, the conversation that did
//! the work distills what a fresh attempt should know into conditioned
//! lessons, then reconciles them with the lessons already stored for the task
//! (doc/LEARNING_TURN_DESIGN.md).
//!
//! Division of labour, the same as the sibling gates: the host decides
//! *whether* the turn runs (pure `decide`), supplies the verdict and the
//! stored lessons as evidence, binds the lesson header to what it saw, and
//! records what happened. It never authors, grades or enforces a lesson.
//!
//! The verdict source is the host check gate (`check_gate.zig`): the turn
//! attaches at the run's terminal boundary, after the gate and the Stop hook
//! let the answer stand. The answer is final before the first learning
//! message is appended; every assistant text a learning pass produces is
//! commentary. During a pass only read tools and `KgRemember` run, so the
//! checked workspace is the workspace the run hands back.
//!
//! Bounds: one learning turn per run, at most two passes (reconcile only
//! after an accepted lesson and only when stored lessons exist to reconcile
//! against), at most `PASS_MAX_TURNS` model turns per pass, at most
//! `lesson.MAX_PER_TURN` lessons. The two pass messages are one-time protocol
//! injections (host_injection_meter exclusion ①) and do not draw from the
//! advisory nudge budget.

const std = @import("std");
const check_gate = @import("check_gate.zig");
const lesson = @import("../kg/lesson.zig");

pub const MARKER = "[learning turn]";
pub const MAX_LEARNING_TURNS: u8 = 1;
/// Model turns per pass. A pass is a few reads and up to four writes.
pub const PASS_MAX_TURNS: u32 = 6;
/// Stored lessons listed in the distill message.
pub const MAX_EXISTING_SHOWN: usize = 6;
/// Tools that run during a learning pass; every other call is refused with a
/// tool error, so the workspace the check judged is the one the run returns.
pub const ALLOWED_TOOLS = [_][]const u8{ "Read", "Grep", "Glob", "KgRecall", "KgContext", "KgRemember" };

const MAX_LISTED_FAILURES: usize = 8;
const MAX_REASON_BYTES: usize = 200;
const MAX_TAIL_BYTES: usize = 1500;
const MAX_EXISTING_BYTES: usize = 600;

pub const Mode = enum { enforce, observe };

pub const Options = struct {
    mode: Mode,
    /// Host-declared task name (`METACODES_TASK_HINT` in headless runs).
    /// Borrowed for the run. Not a clean header token → project-wide lessons.
    task_hint: []const u8 = "",
    /// The host's name for this run in lesson headers (the journal run id in
    /// headless runs). Empty or not `[A-Za-z0-9_-]{1,64}` → the trace id.
    run_label: []const u8 = "",
};

/// What the host knows at the terminal boundary.
pub const Grounding = enum { unchecked, passed, failed, tainted, unavailable };

pub fn groundingOf(verdict: ?check_gate.Verdict) Grounding {
    const v = verdict orelse return .unchecked;
    return switch (v) {
        .passed => .passed,
        .failed => .failed,
        .tainted => .tainted,
        .unavailable => .unavailable,
    };
}

pub const Decision = enum {
    /// The run ended before its terminal boundary (abort, stall, budget, turn
    /// cap): the candidate is unfinished. Never returned by `decide`.
    none_unfinished,
    /// No check ran at this boundary's workspace: nothing grounds a lesson.
    none_unchecked,
    /// The check produced no verdict.
    none_unavailable,
    /// The run changed the check or weakened tests: a lesson would launder it.
    none_tainted,
    /// The run already had its learning turn.
    none_spent,
    distill,
};

/// The policy (LearningTurn.lean mirror, design §7). Pure; observe mode makes
/// the same decision and injects nothing.
pub fn decide(decisions: u8, grounding: Grounding) Decision {
    if (decisions >= MAX_LEARNING_TURNS) return .none_spent;
    return switch (grounding) {
        .unchecked => .none_unchecked,
        .unavailable => .none_unavailable,
        .tainted => .none_tainted,
        .passed, .failed => .distill,
    };
}

pub const Next = enum { reconcile, finish };

/// After the distill pass: reconcile only when a lesson was accepted and
/// stored lessons exist for it to be reconciled against.
pub fn afterDistill(accepted: u8, existing: usize) Next {
    return if (accepted > 0 and existing > 0) .reconcile else .finish;
}

pub const Phase = enum { idle, distill, reconcile };

/// Value-type summary for `RunResult.learning` and the terminal record.
pub const Report = struct {
    enforced: bool,
    grounding: Grounding,
    decision: Decision,
    passes: u8,
    distill_turns: u32,
    reconcile_turns: u32,
    lessons_accepted: u8,
    lessons_refused: u32,
    reconciled: u32,
    truncated: bool,
};

/// Run-local learning state. Lives in the agent loop's frame for the whole
/// run, so `binding` has a stable address while tools hold it.
pub const State = struct {
    decisions: u8 = 0,
    grounding: Grounding = .unchecked,
    decision: ?Decision = null,
    phase: Phase = .idle,
    passes: u8 = 0,
    pass_turns: u32 = 0,
    distill_turns: u32 = 0,
    reconcile_turns: u32 = 0,
    /// Lessons accepted when the distill pass ended (the rest came later).
    distill_accepted: u8 = 0,
    lessons_refused: u32 = 0,
    truncated: bool = false,
    existing: usize = 0,
    /// Rendered verdict of the latest check (owned), replaced on every check.
    verdict_text: ?[]u8 = null,
    run_buf: [lesson.MAX_RUN_BYTES]u8 = undefined,
    binding: lesson.Binding = .{ .verdict = .failed, .task = lesson.NO_TASK, .run = "" },

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.verdict_text) |text| allocator.free(text);
        self.verdict_text = null;
    }

    pub fn active(self: *const State) bool {
        return self.phase != .idle;
    }

    /// Record the latest check's verdict as text the distill message quotes.
    pub fn captureVerdict(self: *State, allocator: std.mem.Allocator, command: []const u8, outcome: *const check_gate.Outcome) void {
        const text = renderVerdict(allocator, command, outcome) catch return;
        if (self.verdict_text) |old| allocator.free(old);
        self.verdict_text = text;
    }

    /// Bind lesson headers for this run: the host's run label when it is a
    /// valid token, else the trace id.
    pub fn bind(self: *State, verdict: lesson.Verdict, options: Options, trace_id: [12]u8) void {
        const run = if (lesson.validRun(options.run_label)) blk: {
            @memcpy(self.run_buf[0..options.run_label.len], options.run_label);
            break :blk self.run_buf[0..options.run_label.len];
        } else std.fmt.bufPrint(&self.run_buf, "{x}", .{trace_id}) catch self.run_buf[0..0];
        self.binding = .{ .verdict = verdict, .task = lesson.taskToken(options.task_hint), .run = run };
    }

    /// Start of a turn inside a pass. False when the pass has used its turns.
    pub fn beginPassTurn(self: *State) bool {
        if (self.pass_turns >= PASS_MAX_TURNS) return false;
        self.pass_turns += 1;
        switch (self.phase) {
            .distill => self.distill_turns += 1,
            .reconcile => self.reconcile_turns += 1,
            .idle => {},
        }
        return true;
    }

    pub fn startPass(self: *State, phase: Phase) void {
        self.phase = phase;
        self.pass_turns = 0;
        self.passes += 1;
    }

    pub fn report(self: *const State, mode: Mode) Report {
        const accepted = self.binding.acceptedCount();
        return .{
            .enforced = mode == .enforce,
            .grounding = self.grounding,
            .decision = self.decision orelse .none_unfinished,
            .passes = self.passes,
            .distill_turns = self.distill_turns,
            .reconcile_turns = self.reconcile_turns,
            .lessons_accepted = accepted,
            .lessons_refused = self.lessons_refused,
            .reconciled = accepted -| self.distill_accepted,
            .truncated = self.truncated,
        };
    }
};

pub fn allowedDuringPass(tool_name: []const u8) bool {
    for (ALLOWED_TOOLS) |name| if (std.mem.eql(u8, name, tool_name)) return true;
    return false;
}

fn utf8Tail(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var start = text.len - max;
    while (start < text.len and (text[start] & 0xC0) == 0x80) start += 1;
    return text[start..];
}

fn writeOneLine(w: *std.Io.Writer, text: []const u8, max: usize) !void {
    for (lesson.boundedUtf8(text, max)) |c| try w.writeByte(if (c == '\n' or c == '\r' or c == '\t') ' ' else c);
}

/// The verdict as the distill message quotes it: outcome, counts, failing
/// names with reasons, and the tail of the output. Owned.
pub fn renderVerdict(allocator: std.mem.Allocator, command: []const u8, outcome: *const check_gate.Outcome) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("The host ran the pinned check `{s}` when you stopped.\n", .{command});
    switch (outcome.verdict) {
        .passed => try w.writeAll("Result: PASSED"),
        .failed => try w.print("Result: FAILED (exit code {d})", .{outcome.exit_code}),
        .tainted => try w.writeAll("Result: TAINTED (the run changed files the check runs or names, or weakened existing tests)"),
        .unavailable => try w.writeAll("Result: UNAVAILABLE (the check produced no verdict)"),
    }
    if (outcome.total > 0) try w.print(", {d}/{d} passed", .{ outcome.passed, outcome.total });
    try w.writeAll(".\n");
    if (outcome.parsed) |parsed| {
        var listed: usize = 0;
        var failing: usize = 0;
        for (parsed.results) |result| {
            if (result.kind != .failed or std.mem.eql(u8, result.name, "pinned check")) continue;
            failing += 1;
            if (listed == MAX_LISTED_FAILURES) continue;
            if (listed == 0) try w.writeAll("Failing:\n");
            listed += 1;
            try w.writeAll("- ");
            try writeOneLine(w, result.name, MAX_REASON_BYTES);
            const reason = if (result.message.len > 0) result.message else result.callsite;
            if (reason.len > 0) {
                try w.writeAll(": ");
                try writeOneLine(w, reason, MAX_REASON_BYTES);
            }
            try w.writeByte('\n');
        }
        if (failing > listed) try w.print("- … and {d} more\n", .{failing - listed});
    }
    if (outcome.verdict != .passed) {
        const tail = utf8Tail(outcome.output, MAX_TAIL_BYTES);
        if (tail.len > 0) {
            try w.writeAll("Output tail:\n");
            try w.writeAll(tail);
            if (tail[tail.len - 1] != '\n') try w.writeByte('\n');
        }
    }
    return out.toOwnedSlice();
}

const EVIDENCE_BOUNDARY =
    "What this verdict establishes: which checks passed or failed in the workspace you left. " ++
    "It does not establish why your approach succeeded or failed, and a pass does not establish " ++
    "that every requirement of the task was met.\n";

/// The distill message. `existing` are the stored lessons for this task,
/// newest first.
pub fn renderDistill(allocator: std.mem.Allocator, state: *const State, existing: []const lesson.Stored) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    var header_buf: [lesson.MAX_TASK_BYTES + 96]u8 = undefined;
    const header = state.binding.header(&header_buf);
    try w.writeAll(MARKER ++ " distill\n");
    try w.writeAll("Your answer above is final and has been delivered; nothing you do now changes it or the workspace. " ++
        "This is a learning turn: record what a fresh attempt at this task should know.\n\n");
    try w.writeAll(state.verdict_text orelse "The host ran the pinned check when you stopped.\n");
    try w.writeByte('\n');
    try w.writeAll(EVIDENCE_BOUNDARY);
    try w.writeAll("\nLessons already stored for this task (written after earlier verdicts; they may be wrong or stale):\n");
    if (existing.len == 0) try w.writeAll("(none)\n");
    for (existing) |stored| {
        try w.print("- node {d} [{s}] holds when: ", .{ stored.node_id, @tagName(stored.envelope.verdict) });
        try writeOneLine(w, stored.envelope.holds_when, 160);
        try w.writeAll(" — ");
        try writeOneLine(w, stored.envelope.lesson, MAX_EXISTING_BYTES);
        try w.writeByte('\n');
    }
    try w.print(
        "\nWrite 0 to {d} lessons, each with one KgRemember call, kind \"lesson\", whose text is exactly:\n" ++
            "{s}\n" ++
            "holds_when: <the condition under which this lesson applies>\n" ++
            "uncertain: <what the evidence did not settle>\n" ++
            "lesson: <what to do or avoid next time, and why, grounded in what you observed>\n" ++
            "supersedes: <node id of a stored lesson this one replaces; omit the line otherwise>\n\n",
        .{ lesson.MAX_PER_TURN, header },
    );
    try w.writeAll("Rules: copy the first line exactly; the host rejects any other header. ");
    if (state.binding.verdict == .failed)
        try w.writeAll("The verdict is FAILED: record what failed and what you would test next, never a claim that it works. ")
    else
        try w.writeAll("The verdict is PASSED for the checks that ran: record what made it work and, under uncertain, what the check did not cover. ");
    try w.writeAll("Make a causal claim only where your own trajectory supports it; put the rest under uncertain. " ++
        "Write nothing if this attempt taught nothing reusable. Only Read, Grep, Glob, KgRecall, KgContext and KgRemember run in this turn; " ++
        "do not change any file. End with one line saying what you recorded.");
    return out.toOwnedSlice();
}

/// The reconcile message, sent after the distill pass accepted a lesson.
pub fn renderReconcile(allocator: std.mem.Allocator, state: *const State) ![]u8 {
    const accepted = state.binding.acceptedCount();
    return std.fmt.allocPrint(
        allocator,
        MARKER ++ " reconcile\n" ++
            "You recorded {d} lesson(s). Now reconcile them with the lessons already stored for this task, listed in the previous message " ++
            "(KgRecall with the query \"" ++ lesson.MARKER ++ " task={s}\" finds them). For each stored lesson that today's evidence contradicts, " ++
            "narrows or replaces, write the corrected lesson with the same header and a `supersedes:` line naming it; " ++
            "do not leave a contradicted lesson standing beside a new one. You may write {d} more lesson(s) in this turn. " ++
            "If nothing needs reconciling, say so in one line and stop.",
        .{ accepted, state.binding.task, lesson.MAX_PER_TURN -| accepted },
    );
}

// ── tests (each named after the LearningTurn.lean theorem it mirrors) ──────

const testing = std.testing;

test "unavailable_never_learns / unchecked / tainted_never_learns" {
    try testing.expectEqual(Decision.none_unchecked, decide(0, .unchecked));
    try testing.expectEqual(Decision.none_unavailable, decide(0, .unavailable));
    try testing.expectEqual(Decision.none_tainted, decide(0, .tainted));
    try testing.expectEqual(Decision.distill, decide(0, .failed));
    try testing.expectEqual(Decision.distill, decide(0, .passed));
}

test "turns_bounded: any grounding after one decision is spent" {
    inline for (@typeInfo(Grounding).@"enum".fields) |field| {
        const g: Grounding = @enumFromInt(field.value);
        try testing.expectEqual(Decision.none_spent, decide(MAX_LEARNING_TURNS, g));
        try testing.expectEqual(Decision.none_spent, decide(MAX_LEARNING_TURNS + 3, g));
    }
}

test "reconcile_requires_lesson: no lesson or nothing stored means finish" {
    try testing.expectEqual(Next.finish, afterDistill(0, 5));
    try testing.expectEqual(Next.finish, afterDistill(2, 0));
    try testing.expectEqual(Next.reconcile, afterDistill(1, 1));
}

test "pass turns are capped per pass and counted per phase" {
    var state = State{};
    state.startPass(.distill);
    var used: u32 = 0;
    while (state.beginPassTurn()) used += 1;
    try testing.expectEqual(PASS_MAX_TURNS, used);
    try testing.expectEqual(PASS_MAX_TURNS, state.distill_turns);
    state.startPass(.reconcile);
    try testing.expect(state.beginPassTurn());
    try testing.expectEqual(@as(u32, 1), state.reconcile_turns);
    try testing.expectEqual(@as(u8, 2), state.passes);
}

test "only read tools and KgRemember run during a pass" {
    try testing.expect(allowedDuringPass("KgRemember"));
    try testing.expect(allowedDuringPass("Read"));
    try testing.expect(!allowedDuringPass("Write"));
    try testing.expect(!allowedDuringPass("Bash"));
    try testing.expect(!allowedDuringPass("Edit"));
}

test "distill message binds the exact header and states the evidence boundary" {
    const a = testing.allocator;
    var state = State{};
    defer state.deinit(a);
    state.bind(.failed, .{ .mode = .enforce, .task_hint = "etag" }, .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 });
    state.verdict_text = try a.dupe(u8, "Result: FAILED (exit code 1), 1/2 passed.\n");
    const text = try renderDistill(a, &state, &.{});
    defer a.free(text);
    try testing.expect(std.mem.startsWith(u8, text, MARKER ++ " distill"));
    try testing.expect(std.mem.indexOf(u8, text, "lesson-v1 verdict=failed task=etag run=0102030405060708090a0b0c\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "does not establish why") != null);
    try testing.expect(std.mem.indexOf(u8, text, "never a claim that it works") != null);
    try testing.expect(std.mem.indexOf(u8, text, "(none)") != null);
}

test "a spaced task hint makes the binding project-wide; a valid run label is used" {
    var state = State{};
    state.bind(.passed, .{ .mode = .enforce, .task_hint = "two words", .run_label = "trial-7" }, .{0} ** 12);
    try testing.expectEqualStrings(lesson.NO_TASK, state.binding.task);
    try testing.expectEqualStrings("trial-7", state.binding.run);
}

test "renderVerdict lists failing names and the output tail, not for a pass" {
    const a = testing.allocator;
    var failed = check_gate.Outcome{ .verdict = .failed, .exit_code = 1, .passed = 1, .total = 2, .output = try a.dupe(u8, "boom at line 3\n") };
    defer failed.deinit(a);
    const text = try renderVerdict(a, "sh run_tests", &failed);
    defer a.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "`sh run_tests`") != null);
    try testing.expect(std.mem.indexOf(u8, text, "FAILED (exit code 1), 1/2 passed") != null);
    try testing.expect(std.mem.indexOf(u8, text, "boom at line 3") != null);
    var passed = check_gate.Outcome{ .verdict = .passed, .passed = 2, .total = 2, .output = try a.dupe(u8, "all good\n") };
    defer passed.deinit(a);
    const ok = try renderVerdict(a, "sh run_tests", &passed);
    defer a.free(ok);
    try testing.expect(std.mem.indexOf(u8, ok, "PASSED, 2/2 passed") != null);
    try testing.expect(std.mem.indexOf(u8, ok, "all good") == null);
}
