//! L2: the learning turn (doc/LEARNING_TURN_DESIGN.md). After the host check
//! gate's verdict ends a run, the same conversation gets one distill message
//! that binds the lesson header to the verdict; lessons are KgRemember nodes
//! of kind `lesson`; a reconcile message follows only when a lesson was
//! accepted and stored lessons exist; only read tools and KgRemember run in a
//! pass; the attempt's answer stays the final result; observe mode and an
//! unchecked run inject nothing. Real TinyKG where a lesson is written.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const tinykg_binary = @import("tinykg_binary.zig");

const learning = cc.learning_turn;
const lesson = cc.kg_lesson;
const KgClient = cc.kg_client.KgClient;
const Event = cc.tools.tool_observation.Event;

/// Passes on every platform shell and names no file: the verdict is a clean
/// FAILED with no taint.
const FAILING_CHECK = "exit 1";
const RUN = "trial-7";
const TASK = "etag";

fn endTurn(allocator: std.mem.Allocator, id: []const u8, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, text },
    );
}

fn toolSse(allocator: std.mem.Allocator, id: []const u8, name: []const u8, input: []const u8) ![]u8 {
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(input, .{}, &escaped.writer);
    const encoded = try escaped.toOwnedSlice();
    defer allocator.free(encoded);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, id, name, encoded },
    );
}

fn jsonObject(allocator: std.mem.Allocator, pairs: []const [2][]const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeByte('{');
    for (pairs, 0..) |pair, index| {
        if (index > 0) try aw.writer.writeByte(',');
        try std.json.Stringify.encodeJsonString(pair[0], .{}, &aw.writer);
        try aw.writer.writeByte(':');
        try std.json.Stringify.encodeJsonString(pair[1], .{}, &aw.writer);
    }
    try aw.writer.writeByte('}');
    return aw.toOwnedSlice();
}

fn writeSse(allocator: std.mem.Allocator, id: []const u8, root: []const u8, name: []const u8, content: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
    defer allocator.free(path);
    const input = try jsonObject(allocator, &.{ .{ "file_path", path }, .{ "content", content } });
    defer allocator.free(input);
    return toolSse(allocator, id, "Write", input);
}

fn readSse(allocator: std.mem.Allocator, id: []const u8, root: []const u8, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
    defer allocator.free(path);
    const input = try jsonObject(allocator, &.{.{ "file_path", path }});
    defer allocator.free(input);
    return toolSse(allocator, id, "Read", input);
}

fn rememberSse(allocator: std.mem.Allocator, id: []const u8, kind: []const u8, text: []const u8) ![]u8 {
    const input = try jsonObject(allocator, &.{ .{ "kind", kind }, .{ "text", text } });
    defer allocator.free(input);
    return toolSse(allocator, id, "KgRemember", input);
}

fn envelope(allocator: std.mem.Allocator, verdict: []const u8, run: []const u8, body: []const u8, supersedes: ?u64) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("lesson-v1 verdict={s} task=" ++ TASK ++ " run={s}\n" ++
        "holds_when: the check runs against result.txt\n" ++
        "uncertain: whether other inputs fail the same way\n" ++
        "lesson: {s}", .{ verdict, run, body });
    if (supersedes) |id| try aw.writer.print("\nsupersedes: {d}", .{id});
    return aw.toOwnedSlice();
}

const RecordSink = struct {
    learning_records: usize = 0,
    last: ?@FieldType(Event, "learning_turn") = null,
    check_records: usize = 0,
    checks: u8 = 0,

    fn emit(raw: *anyopaque, event: Event) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .learning_turn => |record| {
                self.learning_records += 1;
                self.last = record;
            },
            .check_gate => |record| {
                self.check_records += 1;
                self.checks = record.checks;
            },
            else => {},
        }
        return true;
    }

    fn sink(self: *@This()) cc.tools.tool_observation.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
    }
};

