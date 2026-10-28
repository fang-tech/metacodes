//! L2: a live AgentSession's provider credential replaced in place (issue
//! #336), proven at the requests the provider receives.
//!
//! - Concurrent `updateCredential` calls are linearized: the generations they
//!   return are one total order, each caller's in its own program order, and
//!   the request built after they all return carries the credential with the
//!   highest generation.
//! - An update refused for its bytes, its length, or memory during a Run
//!   changes nothing: the Run goes on and its next turn carries the old
//!   credential; the same candidate is accepted once memory allows.
//! - The same rule guards a credential at a Session's creation, and a fixed
//!   (CLI) credential before each request: a byte a header cannot carry is
//!   refused with an error instead of reaching the HTTP client, which asserts
//!   on CR LF, and nothing is sent.
//!
//! Cross-module: agent_session + credential_cell + provider factory +
//! Anthropic, OpenAI and Gemini transports.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn readToolSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_read\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_read\",\"name\":\"Read\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

const AcceptAll = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: u64, _: cc.ui_event.CoreEvent) bool {
        return true;
    }
};

fn subdir(tmp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, name);
    var sub = try tmp.dir.openDir(std.testing.io, name, .{});
    defer sub.close(std.testing.io);
    const len = try sub.realPath(std.testing.io, buffer);
    for (buffer[0..len]) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buffer[0..len];
}

/// The value of the authorization header the provider received in request
/// `index`.
fn authorization(server: *harness.MockServer, index: usize) ![]const u8 {
    const captured = server.requestAt(index) orelse return error.NoRequestCaptured;
    const head_end = std.mem.indexOf(u8, captured.raw, "\r\n\r\n") orelse return error.MalformedRequest;
    var lines = std.mem.splitSequence(u8, captured.raw[0..head_end], "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "authorization"))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return error.MissingAuthorization;
}

fn expectBearer(server: *harness.MockServer, index: usize, credential: []const u8) !void {
    const value = try authorization(server, index);
    try std.testing.expect(std.mem.startsWith(u8, value, "Bearer "));
    try std.testing.expectEqualStrings(credential, value["Bearer ".len..]);
}

const Updater = struct {
    session: *cc.agent_session.AgentSession,
    id: u8,
    /// The last generation this thread got and the credential it published.
    last_generation: u64 = 0,
    last: [32]u8 = undefined,
    last_len: usize = 0,
    out_of_order: bool = false,
    failed: bool = false,

    fn go(self: *Updater) void {
        var name: [32]u8 = undefined;
        for (0..50) |round| {
            const candidate = std.fmt.bufPrint(&name, "linear-t{d}-r{d}", .{ self.id, round }) catch unreachable;
            const generation = self.session.updateCredential(candidate) catch {
                self.failed = true;
                return;
            };
            if (generation <= self.last_generation) self.out_of_order = true;
            self.last_generation = generation;
            @memcpy(self.last[0..candidate.len], candidate);
            self.last_len = candidate.len;
        }
    }
};

const HeldRun = struct {
    session: *cc.agent_session.AgentSession,
    sink: cc.agent_session.EventSink,
    stop_reason: ?cc.agent_loop.StopReason = null,

    fn go(self: *HeldRun) void {
        const result = self.session.runText(1, "hold", 2, self.sink) catch return;
        self.stop_reason = result.stop_reason;
    }
};

test "L2 AgentSession concurrent credential updates linearize and the highest generation rides the next request" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "linear-initial",
        .model = "test-model",
        .base_url = url,
        .workspace = .{ .root = workspace },
        .allowed_tools = &.{},
    });
    defer session.destroy() catch unreachable;
    var sink_state: u8 = 0;
    const sink: cc.agent_session.EventSink = .{ .ctx = &sink_state, .emit = AcceptAll.emit };

    // The Run's stream is held open while four threads update; the request
    // already sent keeps the initial credential and finishes normally.
    server.gateNextResponse();
    var held = HeldRun{ .session = session, .sink = sink };
    const run_thread = try std.Thread.spawn(.{}, HeldRun.go, .{&held});
    try server.waitUntilResponseGated();
    var updaters: [4]Updater = undefined;
    var threads: [updaters.len]std.Thread = undefined;
    for (&updaters, 0..) |*updater, i| updater.* = .{ .session = session, .id = @intCast(i) };
    for (&threads, &updaters) |*thread, *updater| thread.* = try std.Thread.spawn(.{}, Updater.go, .{updater});
    for (threads) |thread| thread.join();
    server.releaseGatedResponse();
    run_thread.join();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, held.stop_reason.?);

    var last = &updaters[0];
    for (&updaters) |*updater| {
        try std.testing.expect(!updater.failed);
        try std.testing.expect(!updater.out_of_order);
        if (updater.last_generation > last.last_generation) last = updater;
    }
    // Generation 1 is the creation credential; every update took exactly one.
    try std.testing.expectEqual(@as(u64, 1 + updaters.len * 50), last.last_generation);
    try std.testing.expectEqual(last.last_generation, session.credential.currentGeneration());

    _ = try session.runText(2, "next", 2, sink);
    try expectBearer(server, 0, "linear-initial");
    try expectBearer(server, 1, last.last[0..last.last_len]);
}

