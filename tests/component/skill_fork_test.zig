//! L2 coverage for fork execution through the canonical shared Skill Runtime.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;

const MINIMAL_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"forked-reply\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const READ_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tool\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_read\",\"name\":\"Read\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// Per-process fixture root `<tmp>/<tag>-<pid>` (util/fs.zig testing.tmpRoot decides the
/// platform root). A fixed `/tmp/...` literal is shared by all parallel shards and, on
/// Windows, is resolved by the CRT against the process's current drive; neither is a
/// property this test should depend on.
fn fixtureRoot(buf: []u8, tag: []const u8) [:0]const u8 {
    return cc.util_fs.testing.perPidDir(buf, tag);
}

fn mkdirOrExisting(path: [*:0]const u8) !void {
    if (pfs.mkdir(path, 0o755) == 0) return;
    if (pfs.exists(path)) return;
    return fixtureFailure("mkdir", path);
}

/// Every fixture I/O failure fails the test with the CRT's view of it. The historical
/// helper discarded mkdir/open/write results, so a missing directory surfaced later as
/// `error.SkillUnavailable` from `registerModelTool` (no skill discovered) and looked
/// like a Skill Runtime bug.
fn fixtureFailure(op: []const u8, path: [*:0]const u8) error{FixtureIoFailed} {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd: []const u8 = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |raw|
        std.mem.span(@as([*:0]const u8, @ptrCast(raw)))
    else
        "?";
    std.debug.print(
        "skill_fork fixture: {s} failed path={s} errno={d} cwd={s}\n",
        .{ op, path, std.c._errno().*, cwd },
    );
    return error.FixtureIoFailed;
}

fn makeSkill(root: []const u8, name: []const u8, definition: []const u8) !void {
    const allocator = std.testing.allocator;
    const root_z = try allocator.dupeZ(u8, root);
    defer allocator.free(root_z);
    try mkdirOrExisting(root_z);
    const skill_dir = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}",
        .{ root, name },
        0,
    );
    defer allocator.free(skill_dir);
    try mkdirOrExisting(skill_dir);
    const path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}/SKILL.md",
        .{ root, name },
        0,
    );
    defer allocator.free(path);
    const fd = pfs.open(
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    if (fd < 0) return fixtureFailure("open", path);
    defer pfs.close(fd);
    const n = pfs.write(fd, definition);
    if (n < 0 or @as(usize, @intCast(n)) != definition.len) return fixtureFailure("write", path);
}

fn cleanup(root: []const u8, name: []const u8) void {
    const allocator = std.testing.allocator;
    const path = std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}/SKILL.md",
        .{ root, name },
        0,
    ) catch return;
    defer allocator.free(path);
    pfs.unlinkPath(path) catch {};
    const skill_dir = std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}",
        .{ root, name },
        0,
    ) catch return;
    defer allocator.free(skill_dir);
    _ = pfs.rmdir(skill_dir);
    const root_z = allocator.dupeZ(u8, root) catch return;
    defer allocator.free(root_z);
    _ = pfs.rmdir(root_z);
}

const Host = struct {
    fn activate(
        _: *anyopaque,
        _: []const u8,
        _: []const []const u8,
        _: []const []const u8,
    ) anyerror!void {}
};