const MAX_REQUESTS = 12;

const Run = struct {
    result: cc.agent_loop.RunResult,
    requests: usize,
    bodies: [MAX_REQUESTS]?[]u8 = [_]?[]u8{null} ** MAX_REQUESTS,
    record: RecordSink,
    final_text: ?[]u8 = null,

    fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        for (self.bodies) |entry| if (entry) |bytes| allocator.free(bytes);
        if (self.final_text) |text| allocator.free(text);
    }

    fn body(self: *const Run, index: usize) []const u8 {
        return self.bodies[index] orelse "";
    }

    fn markersIn(self: *const Run, index: usize, needle: []const u8) usize {
        return std.mem.count(u8, self.body(index), needle);
    }
};

const Config = struct {
    gate: ?cc.check_gate.Options = .{ .command = FAILING_CHECK, .mode = .observe },
    learning: ?learning.Options = .{ .mode = .enforce, .task_hint = TASK, .run_label = RUN },
    kg: ?*KgClient = null,
};

fn runLoop(allocator: std.mem.Allocator, root: []const u8, config: Config, responses: []const []const u8) !Run {
    var server = try harness.MockServer.startCassette(responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "key", "model", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "produce result.txt");
    var permission = cc.permission.createContext(.bypass_permissions, allocator);
    permission.no_interactive_prompt = true;
    const enabled = [_][]const u8{ "Read", "Write", "KgRemember", "KgRecall", "KgContext" };
    var defs_arena = std.heap.ArenaAllocator.init(allocator);
    defer defs_arena.deinit();
    var prompt_context = cc.tools.PromptContext{ .enabled_tool_names = &enabled };
    const defs = try cc.tools.toToolDefinitionsFull(defs_arena.allocator(), null, &prompt_context);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    var record = RecordSink{};
    var ledger = cc.output_semantics.Ledger.init(allocator);
    defer ledger.deinit();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 16,
            .system_prompt = "STABLE-PREFIX",
            .check_gate = config.gate,
            .learning_turn = config.learning,
            .kg = config.kg,
            .tool_observer = record.sink(),
            .output_ledger = &ledger,
            .cwd_abs = root,
            .project_dir = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    var out = Run{ .result = result, .requests = server.requestCount(), .record = record };
    var index: usize = 0;
    while (server.requestAt(index)) |request| : (index += 1) {
        if (index < MAX_REQUESTS) out.bodies[index] = try allocator.dupe(u8, request.body());
    }
    if (ledger.finalText()) |text| out.final_text = try allocator.dupe(u8, text);
    return out;
}

fn tmpRoot(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, buf)]);
}

const Kg = struct {
    client: KgClient,
    store: []u8,
    bin: []u8,

    fn open(allocator: std.mem.Allocator, root: []const u8) !?Kg {
        const bin = tinykg_binary.find(allocator) orelse return null;
        errdefer allocator.free(bin);
        const store = try std.fmt.allocPrint(allocator, "{s}/learning.kg", .{root});
        errdefer allocator.free(store);
        var client = try KgClient.init(allocator, .{
            .state_root = root,
            .domain = "proj-learning-turn",
            .config_bin = bin,
            .config_store = store,
            .env_bin = "",
            .env_store = "",
        });
        client.ensureReady();
        if (!client.ready) {
            client.deinit();
            allocator.free(store);
            allocator.free(bin);
            return null;
        }
        return .{ .client = client, .store = store, .bin = bin };
    }

    fn close(self: *Kg, allocator: std.mem.Allocator) void {
        self.client.deinit();
        allocator.free(self.store);
        allocator.free(self.bin);
    }
};

fn readFile(allocator: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer dir.close(std.testing.io);
    return dir.readFileAlloc(std.testing.io, name, allocator, .limited(1 << 16));
}

