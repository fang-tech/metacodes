//! L2 evidence: the guided API-key login for a provider without OAuth (the
//! GLM Coding Plan) checks the pasted key, stores it in that provider's own
//! file, and the next request on that provider — and only that provider —
//! authenticates with it.
//!
//! Before: `login --provider zai-coding-plan` refused ("declares no OAuth
//! token endpoint"), a Z.AI key could live only in an environment variable,
//! and a `/model` pick of a Z.AI model without one ended in
//! `MissingCredentials`.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const App = cc.app_module.App;
const Slug = cc.provider_ids.Slug;
const provider_login = cc.api_provider_login;
const key_store = cc.provider_api_key_store;
const picker_host = cc.repl_picker_host;

const GOOD_KEY = "plan-key-good";
const MODELS_OK = "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5.3\"}]}";
const ANTHROPIC_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .allocator = allocator, .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            self.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

const cleared_variables = [_][*:0]const u8{
    "ZAI_API_KEY",
    "GLM_API_KEY",
    "Z_AI_API_KEY",
    "OPENAI_API_KEY",
    "METASK_API_KEY",
    "METASK_GATEWAY_URL",
    "METACODES_PROVIDER",
    "METACODES_KEY_CHECK_URL",
    "METACODES_CONFIG_FILE",
};

/// A scratch state root as HOME, every key variable cleared, no probe, no KG.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [cleared_variables.len + 4]EnvGuard,
    guard_count: usize,

    fn init(self: *Case) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.guard_count = 0;
        self.root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        for (cleared_variables) |name| try self.setEnv(name, null);
        try self.setEnv("HOME", (try self.arena.allocator().dupeZ(u8, self.root)).ptr);
        try self.setEnv("METACODES_NO_PROBE", "1");
        try self.setEnv("METACODES_KG_AUTOSTART", "0");
    }

    fn setEnv(self: *Case, name: [*:0]const u8, value: ?[*:0]const u8) !void {
        for (self.guards[0..self.guard_count]) |*guard| {
            if (std.mem.orderZ(u8, guard.name, name) == .eq) {
                if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
                return;
            }
        }
        self.guards[self.guard_count] = try EnvGuard.set(self.arena.allocator(), name, value);
        self.guard_count += 1;
    }

    /// Point the key check at `server` (`METACODES_KEY_CHECK_URL`).
    fn checkAt(self: *Case, server: *harness.MockServer) !void {
        const url = try server.urlOwned(self.arena.allocator());
        const origin = url[0 .. url.len - "/v1/messages".len];
        const check = try std.fmt.allocPrintSentinel(self.arena.allocator(), "{s}/api/coding/paas/v4/models", .{origin}, 0);
        try self.setEnv("METACODES_KEY_CHECK_URL", check.ptr);
    }

    fn deinit(self: *Case) void {
        var index = self.guard_count;
        while (index > 0) {
            index -= 1;
            self.guards[index].restore();
        }
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn config(self: *Case, argv: []const [*:0]const u8) !cc.types_mod.Config {
        var parsed = cc.parseArgsForTest(argv, self.arena.allocator());
        try std.testing.expect(parsed.parse_error == null);
        parsed.state_root = self.root;
        return parsed;
    }
};

fn zaiProfile(registry: *cc.provider_registry.ProviderRegistry) *const cc.provider_profile.ProviderProfile {
    return registry.find("zai-coding-plan").?;
}

fn requestLine(captured: harness.CapturedRequest) []const u8 {
    const end = std.mem.indexOf(u8, captured.raw, "\r\n") orelse captured.raw.len;
    return captured.raw[0..end];
}