const Fixture = struct {
    runtime: cc.skills_cli_adapter.Runtime,
    projection: cc.skills.SkillSet,
    registry: cc.tools_dynamic.DynRegistry,
    abort: cc.util_abort.AbortSignal,
    permission: cc.permission.PermissionContext,
    tool_defs: []cc.json_mod.ToolDefinition,
    host_token: u8 = 0,

    fn init(
        self: *Fixture,
        allocator: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
    ) !void {
        self.* = .{
            .runtime = cc.skills_cli_adapter.Runtime.init(allocator, io),
            .projection = cc.skills.SkillSet.init(allocator),
            .registry = cc.tools_dynamic.DynRegistry.init(allocator),
            .abort = cc.util_abort.AbortSignal.init(),
            .permission = .{
                .mode = .init(.bypass_permissions),
                .allocator = allocator,
            },
            .tool_defs = try cc.tools.toToolDefinitions(allocator),
        };
        errdefer allocator.free(self.tool_defs);
        errdefer self.registry.deinit();
        errdefer self.projection.deinit();
        errdefer self.runtime.deinit();

        const sources = [_]cc.skills_runtime.catalog.Source{.{
            .root = root,
            .scope = .project,
            .priority = 300,
        }};
        try self.runtime.loadSources(root, "", "", &sources, &self.projection);
        try cc.skills_tool.registerSkillTool(&self.registry, &self.runtime);
        const model_defs = try cc.tools.toToolDefinitionsWithDyn(
            allocator,
            &self.registry,
        );
        allocator.free(self.tool_defs);
        self.tool_defs = model_defs;
        if (!cc.skills_cli_adapter.applyModelToolSchema(self.tool_defs))
            return error.SkillSchemaMissing;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.registry.deinit();
        self.runtime.deinit();
        self.projection.deinit();
        allocator.free(self.tool_defs);
        self.* = undefined;
    }

    fn context(
        self: *Fixture,
        allocator: std.mem.Allocator,
        root: []const u8,
        client: ?*cc.client_mod.Client,
    ) cc.tools.ToolContext {
        var ctx = cc.tools.ToolContext.withAbort(allocator, &self.abort);
        ctx.api_client = client;
        ctx.tool_defs = self.tool_defs;
        ctx.permission_ctx = &self.permission;
        ctx.dyn_registry = &self.registry;
        ctx.project_dir = root;
        ctx.cwd_abs = root;
        ctx.host_services = .{
            .ctx = @ptrCast(&self.host_token),
            .activateSkillFn = &Host.activate,
        };
        return ctx;
    }
};

test "L2: shared Runtime fork sends rendered body to child" {
    const allocator = std.testing.allocator;
    var root_buf: [512]u8 = undefined;
    const root = fixtureRoot(&root_buf, "cc-zig-skill-fork-body");
    defer cleanup(root, "forky");
    try makeSkill(
        root,
        "forky",
        "---\nname: forky\ndescription: forks\ncontext: fork\n---\nFORK_BODY_MARKER do the thing\n",
    );

    var server = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "claude-sonnet-4-20250514",
        url,
    );
    defer client.deinit();

    var fixture: Fixture = undefined;
    try fixture.init(allocator, io_runtime.io(), root);
    defer fixture.deinit(allocator);
    var ctx = fixture.context(allocator, root, &client);
    const entry = fixture.registry.find("Skill").?;
    var output_body = try entry.execute(
        &ctx,
        "{\"name\":\"forky\"}",
    );
    defer output_body.deinit(allocator);
    const output = output_body.@"inline".bytes;

    try std.testing.expect(std.mem.indexOf(u8, output, "(forked)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "forked-reply") != null);
    const capture = server.lastRequest() orelse return error.NoRequestCaptured;
    const messages = capture.jsonField("messages") orelse
        return error.MessagesFieldMissing;
    try std.testing.expect(
        std.mem.indexOf(u8, messages, "FORK_BODY_MARKER") != null,
    );
    try std.testing.expect(fixture.runtime.currentPolicyFrame() == null);
    try std.testing.expect(fixture.permission.active_skill == null);
}

test "L2: shared Runtime inline does not spawn child" {
    const allocator = std.testing.allocator;
    var root_buf: [512]u8 = undefined;
    const root = fixtureRoot(&root_buf, "cc-zig-skill-inline");
    defer cleanup(root, "inliney");
    try makeSkill(
        root,
        "inliney",
        "---\nname: inliney\ndescription: inline\n---\nINLINE_BODY just text\n",
    );

    var server = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "claude-sonnet-4-20250514",
        url,
    );
    defer client.deinit();

    var fixture: Fixture = undefined;
    try fixture.init(allocator, io_runtime.io(), root);
    defer fixture.deinit(allocator);
    var ctx = fixture.context(allocator, root, &client);
    const entry = fixture.registry.find("Skill").?;
    var output_body = try entry.execute(
        &ctx,
        "{\"name\":\"inliney\"}",
    );
    defer output_body.deinit(allocator);
    const output = output_body.@"inline".bytes;

    try std.testing.expect(std.mem.indexOf(u8, output, "INLINE_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(forked)") == null);
    try std.testing.expect(server.lastRequest() == null);
}

