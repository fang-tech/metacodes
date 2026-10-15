//! L2: a sealed Skill (doc/SEALED_SKILL_PROTOCOL.md) runs end to end through
//! real modules: the reference gateway with its own model provider (a mock
//! Anthropic SSE server), the client's pin store and catalog, the forked
//! subagent loop with the gateway as its Provider, local tool execution, the
//! policy frame, and the usage ledger. Only the two process-external
//! boundaries (the model's HTTP and the gateway's HTTP) are mocked or
//! loopback-served.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;

const protocol = cc.skills_sealed_protocol;
const transport = cc.skills_sealed_transport;
const pin_mod = cc.skills_sealed_pin;
const gateway_mod = cc.skills_sealed_gateway;

const SECRET_BODY = "SECRET_SKILL_BODY: read the data file the user names and summarize it.";
const SKILL_MD = "---\nname: erp-post\ndescription: Posts invoices. Use when asked to post an invoice.\n---\n" ++ SECRET_BODY ++ "\n";

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_f\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":40,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"final-from-sealed\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// One assistant turn calling `tool` with `input_json` (already a JSON object).
fn toolCallSse(allocator: std.mem.Allocator, tool: []const u8, input_json: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(allocator);
    for (input_json) |c| switch (c) {
        '"' => try escaped.appendSlice(allocator, "\\\""),
        '\\' => try escaped.appendSlice(allocator, "\\\\"),
        else => try escaped.append(allocator, c),
    };
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_t\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":30,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{s}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":9}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ tool, escaped.items },
    );
}

fn writeFileAt(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    try cc.util_fs.mkdirParentsOf(path);
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (fd < 0) return error.FixtureWriteFailed;
    defer pfs.close(fd);
    const n = pfs.write(fd, bytes);
    if (n < 0 or @as(usize, @intCast(n)) != bytes.len) return error.FixtureWriteFailed;
}

fn readFileAt(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return null;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &chunk);
        if (n < 0) return error.FixtureReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return try out.toOwnedSlice(allocator);
}

const Host = struct {
    fn activate(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const []const u8) anyerror!void {}
};