fn headerValue(captured: harness.CapturedRequest, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, captured.raw, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn runKey(case: *Case, io: std.Io, key: []const u8) !void {
    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    const prepared = try provider_login.prepareApiKey(zaiProfile(&registry), "cn-personal", null, key, .{ .state_root = case.root });
    _ = try prepared.run(std.testing.allocator, io, cc.api_oauth_login.stderrNotify(), null);
}

test "L2 key login: a key the check accepts is stored; a refused or unchecked one is not" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    var io_runtime = @import("platform").signal.threadedIo(case.arena.allocator(), .{});
    defer io_runtime.deinit();
    const zai = Slug.lit("zai-coding-plan");

    // Refused (401): nothing is stored.
    {
        var server = try harness.MockServer.startWithStatus("{\"error\":{\"message\":\"unauthorized\"}}", 0, "HTTP/1.1 401 Unauthorized");
        defer server.stop();
        try case.checkAt(server);
        try std.testing.expectError(error.KeyRefused, runKey(&case, io_runtime.io(), "  plan-key-bad \n"));
        try std.testing.expectEqualStrings("GET /api/coding/paas/v4/models HTTP/1.1", requestLine(server.lastRequest().?));
        // Surrounding whitespace from a paste is not part of the key.
        try std.testing.expectEqualStrings("Bearer plan-key-bad", headerValue(server.lastRequest().?, "authorization").?);
        try std.testing.expect(try key_store.load(std.testing.allocator, case.root, zai) == null);
    }
    // The check could not be made (500): nothing is stored either.
    {
        var server = try harness.MockServer.startWithStatus("{}", 0, "HTTP/1.1 500 Internal Server Error");
        defer server.stop();
        try case.checkAt(server);
        try std.testing.expectError(error.KeyCheckFailed, runKey(&case, io_runtime.io(), GOOD_KEY));
        try std.testing.expect(try key_store.load(std.testing.allocator, case.root, zai) == null);
    }
    // Accepted (200): stored as the Coding Plan kind, with its page.
    {
        var server = try harness.MockServer.start(MODELS_OK, 0);
        defer server.stop();
        try case.checkAt(server);
        try runKey(&case, io_runtime.io(), GOOD_KEY);
        var stored = (try key_store.load(std.testing.allocator, case.root, zai)).?;
        defer stored.deinit();
        try std.testing.expectEqualStrings(GOOD_KEY, stored.secret);
        try std.testing.expectEqual(cc.provider_credential.CredentialKind.zai_coding_plan_api_key, stored.kind);
        try std.testing.expectEqualStrings("cn-personal", stored.page.?);
    }
}

test "L2 key login: a 200 that is not the provider's answer stores nothing" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    var io_runtime = @import("platform").signal.threadedIo(case.arena.allocator(), .{});
    defer io_runtime.deinit();
    // A captive portal's page, and Z.AI's own 200-with-failure shape.
    for ([_][]const u8{
        "<html><body>Sign in to the network</body></html>",
        "{\"success\":false,\"code\":401,\"msg\":\"token invalid\"}",
    }) |body| {
        var server = try harness.MockServer.start(body, 0);
        defer server.stop();
        try case.checkAt(server);
        try std.testing.expectError(error.KeyCheckFailed, runKey(&case, io_runtime.io(), GOOD_KEY));
        try std.testing.expect(try key_store.load(std.testing.allocator, case.root, Slug.lit("zai-coding-plan")) == null);
    }
}