test "L2: shared Runtime fork honors model override" {
    const allocator = std.testing.allocator;
    var root_buf: [512]u8 = undefined;
    const root = fixtureRoot(&root_buf, "cc-zig-skill-fork-model");
    defer cleanup(root, "haikufork");
    try makeSkill(
        root,
        "haikufork",
        "---\nname: haikufork\ndescription: fork haiku\ncontext: fork\nmodel: haiku\n---\nbody here\n",
    );

    var server = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "claude-sonnet-4-20250514",
        url,
    );
    defer client.deinit();

    var fixture: Fixture = undefined;
    try fixture.init(allocator, io_runtime.io(), root);
    defer fixture.deinit(allocator);
    // skill.model=haiku 是兼容别名 → low 档:配置档位表后,fork 子请求应携带档位 model
    //(未配置时为 inherit,不再映射硬编码 Anthropic ID)。
    var tiers = cc.model_tiers.ProviderTiers{};
    tiers.low = .{ .model = @constCast("tier-low-model") };
    var ctx = fixture.context(allocator, root, &client);
    ctx.model_tiers = &tiers;
    const entry = fixture.registry.find("Skill").?;
    var output_body = try entry.execute(
        &ctx,
        "{\"name\":\"haikufork\"}",
    );
    defer output_body.deinit(allocator);
    try std.testing.expect(output_body == .@"inline");
    const capture = server.lastRequest() orelse return error.NoRequestCaptured;
    const model = capture.jsonField("model") orelse return error.ModelFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, model, "tier-low-model") != null);
}

test "L2: unknown agent binding fails before any child request" {
    const allocator = std.testing.allocator;
    var root_buf: [512]u8 = undefined;
    const root = fixtureRoot(&root_buf, "cc-zig-skill-agent-unavailable");
    defer cleanup(root, "agentfork");
    try makeSkill(
        root,
        "agentfork",
        "---\nname: agentfork\ndescription: unknown binding\ncontext: fork\nagent: custom\n---\nbody\n",
    );
    var server = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var fixture: Fixture = undefined;
    try fixture.init(allocator, io_runtime.io(), root);
    defer fixture.deinit(allocator);
    var agents = cc.agents_set.AgentSet.init(allocator);
    defer agents.deinit();
    var ctx = fixture.context(allocator, root, &client);
    ctx.agents = &agents;
    const entry = fixture.registry.find("Skill").?;
    try std.testing.expectError(
        error.SkillAgentNotFound,
        entry.execute(&ctx, "{\"name\":\"agentfork\"}"),
    );
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());
    try std.testing.expect(fixture.runtime.currentPolicyFrame() == null);
}

test "L2: agent binding runs the fork under that subagent's tool set" {
    const allocator = std.testing.allocator;
    var root_buf: [512]u8 = undefined;
    const root = fixtureRoot(&root_buf, "cc-zig-skill-agent-bound");
    defer cleanup(root, "readerfork");
    try makeSkill(
        root,
        "readerfork",
        "---\nname: readerfork\ndescription: bound to reader\ncontext: fork\nagent: reader\n---\nREADER_FORK_BODY\n",
    );
    var server = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var fixture: Fixture = undefined;
    try fixture.init(allocator, io_runtime.io(), root);
    defer fixture.deinit(allocator);
    var agents = cc.agents_set.AgentSet.init(allocator);
    defer agents.deinit();
    try agents.agents.append(allocator, try cc.agents_def.parseAgentMd(
        allocator,
        "---\nname: reader\ndescription: read only\ntools: Read, Grep\n---\nREADER_AGENT_PROMPT\n",
        "/fake/reader.md",
        .project,
    ));
    var ctx = fixture.context(allocator, root, &client);
    ctx.agents = &agents;
    const entry = fixture.registry.find("Skill").?;
    var output_body = try entry.execute(&ctx, "{\"name\":\"readerfork\"}");
    defer output_body.deinit(allocator);

    const capture = server.lastRequest() orelse return error.NoRequestCaptured;
    const tools = capture.jsonField("tools") orelse return error.ToolsFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"Read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"Write\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"Bash\"") == null);
    const system = capture.jsonField("system") orelse return error.SystemFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, system, "READER_AGENT_PROMPT") != null);
    const messages = capture.jsonField("messages") orelse return error.MessagesFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, messages, "Base directory for this skill:") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "READER_FORK_BODY") != null);
}