/// Fails the first allocation of exactly `armed_len` bytes after arming,
/// from any thread, and passes everything else through.
const FailOnLength = struct {
    backing: std.mem.Allocator,
    armed_len: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(u32) = .init(0),

    fn allocator(self: *FailOnLength) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailOnLength = @ptrCast(@alignCast(ctx));
        if (len != 0 and self.armed_len.cmpxchgStrong(len, 0, .acq_rel, .acquire) == null) {
            _ = self.failures.fetchAdd(1, .acq_rel);
            return null;
        }
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailOnLength = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailOnLength = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailOnLength = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

/// A candidate of a length no other allocation of the Run shares, so the
/// armed failure lands on the update's own copy.
const UNALLOCATABLE = "unallocatable-" ++ ("k" ** 763);

const RefusingSink = struct {
    session: ?*cc.agent_session.AgentSession = null,
    failing: *FailOnLength,
    tried: bool = false,
    outcomes: [4]?anyerror = .{null} ** 4,

    fn emit(raw: *anyopaque, _: cc.session_id.SessionId, _: u64, event: cc.ui_event.CoreEvent) bool {
        const self: *RefusingSink = @ptrCast(@alignCast(raw));
        if (event != .tool_start or self.tried) return true;
        self.tried = true;
        const session = self.session.?;
        self.failing.armed_len.store(UNALLOCATABLE.len, .release);
        self.outcomes[0] = if (session.updateCredential(UNALLOCATABLE)) |_| null else |err| err;
        self.outcomes[1] = if (session.updateCredential("steady key")) |_| null else |err| err;
        self.outcomes[2] = if (session.updateCredential("")) |_| null else |err| err;
        self.outcomes[3] = if (session.updateCredential("k" ** (16 * 1024 + 1))) |_| null else |err| err;
        return true;
    }
};

test "L2 AgentSession refuses an invalid or unallocatable credential mid-Run and the Run goes on with the old one" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);
    const note = try std.fmt.allocPrint(a, "{s}/note.txt", .{workspace});
    defer a.free(note);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = note, .data = "steady" });
    const read_sse = try readToolSse(a, note);
    defer a.free(read_sse);
    const bodies = [_][]const u8{ read_sse, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var failing = FailOnLength{ .backing = a };
    const runtime = try cc.agent_session.AgentRuntime.create(failing.allocator(), .{ .builtin_tools = &.{"Read"} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "steady-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = workspace },
        .allowed_tools = &.{"Read"},
    });
    defer session.destroy() catch unreachable;
    var refusing = RefusingSink{ .session = session, .failing = &failing };
    const sink: cc.agent_session.EventSink = .{ .ctx = &refusing, .emit = RefusingSink.emit };

    const result = try session.runText(1, "read the note", 4, sink);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expect(refusing.tried);
    try std.testing.expectEqual(@as(u32, 1), failing.failures.load(.acquire));
    try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), refusing.outcomes[0]);
    try std.testing.expectEqual(@as(?anyerror, error.InvalidCredentialByte), refusing.outcomes[1]);
    try std.testing.expectEqual(@as(?anyerror, error.EmptyCredential), refusing.outcomes[2]);
    try std.testing.expectEqual(@as(?anyerror, error.CredentialTooLong), refusing.outcomes[3]);
    try std.testing.expectEqual(@as(u64, 1), session.credential.currentGeneration());
    // Both turns of the Run, the one after every refusal included, carried
    // the credential the Session started with.
    try expectBearer(server, 0, "steady-key");
    try expectBearer(server, 1, "steady-key");

    // With memory to spare, the same candidate is accepted for the next Run.
    try std.testing.expectEqual(@as(u64, 2), try session.updateCredential(UNALLOCATABLE));
    var quiet: u8 = 0;
    _ = try session.runText(2, "again", 2, .{ .ctx = &quiet, .emit = AcceptAll.emit });
    try expectBearer(server, 2, UNALLOCATABLE);
}