test "L2 key login: a key never follows a redirect, from the check or any catalog GET" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();

    // The redirect goes to another host name for the same listener's address
    // family: `localhost` is not `127.0.0.1`, so std's client treats it as a
    // different domain.
    var target = try harness.MockServer.start(MODELS_OK, 0);
    defer target.stop();
    const location = try std.fmt.allocPrint(allocator, "location: http://localhost:{d}/api/coding/paas/v4/models\r\n", .{target.port});
    var redirect = try harness.MockServer.startRepeatingStatus("", "HTTP/1.1 302 Found", location);
    defer redirect.stop();
    try case.checkAt(redirect);

    // The key check stops at the redirect: the host that would answer never
    // saw the key, so its answer proves nothing.
    try std.testing.expectError(error.KeyCheckFailed, runKey(&case, io_runtime.io(), GOOD_KEY));
    try std.testing.expectEqual(@as(usize, 0), target.requestCount());
    try std.testing.expect(try key_store.load(std.testing.allocator, case.root, Slug.lit("zai-coding-plan")) == null);

    // Any catalog GET carrying a credential: std's client would re-send the
    // header to whatever host the redirect names.
    const url = try redirect.urlOwned(allocator);
    const models_url = try std.fmt.allocPrint(allocator, "{s}/api/coding/paas/v4/models", .{url[0 .. url.len - "/v1/messages".len]});
    try std.testing.expectError(error.HttpError, cc.api_catalog_fetch.fetch(std.testing.allocator, io_runtime.io(), .{ .url = models_url, .bearer = GOOD_KEY }));
    try std.testing.expectEqualStrings("Bearer " ++ GOOD_KEY, headerValue(redirect.lastRequest().?, "authorization").?);
    try std.testing.expectEqual(@as(usize, 0), target.requestCount());

    // A public catalog still follows it.
    const answer = try cc.api_catalog_fetch.fetch(std.testing.allocator, io_runtime.io(), .{ .url = models_url });
    defer std.testing.allocator.free(answer.body);
    const followed = target.lastRequest() orelse return error.RedirectNotFollowed;
    try std.testing.expect(headerValue(followed, "authorization") == null);
}

test "L2 key login: a stored key starts a Z.AI session and reaches its requests, and no other provider's" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();
    try key_store.save(std.testing.allocator, case.root, Slug.lit("zai-coding-plan"), .zai_coding_plan_api_key, GOOD_KEY, "cn-personal", 1);

    // Startup: no variable holds a key; the store answers for Z.AI.
    {
        const argv = [_][*:0]const u8{ "metacodes", "--provider", "zai-coding-plan" };
        const config = try case.config(&argv);
        const secret = try cc.resolveProviderScopedSecret(std.testing.allocator, config, "zai-coding-plan");
        defer std.testing.allocator.free(secret);
        try std.testing.expectEqualStrings(GOOD_KEY, secret);
        // ...and not for OpenAI.
        try std.testing.expectError(error.MissingCredentials, cc.resolveProviderScopedSecret(std.testing.allocator, config, "openai"));
    }

    // A session on the Z.AI route sends it.
    var server = try harness.MockServer.start(ANTHROPIC_END_TURN_SSE, 0);
    defer server.stop();
    const messages_url = try allocator.dupeZ(u8, try server.urlOwned(allocator));
    const argv = [_][*:0]const u8{ "metacodes", "--provider", "zai-coding-plan", "--model", "glm-5.3", "--base-url", messages_url.ptr };
    const config = try case.config(&argv);
    const secret = try cc.resolveProviderScopedSecret(std.testing.allocator, config, "zai-coding-plan");
    defer std.testing.allocator.free(secret);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, secret);
    defer app.deinit();
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = try app.provider().sendStream(&messages, null, null, null, null, null, "");
    while (try handle.next()) |event| switch (event) {
        .text => |text| app.allocator.free(text),
        else => {},
    };
    handle.deinit();
    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expectEqualStrings("POST /v1/messages HTTP/1.1", requestLine(captured));
    try std.testing.expectEqualStrings("Bearer " ++ GOOD_KEY, headerValue(captured, "authorization").?);
}