/// The child's one Write tool_use, the path JSON-escaped twice (into the
/// tool input, then into partial_json).
fn writeToolSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();
    try input.writer.writeAll("{\"file_path\":");
    try std.json.Stringify.encodeJsonString(path, .{}, &input.writer);
    try input.writer.writeAll(",\"content\":\"forked\\n\"}");
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(input.written(), .{}, &escaped.writer);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_w\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_w\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{escaped.written()},
    );
}

/// Answers every permission prompt "deny once" and counts the Write prompts.
const DenyingPrompter = struct {
    write_prompts: usize = 0,

    fn request(
        raw: *anyopaque,
        _: cc.session_id.SessionId,
        _: std.mem.Allocator,
        req: *const cc.ui_request.UiRequest,
        out: *cc.ui_request.UiResponse,
    ) anyerror!cc.ui_request.RequestOutcome {
        const self: *DenyingPrompter = @ptrCast(@alignCast(raw));
        switch (req.*) {
            .permission => |prompt| {
                if (std.mem.eql(u8, prompt.tool, "Write")) self.write_prompts += 1;
                out.* = .{ .permission = .deny_once };
                return .answered;
            },
            else => return error.UnexpectedUiRequest,
        }
    }
};

const ForkedWrite = struct { output: []u8, followup: []u8, created: bool, write_prompts: usize };

/// A forked Skill bound to an agent whose `permissionMode` is bypassPermissions
/// writes one file, under a `default` parent whose settings carry `layer`.
fn runBypassFork(allocator: std.mem.Allocator, tag: []const u8, layer: cc.permission_settings.Layer) !ForkedWrite {
    return runForkedWrite(allocator, tag, .default, "permissionMode: bypassPermissions\n", layer);
}