test "L2 AgentSession creation refuses a credential a request header cannot carry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);
    const runtime = try cc.agent_session.AgentRuntime.create(std.testing.allocator, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    const Refusal = struct { key: []const u8, err: anyerror };
    const refusals = [_]Refusal{
        .{ .key = "create-key\r\nx-injected: 1", .err = error.InvalidCredentialByte },
        .{ .key = "create key", .err = error.InvalidCredentialByte },
        .{ .key = "create-key-\xc3\xa9", .err = error.InvalidCredentialByte },
        .{ .key = "", .err = error.EmptyCredential },
        .{ .key = "k" ** (16 * 1024 + 1), .err = error.CredentialTooLong },
    };
    for (refusals) |refusal| {
        try std.testing.expectError(refusal.err, runtime.createSession(.{
            .provider_kind = .anthropic,
            .api_key = refusal.key,
            .model = "test-model",
            .workspace = .{ .root = workspace },
            .allowed_tools = &.{},
        }));
    }
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "k" ** (16 * 1024),
        .model = "test-model",
        .workspace = .{ .root = workspace },
        .allowed_tools = &.{},
    });
    try session.destroy();
}

fn sendOnce(provider: cc.api_provider.Provider) !void {
    const types = cc.types_mod;
    const messages = [_]types.ApiMessage{.{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} }};
    const handle = try provider.sendStream(&messages, null, null, null, null, null, "hi");
    handle.deinit();
}

test "L2 a fixed credential a header cannot carry fails its request before anything is sent, on every transport" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const kinds = [_]cc.types_mod.ProviderKind{ .anthropic, .openai, .gemini };

    // The CLI's credentials are fixed bytes from a flag, the environment, a
    // key file or a token response. One with CR LF used to reach the HTTP
    // client, whose header assertion ends the process.
    for (kinds) |kind| {
        for ([_][]const u8{ "fixed-key\r\nx-injected: 1", "fixed\nkey", "fixed key" }) |bad| {
            var owned = try cc.api_provider_factory.makeProvider(a, kind, bad, "test-model", url);
            defer owned.deinit();
            try std.testing.expectError(error.InvalidCredential, sendOnce(owned.provider()));
        }
    }
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());

    for (kinds) |kind| {
        var owned = try cc.api_provider_factory.makeProvider(a, kind, "fixed-good-key", "test-model", url);
        defer owned.deinit();
        try sendOnce(owned.provider());
    }
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    try expectBearer(server, 0, "fixed-good-key");
    try expectBearer(server, 1, "fixed-good-key");
    const gemini = server.requestAt(2) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, gemini.raw, "x-goog-api-key: fixed-good-key\r\n") != null);
}