test "L2 learning turn: a failed verdict gets one distill pass, the lesson is stored, the answer stays final" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var kg = (try Kg.open(a, root)) orelse return error.SkipZigTest;
    defer kg.close(a);

    const write = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(write);
    const done = try endTurn(a, "done_1", "done");
    defer a.free(done);
    const text = try envelope(a, "failed", RUN, "compute TOTAL from the input instead of guessing it", null);
    defer a.free(text);
    const remember = try rememberSse(a, "remember_1", "lesson", text);
    defer a.free(remember);
    const recorded = try endTurn(a, "recorded", "recorded one lesson");
    defer a.free(recorded);
    var run = try runLoop(a, root, .{ .kg = &kg.client }, &.{ write, done, remember, recorded });
    defer run.deinit(a);

    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, run.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 4), run.requests);
    // The distill message rides request 3 (after the answer) and never earlier.
    try std.testing.expectEqual(@as(usize, 0), run.markersIn(1, learning.MARKER));
    try std.testing.expectEqual(@as(usize, 1), run.markersIn(2, learning.MARKER ++ " distill"));
    try std.testing.expect(std.mem.indexOf(u8, run.body(2), "Result: FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.body(2), "lesson-v1 verdict=failed task=etag run=trial-7") != null);
    try std.testing.expectEqual(@as(usize, 0), run.markersIn(3, learning.MARKER ++ " reconcile"));
    // The attempt's answer is the result; the learning text is commentary.
    try std.testing.expectEqualStrings("done", run.final_text.?);
    const report = run.result.learning.?;
    try std.testing.expectEqual(learning.Decision.distill, report.decision);
    try std.testing.expectEqual(@as(u8, 1), report.passes);
    try std.testing.expectEqual(@as(u8, 1), report.lessons_accepted);
    try std.testing.expect(!report.truncated);
    try std.testing.expectEqual(@as(usize, 1), run.record.learning_records);
    try std.testing.expect(run.record.last.?.enforced);
    try std.testing.expectEqual(@as(u8, 1), run.record.checks);
    const stored = try lesson.collectForTask(a, &kg.client, TASK, 4);
    defer lesson.freeStored(a, stored);
    try std.testing.expectEqual(@as(usize, 1), stored.len);
    try std.testing.expectEqual(lesson.Verdict.failed, stored[0].envelope.verdict);
}

test "L2 learning turn: with stored lessons an accepted lesson earns one reconcile pass, and supersedes retires the old one" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var kg = (try Kg.open(a, root)) orelse return error.SkipZigTest;
    defer kg.close(a);
    const seed_text = try envelope(a, "failed", "trial-6", "TOTAL is always 41", null);
    defer a.free(seed_text);
    const seed_id = try kg.client.remember(.observation, seed_text, lesson.SCHEMA_TYPE, false);

    const write = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(write);
    const done = try endTurn(a, "done_1", "done");
    defer a.free(done);
    const new_text = try envelope(a, "failed", RUN, "TOTAL depends on the input; 41 was wrong here too", seed_id);
    defer a.free(new_text);
    const remember = try rememberSse(a, "remember_1", "lesson", new_text);
    defer a.free(remember);
    const noted = try endTurn(a, "noted", "recorded and superseded");
    defer a.free(noted);
    const reconciled = try endTurn(a, "reconciled", "nothing else to reconcile");
    defer a.free(reconciled);
    var run = try runLoop(a, root, .{ .kg = &kg.client }, &.{ write, done, remember, noted, reconciled });
    defer run.deinit(a);

    try std.testing.expectEqual(@as(usize, 5), run.requests);
    // The stored lesson is quoted to the distill pass.
    try std.testing.expect(std.mem.indexOf(u8, run.body(2), "TOTAL is always 41") != null);
    try std.testing.expectEqual(@as(usize, 1), run.markersIn(4, learning.MARKER ++ " reconcile"));
    const report = run.result.learning.?;
    try std.testing.expectEqual(@as(u8, 2), report.passes);
    try std.testing.expectEqual(@as(u8, 1), report.lessons_accepted);
    try std.testing.expectEqualStrings("done", run.final_text.?);
    const stored = try lesson.collectForTask(a, &kg.client, TASK, 4);
    defer lesson.freeStored(a, stored);
    try std.testing.expectEqual(@as(usize, 1), stored.len);
    try std.testing.expectEqual(@as(?u64, seed_id), stored[0].envelope.supersedes);
}