/// A forked Skill bound to an agent (frontmatter extra `agent_mode_line`) writes
/// one file, under a parent in `parent_mode` whose settings carry `layer`.
fn runForkedWrite(
    allocator: std.mem.Allocator,
    tag: []const u8,
    parent_mode: cc.types_mod.PermissionMode,
    agent_mode_line: []const u8,
    layer: cc.permission_settings.Layer,
) !ForkedWrite {
    var root_buf: [512]u8 = undefined;
    const root = fixtureRoot(&root_buf, tag);
    defer cleanup(root, "bypassfork");
    try makeSkill(
        root,
        "bypassfork",
        "---\nname: bypassfork\ndescription: bound to a bypass agent\ncontext: fork\nagent: bypasser\n---\nWrite the file.\n",
    );
    const target = try std.fmt.allocPrintSentinel(allocator, "{s}/forked-write.txt", .{root}, 0);
    defer allocator.free(target);
    defer pfs.unlinkPath(target) catch {};
    const write_sse = try writeToolSse(allocator, target);
    defer allocator.free(write_sse);
    const bodies = [_][]const u8{ write_sse, MINIMAL_END_TURN_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var fixture: Fixture = undefined;
    try fixture.init(allocator, io_runtime.io(), root);
    defer fixture.deinit(allocator);
    const layers = [_]cc.permission_settings.Layer{layer};
    const settings = cc.permission_settings.MergedSettings{ .layers = &layers, .allocator = allocator };
    var prompter = DenyingPrompter{};
    fixture.permission.mode = .init(parent_mode);
    fixture.permission.settings = &settings;
    fixture.permission.ui_requester = .{ .ctx = &prompter, .requestFn = DenyingPrompter.request };
    fixture.permission.no_interactive_prompt = true;
    var agents = cc.agents_set.AgentSet.init(allocator);
    defer agents.deinit();
    const agent_md = try std.fmt.allocPrint(
        allocator,
        "---\nname: bypasser\ndescription: writes\ntools: Write\n{s}---\nBYPASS_AGENT\n",
        .{agent_mode_line},
    );
    defer allocator.free(agent_md);
    try agents.agents.append(allocator, try cc.agents_def.parseAgentMd(
        allocator,
        agent_md,
        "/fake/bypasser.md",
        .project,
    ));
    var ctx = fixture.context(allocator, root, &client);
    ctx.agents = &agents;
    const entry = fixture.registry.find("Skill").?;
    var output_body = try entry.execute(&ctx, "{\"name\":\"bypassfork\"}");
    defer output_body.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const output = try allocator.dupe(u8, output_body.@"inline".bytes);
    errdefer allocator.free(output);
    const followup = try allocator.dupe(u8, (server.lastRequest() orelse return error.NoRequestCaptured).body());
    return .{
        .output = output,
        .followup = followup,
        .created = pfs.exists(target.ptr),
        .write_prompts = prompter.write_prompts,
    };
}

test "L2: a forked Skill's agent permissionMode the settings disable runs as default and is reported" {
    const allocator = std.testing.allocator;
    const no_rules: []const cc.permission_settings.Rule = &.{};
    const run = try runBypassFork(allocator, "cc-zig-skill-fork-bypass-off", .{
        .source = .managed,
        .allow = no_rules,
        .ask = no_rules,
        .deny = no_rules,
        .disable_bypass_permissions_mode = true,
    });
    defer allocator.free(run.output);
    defer allocator.free(run.followup);
    // The write bypass would auto-allow is asked (and refused), as in default.
    try std.testing.expectEqual(@as(usize, 1), run.write_prompts);
    try std.testing.expect(!run.created);
    try std.testing.expect(std.mem.indexOf(u8, run.followup, "permission_denied") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        run.output,
        "permissionMode bypassPermissions is disabled by settings; the subagent runs as default",
    ) != null);

    // Twin: only disableAutoMode → the agent's bypass applies.
    const twin = try runBypassFork(allocator, "cc-zig-skill-fork-bypass-on", .{
        .source = .managed,
        .allow = no_rules,
        .ask = no_rules,
        .deny = no_rules,
        .disable_auto_mode = true,
    });
    defer allocator.free(twin.output);
    defer allocator.free(twin.followup);
    try std.testing.expectEqual(@as(usize, 0), twin.write_prompts);
    try std.testing.expect(twin.created);
    try std.testing.expect(std.mem.indexOf(u8, twin.output, "disabled by settings") == null);
}

test "L2: a fork inheriting a mode the parent's settings disable is decided as default (backstop)" {
    // No AgentDef override here: the child inherits its parent's context, whose
    // bypass reached it past every setter. Only the decision-time backstop
    // stands between that and an auto-allowed write.
    const allocator = std.testing.allocator;
    const no_rules: []const cc.permission_settings.Rule = &.{};
    const run = try runForkedWrite(allocator, "cc-zig-skill-fork-inherit-off", .bypass_permissions, "", .{
        .source = .managed,
        .allow = no_rules,
        .ask = no_rules,
        .deny = no_rules,
        .disable_bypass_permissions_mode = true,
    });
    defer allocator.free(run.output);
    defer allocator.free(run.followup);
    try std.testing.expectEqual(@as(usize, 1), run.write_prompts);
    try std.testing.expect(!run.created);
    try std.testing.expect(std.mem.indexOf(u8, run.followup, "permission_denied") != null);

    // Twin: the same inherited bypass with the switch off writes unasked.
    const twin = try runForkedWrite(allocator, "cc-zig-skill-fork-inherit-on", .bypass_permissions, "", .{
        .source = .managed,
        .allow = no_rules,
        .ask = no_rules,
        .deny = no_rules,
        .disable_auto_mode = true,
    });
    defer allocator.free(twin.output);
    defer allocator.free(twin.followup);
    try std.testing.expectEqual(@as(usize, 0), twin.write_prompts);
    try std.testing.expect(twin.created);
}