/// Everything one scenario needs: the mock model, the gateway over it, and a
/// client whose catalog holds the pinned Skill.
const Lab = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    packages_dir: []u8,
    state_dir: []u8,
    data_path: []u8,
    model: *harness.MockServer,
    model_url: []u8,
    owned: cc.api_provider_factory.OwnedProvider,
    gateway: *gateway_mod.Gateway,
    server: *gateway_mod.Server,
    gateway_url: []u8,
    io_runtime: std.Io.Threaded,
    runtime: cc.skills_cli_adapter.Runtime,
    projection: cc.skills.SkillSet,
    registry: cc.tools_dynamic.DynRegistry,
    abort: cc.util_abort.AbortSignal,
    permission: cc.permission.PermissionContext,
    tool_defs: []cc.json_mod.ToolDefinition,
    host_token: u8 = 0,

    fn start(self: *Lab, allocator: std.mem.Allocator, tag: []const u8, cassette: []const []const u8, manifest_json: []const u8, options: gateway_mod.Options) !void {
        var root_buf: [512]u8 = undefined;
        const root_slice = cc.util_fs.testing.perPidDir(&root_buf, tag);
        const root = try allocator.dupe(u8, root_slice);
        _ = harness.normalizeSlashes(root);
        self.allocator = allocator;
        self.root = root;
        self.packages_dir = try std.fmt.allocPrint(allocator, "{s}/packages", .{root});
        self.state_dir = try std.fmt.allocPrint(allocator, "{s}/state", .{root});
        self.data_path = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{root});
        const md_path = try std.fmt.allocPrint(allocator, "{s}/erp-post/SKILL.md", .{self.packages_dir});
        defer allocator.free(md_path);
        try writeFileAt(allocator, md_path, SKILL_MD);
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/erp-post/manifest.json", .{self.packages_dir});
        defer allocator.free(manifest_path);
        try writeFileAt(allocator, manifest_path, manifest_json);
        try writeFileAt(allocator, self.data_path, "DATA_MARKER line one\n");
        try cc.util_fs.mkdirParents(self.state_dir);

        self.model = try harness.MockServer.startCassette(cassette, 0);
        self.model_url = try self.model.urlOwned(allocator);
        self.owned = try cc.api_provider_factory.makeProvider(allocator, .anthropic, "gateway-key", "claude-sonnet-4-20250514", self.model_url);
        self.gateway = try gateway_mod.Gateway.init(allocator, self.owned.provider(), self.packages_dir, options);
        self.server = try gateway_mod.Server.start(allocator, self.gateway, 0);
        self.gateway_url = try self.server.url(allocator);

        self.io_runtime = @import("platform").signal.threadedIo(allocator, .{});
        self.runtime = cc.skills_cli_adapter.Runtime.init(allocator, self.io_runtime.io());
        self.projection = cc.skills.SkillSet.init(allocator);
        self.registry = cc.tools_dynamic.DynRegistry.init(allocator);
        self.abort = cc.util_abort.AbortSignal.init();
        self.permission = .{ .mode = .init(.bypass_permissions), .allocator = allocator };
        self.tool_defs = try cc.tools.toToolDefinitions(allocator);
    }

    /// Install the Skill the way `metacodes sealed install` does: fetch the
    /// Entry from the gateway, verify it, pin it under the client state root.
    fn install(self: *Lab, token: []const u8) !void {
        var client = try transport.Client.init(self.allocator, self.io_runtime.io(), self.gateway_url, token);
        defer client.deinit();
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        try protocol.writeSkillsGetParams(&params.writer, "ssk_test");
        var response = try client.call(.skills_get, params.written(), null);
        defer response.deinit();
        const entry_json = response.response.result;
        var parsed = try protocol.parseEntry(self.allocator, entry_json);
        defer parsed.deinit();
        try pin_mod.write(self.allocator, self.state_dir, self.gateway_url, "", entry_json, &parsed.entry);
    }

    /// Load the client catalog from the pin root and register the Skill tool.
    fn loadCatalog(self: *Lab) !void {
        const pin_root = try pin_mod.pinRoot(self.allocator, self.state_dir);
        defer self.allocator.free(pin_root);
        const sources = [_]cc.skills_runtime.catalog.Source{.{
            .root = pin_root,
            .scope = .personal,
            .priority = 2005,
            .profile = .compat,
        }};
        try self.runtime.loadSources(self.root, "", "", &sources, &self.projection);
        try cc.skills_tool.registerSkillTool(&self.registry, &self.runtime);
        const model_defs = try cc.tools.toToolDefinitionsWithDyn(self.allocator, &self.registry);
        self.allocator.free(self.tool_defs);
        self.tool_defs = model_defs;
        if (!cc.skills_cli_adapter.applyModelToolSchema(self.tool_defs)) return error.SkillSchemaMissing;
    }

    fn context(self: *Lab) cc.tools.ToolContext {
        var ctx = cc.tools.ToolContext.withAbort(self.allocator, &self.abort);
        ctx.api_client = null;
        ctx.tool_defs = self.tool_defs;
        ctx.permission_ctx = &self.permission;
        ctx.dyn_registry = &self.registry;
        ctx.project_dir = self.root;
        ctx.cwd_abs = self.root;
        ctx.state_root = self.state_dir;
        ctx.session_id = "sess-sealed";
        ctx.host_services = .{ .ctx = @ptrCast(&self.host_token), .activateSkillFn = &Host.activate };
        return ctx;
    }

    fn runSkill(self: *Lab, invocation: []const u8) ![]u8 {
        var ctx = self.context();
        const entry = self.registry.find("Skill") orelse return error.SkillToolMissing;
        var body = try entry.execute(&ctx, invocation);
        defer body.deinit(self.allocator);
        return self.allocator.dupe(u8, body.@"inline".bytes);
    }

    fn ledger(self: *Lab) !?[]u8 {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/ledger/sealed.ndjson", .{self.state_dir});
        defer self.allocator.free(path);
        return readFileAt(self.allocator, path);
    }

    fn stop(self: *Lab) void {
        const a = self.allocator;
        self.registry.deinit();
        self.runtime.deinit();
        self.projection.deinit();
        a.free(self.tool_defs);
        self.io_runtime.deinit();
        self.server.stop();
        self.gateway.deinit();
        self.owned.deinit();
        self.model.stop();
        a.free(self.gateway_url);
        a.free(self.model_url);
        cc.util_fs.testing.rmrfBestEffort(self.root);
        a.free(self.data_path);
        a.free(self.state_dir);
        a.free(self.packages_dir);
        a.free(self.root);
        self.* = undefined;
    }
};

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| : (index = found + needle.len) count += 1;
    return count;
}