test "L2 learning turn: a lesson outside a learning turn or with a lying header is refused" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var kg = (try Kg.open(a, root)) orelse return error.SkipZigTest;
    defer kg.close(a);

    const early_text = try envelope(a, "passed", RUN, "it works", null);
    defer a.free(early_text);
    const early = try rememberSse(a, "remember_0", "lesson", early_text);
    defer a.free(early);
    const write = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(write);
    const done = try endTurn(a, "done_1", "done");
    defer a.free(done);
    // The check FAILED; a header claiming a pass is not the host's header.
    const lying_text = try envelope(a, "passed", RUN, "it works", null);
    defer a.free(lying_text);
    const lying = try rememberSse(a, "remember_1", "lesson", lying_text);
    defer a.free(lying);
    const end = try endTurn(a, "end", "could not record");
    defer a.free(end);
    var run = try runLoop(a, root, .{ .kg = &kg.client }, &.{ early, write, done, lying, end });
    defer run.deinit(a);

    // Tool errors carry the detail, not the Zig error name.
    try std.testing.expect(std.mem.indexOf(u8, run.body(1), "is written only in a learning turn") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.body(4), "lesson header must be exactly") != null);
    const report = run.result.learning.?;
    try std.testing.expectEqual(@as(u8, 0), report.lessons_accepted);
    try std.testing.expectEqual(@as(u32, 1), report.lessons_refused); // only the pass's refusal counts
    const stored = try lesson.collectForTask(a, &kg.client, TASK, 4);
    defer lesson.freeStored(a, stored);
    try std.testing.expectEqual(@as(usize, 0), stored.len);
}

test "L2 learning turn: a write during a pass is refused and the checked workspace is what the run returns" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var kg = (try Kg.open(a, root)) orelse return error.SkipZigTest;
    defer kg.close(a);

    const write = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(write);
    const done = try endTurn(a, "done_1", "done");
    defer a.free(done);
    const sneaky = try writeSse(a, "write_2", root, "result.txt", "TOTAL=42\n");
    defer a.free(sneaky);
    const end = try endTurn(a, "end", "nothing recorded");
    defer a.free(end);
    var run = try runLoop(a, root, .{ .kg = &kg.client }, &.{ write, done, sneaky, end });
    defer run.deinit(a);

    try std.testing.expect(std.mem.indexOf(u8, run.body(3), "does not run in a learning turn") != null);
    const content = try readFile(a, root, "result.txt");
    defer a.free(content);
    try std.testing.expectEqualStrings("TOTAL=41\n", content);
    // The refused write did not make the run dirty: one check, nothing unchecked.
    try std.testing.expectEqual(@as(u8, 1), run.record.checks);
    try std.testing.expectEqualStrings("done", run.final_text.?);
}

test "L2 learning turn: a pass that keeps calling tools is cut at its turn cap" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var kg = (try Kg.open(a, root)) orelse return error.SkipZigTest;
    defer kg.close(a);

    const write = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(write);
    const done = try endTurn(a, "done_1", "done");
    defer a.free(done);
    var reads: [learning.PASS_MAX_TURNS][]u8 = undefined;
    var made: usize = 0;
    defer for (reads[0..made]) |r| a.free(r);
    var responses: [2 + learning.PASS_MAX_TURNS][]const u8 = undefined;
    responses[0] = write;
    responses[1] = done;
    while (made < learning.PASS_MAX_TURNS) : (made += 1) {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "read_{d}", .{made});
        reads[made] = try readSse(a, id, root, "result.txt");
        responses[2 + made] = reads[made];
    }
    var run = try runLoop(a, root, .{ .kg = &kg.client }, &responses);
    defer run.deinit(a);

    try std.testing.expectEqual(@as(usize, 2 + learning.PASS_MAX_TURNS), run.requests);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, run.result.stop_reason);
    const report = run.result.learning.?;
    try std.testing.expect(report.truncated);
    try std.testing.expectEqual(learning.PASS_MAX_TURNS, report.distill_turns);
    try std.testing.expectEqualStrings("done", run.final_text.?);
}