test "L2 key login: a /model pick without a key takes the pasted key, stores it, and applies the route" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();
    var check = try harness.MockServer.start(MODELS_OK, 0);
    defer check.stop();
    try case.checkAt(check);

    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const argv = [_][*:0]const u8{"metacodes"};
    const app = try App.init(std.testing.allocator, io_runtime.io(), try case.config(&argv), "metask-key");
    defer app.deinit();

    var ui: cc.tui_ui_state.UiState = .{};
    picker_host.open(app, &ui);
    for ("zai-coding-plan") |byte| _ = picker_host.onKey(app, &ui, .{ .char = byte });
    _ = picker_host.onKey(app, &ui, .enter); // provider
    _ = picker_host.onKey(app, &ui, .enter); // GLM-5.3, listed first
    _ = picker_host.onKey(app, &ui, .enter); // its first channel (cn-anthropic)
    _ = picker_host.onKey(app, &ui, .enter); // options: apply → no key
    const picker = &app.model_picker;
    try std.testing.expectEqual(cc.repl_model_picker.Stage.credential, picker.stage);
    try std.testing.expectEqual(cc.repl_model_picker.CredentialMode.paste_key, picker.credential_mode);
    // The plan page for the channel's region is the one offered first.
    try std.testing.expectEqualStrings("China · Personal Coding Plan", picker.keyChoices()[picker.key_choice].label);

    for (GOOD_KEY) |byte| _ = picker_host.onKey(app, &ui, .{ .char = byte });
    try std.testing.expectEqual(picker_host.Result.redraw, picker_host.onKey(app, &ui, .enter));
    // The field is wiped as soon as the worker has its copy.
    try std.testing.expectEqual(@as(usize, 0), picker.key_len);

    // The idle tick settles the worker and retries the pending commit.
    var result: picker_host.Result = .ignored;
    var waited_ms: u32 = 0;
    while (app.login_worker != null) : (waited_ms += 10) {
        if (waited_ms > 10_000) return error.KeyLoginTimedOut;
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
        result = picker_host.poll(app, &ui);
    }
    try std.testing.expectEqual(picker_host.Result.committed, result);
    try std.testing.expectEqualStrings("glm-5.3", app.activeModel());
    try std.testing.expectEqualStrings("Bearer " ++ GOOD_KEY, headerValue(check.lastRequest().?, "authorization").?);
    var stored = (try key_store.load(std.testing.allocator, case.root, Slug.lit("zai-coding-plan"))).?;
    defer stored.deinit();
    try std.testing.expectEqualStrings(GOOD_KEY, stored.secret);
}

test "L2 key login: Esc during a key check that does not answer returns at once and stores nothing" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();
    var check = try harness.MockServer.start(MODELS_OK, 0);
    defer check.stop();
    try case.checkAt(check);
    check.gateNextResponse();

    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const argv = [_][*:0]const u8{"metacodes"};
    const app = try App.init(std.testing.allocator, io_runtime.io(), try case.config(&argv), "metask-key");
    var app_alive = true;
    defer if (app_alive) app.deinit();

    var ui: cc.tui_ui_state.UiState = .{};
    picker_host.open(app, &ui);
    for ("zai-coding-plan") |byte| _ = picker_host.onKey(app, &ui, .{ .char = byte });
    for (0..4) |_| _ = picker_host.onKey(app, &ui, .enter);
    try std.testing.expectEqual(cc.repl_model_picker.CredentialMode.paste_key, app.model_picker.credential_mode);
    for (GOOD_KEY) |byte| _ = picker_host.onKey(app, &ui, .{ .char = byte });
    _ = picker_host.onKey(app, &ui, .enter);
    // The check is on the wire and the server holds its answer.
    try check.waitUntilResponseGated();
    // Should Esc wait on the worker, it waits ~3 s for this and the timing
    // check below fails, rather than the test hanging.
    const Fallback = struct {
        fn release(server: *harness.MockServer, done: *std.atomic.Value(bool)) void {
            var waited_ms: u32 = 0;
            while (!done.load(.acquire) and waited_ms < 3_000) : (waited_ms += 10) {
                std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
            }
            server.releaseGatedResponse();
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const fallback = try std.Thread.spawn(.{}, Fallback.release, .{ check, &done });
    defer {
        done.store(true, .release);
        fallback.join();
    }

    const before = cc.util_time.nowMs();
    _ = picker_host.onKey(app, &ui, .escape);
    try std.testing.expect(cc.util_time.nowMs() - before < 1_000);
    try std.testing.expect(app.login_worker == null);
    try std.testing.expect(app.model_picker.stage != cc.repl_model_picker.Stage.credential);
    try std.testing.expect(std.mem.indexOf(u8, app.model_picker.notice(), "no key was stored") != null);

    // The answer arrives after the cancel: the parked worker drops it.
    done.store(true, .release);
    check.releaseGatedResponse();
    app.deinit();
    app_alive = false;
    try std.testing.expect(try key_store.load(std.testing.allocator, case.root, Slug.lit("zai-coding-plan")) == null);
}