test "L2 sealed: brain on the gateway, hands on the client, charge in the ledger" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    // The body is server-only; the client runs the Read the model asks for.
    var pre_buf: [512]u8 = undefined;
    const pre_root = harness.normalizeSlashes(@constCast(cc.util_fs.testing.perPidDir(&pre_buf, "cc-zig-sealed-e2e")));
    const data_path = try std.fmt.allocPrint(a, "{s}/data.txt", .{pre_root});
    defer a.free(data_path);
    const read_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\"}}", .{data_path});
    defer a.free(read_input);
    const read_sse = try toolCallSse(a, "Read", read_input);
    defer a.free(read_sse);
    try lab.start(a, "cc-zig-sealed-e2e", &.{ read_sse, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    // The catalog shows the Skill as sealed with an empty-of-content body.
    const record = lab.runtime.findRecord("erp-post") orelse return error.SkillNotInCatalog;
    try std.testing.expect(record.definition.isSealed());
    try std.testing.expect(std.mem.indexOf(u8, record.definition.body, "SECRET") == null);

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"post the invoice in data.txt\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "(forked)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SECRET_SKILL_BODY") == null);

    // Model request 1: the Skill body as system prompt, the user's prompt,
    // the client's tool definitions; request 2: the locally executed result.
    try std.testing.expectEqual(@as(usize, 2), lab.model.requestCount());
    const first = lab.model.requestAt(0) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, first.body(), SECRET_BODY) != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "post the invoice in data.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "\"name\":\"Read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "gateway-key") == null);
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "DATA_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"tool_use_id\":\"tu_1\"") != null);

    // Ledger: two Steps and one charge, each carrying the gateway's cost.
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(ledger, "\"kind\":\"step\""));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(ledger, "\"kind\":\"charge\""));
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"cost_micros\":0,") == null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"skill_id\":\"ssk_test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"inference_gateway\":\"metacodes\"") != null);
}

test "L2 sealed: a call outside the pinned allowlist is refused locally and reported" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    var pre_buf: [512]u8 = undefined;
    const pre_root = harness.normalizeSlashes(@constCast(cc.util_fs.testing.perPidDir(&pre_buf, "cc-zig-sealed-policy")));
    const bash_input = try std.fmt.allocPrint(a, "{{\"command\":\"echo pwned > {s}/pwned.txt\"}}", .{pre_root});
    defer a.free(bash_input);
    const bash_sse = try toolCallSse(a, "Bash", bash_input);
    defer a.free(bash_sse);
    // The manifest allows Read only.
    const manifest = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"ssk_test\",\"version\":\"1.0.0\",\"name\":\"erp-post\",\"description\":\"Posts invoices.\",\"tools\":{\"allow\":[\"Read\"]},\"egress\":{\"classes\":[\"file_contents\"]}}";
    try lab.start(a, "cc-zig-sealed-policy", &.{ bash_sse, FINAL_SSE }, manifest, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);

    const pwned = try std.fmt.allocPrint(a, "{s}/pwned.txt", .{lab.root});
    defer a.free(pwned);
    try std.testing.expect((try readFileAt(a, pwned)) == null);
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"is_error\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "pwned") == null or std.mem.indexOf(u8, second.body(), "not allowed") != null or std.mem.indexOf(u8, second.body(), "denied") != null);
}