test "L2 learning turn: observe mode decides and injects nothing" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var kg = (try Kg.open(a, root)) orelse return error.SkipZigTest;
    defer kg.close(a);

    const write = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(write);
    const done = try endTurn(a, "done_1", "done");
    defer a.free(done);
    var run = try runLoop(a, root, .{ .kg = &kg.client, .learning = .{ .mode = .observe, .task_hint = TASK } }, &.{ write, done });
    defer run.deinit(a);

    try std.testing.expectEqual(@as(usize, 2), run.requests);
    try std.testing.expectEqual(@as(usize, 0), run.markersIn(1, learning.MARKER));
    const record = run.record.last.?;
    try std.testing.expect(!record.enforced);
    try std.testing.expectEqual(cc.tools.tool_observation.LearningDecision.distill, record.decision);
    try std.testing.expectEqual(@as(u8, 0), record.passes);
}

test "L2 learning turn: a grounded verdict with no ready store spends no request" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);

    const write = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(write);
    const done = try endTurn(a, "done_1", "done");
    defer a.free(done);
    var run = try runLoop(a, root, .{}, &.{ write, done });
    defer run.deinit(a);

    try std.testing.expectEqual(@as(usize, 2), run.requests);
    try std.testing.expectEqual(learning.Decision.none_unstorable, run.result.learning.?.decision);
    try std.testing.expectEqual(learning.Grounding.failed, run.result.learning.?.grounding);
    try std.testing.expectEqual(@as(u8, 0), run.record.last.?.passes);
}

test "L2 learning turn: without a check there is no verdict and no learning message" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);

    const write = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(write);
    const done = try endTurn(a, "done_1", "done");
    defer a.free(done);
    var run = try runLoop(a, root, .{ .gate = null }, &.{ write, done });
    defer run.deinit(a);

    try std.testing.expectEqual(@as(usize, 2), run.requests);
    try std.testing.expectEqual(learning.Decision.none_unchecked, run.result.learning.?.decision);
    try std.testing.expectEqual(cc.tools.tool_observation.LearningDecision.none_unchecked, run.record.last.?.decision);
}

test "L2 same-task lessons note: newest unsuperseded lessons for the hinted task, nothing without one" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var kg = (try Kg.open(a, root)) orelse return error.SkipZigTest;
    defer kg.close(a);
    const paths = @import("platform").paths;
    paths.setEnv("METACODES_TASK_HINT", TASK);
    defer paths.unsetEnv("METACODES_TASK_HINT");

    try std.testing.expect(cc.kg_scoped_recall.sameTaskLessonsNote(a, &kg.client) == null);
    const old_text = try envelope(a, "failed", "trial-5", "the first reading", null);
    defer a.free(old_text);
    const old_id = try kg.client.remember(.observation, old_text, lesson.SCHEMA_TYPE, false);
    const new_text = try envelope(a, "passed", "trial-6", "the corrected reading", old_id);
    defer a.free(new_text);
    _ = try kg.client.remember(.observation, new_text, lesson.SCHEMA_TYPE, false);

    const note = cc.kg_scoped_recall.sameTaskLessonsNote(a, &kg.client).?;
    defer a.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, lesson.NOTE_HEADING) != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "the corrected reading") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "the first reading") == null);
}