test "L2: fork without child runner fails closed and never falls back inline" {
    const allocator = std.testing.allocator;
    var root_buf: [512]u8 = undefined;
    const root = fixtureRoot(&root_buf, "cc-zig-skill-fork-unavailable");
    defer cleanup(root, "nofork");
    try makeSkill(
        root,
        "nofork",
        "---\nname: nofork\ndescription: requires fork\ncontext: fork\n---\nNO_FALLBACK_BODY\n",
    );
    var fixture: Fixture = undefined;
    try fixture.init(allocator, std.testing.io, root);
    defer fixture.deinit(allocator);
    var ctx = fixture.context(allocator, root, null);
    const entry = fixture.registry.find("Skill").?;
    try std.testing.expectError(
        error.ForkUnavailable,
        entry.execute(&ctx, "{\"name\":\"nofork\"}"),
    );
    try std.testing.expect(fixture.runtime.currentPolicyFrame() == null);
}

const ProjectionProbe = struct {
    text: usize = 0,
    stream_done: usize = 0,
    tool_start: usize = 0,
    tool_result: usize = 0,
    usage: usize = 0,

    fn backend(self: *ProjectionProbe) cc.ui_backend.UiBackend {
        return .{ .ctx = self, .emit = emit, .poll = poll };
    }

    fn emit(
        raw: *anyopaque,
        _: cc.session_id.SessionId,
        event: cc.ui_event.CoreEvent,
    ) void {
        const self: *ProjectionProbe = @ptrCast(@alignCast(raw));
        switch (event) {
            .text_chunk => self.text += 1,
            .stream_done => self.stream_done += 1,
            .tool_start => self.tool_start += 1,
            .tool_result => self.tool_result += 1,
            .usage => self.usage += 1,
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

test "L2: AgentCore fork capture preserves raw boundaries at true child depth" {
    const allocator = std.testing.allocator;
    const bodies = [_][]const u8{
        READ_TOOL_SSE,
        MINIMAL_END_TURN_SSE,
        READ_TOOL_SSE,
        MINIMAL_END_TURN_SSE,
    };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "test-model",
        url,
    );
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tool_defs = try cc.tools.toToolDefinitions(arena.allocator());
    var permission = cc.permission.PermissionContext{
        .mode = .init(.bypass_permissions),
        .allocator = allocator,
    };

    var root_probe = ProjectionProbe{};
    const root_backend = root_probe.backend();
    const root_result = try cc.core_subagent.spawnAgentSink(
        allocator,
        client.provider(),
        &client,
        tool_defs,
        &permission,
        null,
        "exercise run-root projection",
        .{
            .max_turns = 3,
            .agent_depth = 2,
            .event_projection = .run_root,
        },
        &root_backend,
    );
    defer root_result.deinit();
    try std.testing.expectEqual(
        cc.agent_loop.StopReason.end_turn,
        root_result.stop_reason,
    );
    try std.testing.expectEqual(@as(usize, 1), root_probe.tool_start);
    try std.testing.expectEqual(@as(usize, 1), root_probe.tool_result);
    try std.testing.expect(root_probe.text > 0);
    try std.testing.expectEqual(@as(usize, 2), root_probe.stream_done);
    try std.testing.expect(root_probe.usage > 0);

    var model_probe = ProjectionProbe{};
    const model_backend = model_probe.backend();
    const model_result = try cc.core_subagent.spawnAgentSink(
        allocator,
        client.provider(),
        &client,
        tool_defs,
        &permission,
        null,
        "exercise model-tool projection",
        .{
            .max_turns = 3,
            .agent_depth = 2,
            .event_projection = .model_tool,
        },
        &model_backend,
    );
    defer model_result.deinit();
    try std.testing.expectEqual(
        cc.agent_loop.StopReason.end_turn,
        model_result.stop_reason,
    );
    try std.testing.expectEqual(@as(usize, 1), model_probe.tool_start);
    try std.testing.expectEqual(@as(usize, 1), model_probe.tool_result);
    try std.testing.expect(model_probe.text > 0);
    try std.testing.expectEqual(@as(usize, 2), model_probe.stream_done);
    try std.testing.expect(model_probe.usage > 0);
}