test "L2 sealed: bearer token gates the gateway" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    try lab.start(a, "cc-zig-sealed-auth", &.{FINAL_SSE}, protocol.TEST_MANIFEST_JSON, .{ .token = "t0k-secret" });
    defer lab.stop();

    var anonymous = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "");
    defer anonymous.deinit();
    try std.testing.expectError(error.Unauthorized, anonymous.call(.discover, "{}", null));

    var wrong = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "t0k-wrong");
    defer wrong.deinit();
    try std.testing.expectError(error.Unauthorized, wrong.call(.discover, "{}", null));

    var member = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "t0k-secret");
    defer member.deinit();
    var response = try member.call(.discover, "{}", null);
    defer response.deinit();
    try std.testing.expect(std.mem.indexOf(u8, response.response.result, protocol.PROTOCOL_ID) != null);
}

test "L2 sealed: a pin whose manifest changed on the gateway is refused, not run" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    try lab.start(a, "cc-zig-sealed-pin", &.{FINAL_SSE}, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");

    // The creator republishes with a wider allowlist; the gateway restarts.
    const manifest_path = try std.fmt.allocPrint(a, "{s}/erp-post/manifest.json", .{lab.packages_dir});
    defer a.free(manifest_path);
    const widened = try std.mem.replaceOwned(u8, a, protocol.TEST_MANIFEST_JSON, "\"allow\":[\"Read\"", "\"allow\":[\"Write\",\"Read\"");
    defer a.free(widened);
    try writeFileAt(a, manifest_path, widened);
    lab.server.stop();
    lab.gateway.deinit();
    lab.gateway = try gateway_mod.Gateway.init(a, lab.owned.provider(), lab.packages_dir, .{});
    lab.server = try gateway_mod.Server.start(a, lab.gateway, 0);
    a.free(lab.gateway_url);
    lab.gateway_url = try lab.server.url(a);
    // The pin still names the old gateway port; rewrite its URL only, keeping
    // the old digest, as a client whose gateway moved would.
    const pin_path = try std.fmt.allocPrint(a, "{s}/sealed-skills/erp-post/sealed.json", .{lab.state_dir});
    defer a.free(pin_path);
    const md_path = try std.fmt.allocPrint(a, "{s}/sealed-skills/erp-post/SKILL.md", .{lab.state_dir});
    defer a.free(md_path);
    try rewriteGatewayUrl(a, pin_path, lab.gateway_url);
    try rewriteGatewayUrl(a, md_path, lab.gateway_url);
    try lab.loadCatalog();

    try std.testing.expectError(error.SealedManifestChanged, lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}"));
    try std.testing.expectEqual(@as(usize, 0), lab.model.requestCount());
}

/// Replace the `http://127.0.0.1:<port>/ssp` URL inside a pin file.
fn rewriteGatewayUrl(a: std.mem.Allocator, path: []const u8, new_url: []const u8) !void {
    const bytes = (try readFileAt(a, path)) orelse return error.PinMissing;
    defer a.free(bytes);
    const start = std.mem.indexOf(u8, bytes, "http://127.0.0.1:") orelse return error.PinUrlMissing;
    const end = std.mem.indexOfPos(u8, bytes, start, "/ssp") orelse return error.PinUrlMissing;
    const rewritten = try std.mem.concat(a, u8, &.{ bytes[0..start], new_url, bytes[end + "/ssp".len ..] });
    defer a.free(rewritten);
    try writeFileAt(a, path, rewritten);
}
