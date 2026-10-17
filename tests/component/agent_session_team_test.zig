//! Issue #277: a host-scheduled team through AgentCore's core. A lead Session
//! creates a team and delegates with SpawnTeammate — which records a request
//! for the Host, not an in-process thread — and a member Session joins the
//! roster and talks to the lead through SendMessage. These drive the real
//! AgentSession tool loop against a cassette server.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const AgentRuntime = cc.agent_session.AgentRuntime;

fn textSse(comptime text: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"" ++ text ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

fn toolSse(comptime id: []const u8, comptime name: []const u8, comptime input_json: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"" ++ id ++ "\",\"name\":\"" ++ name ++ "\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"" ++ input_json ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

const Sink = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: u64, _: cc.ui_event.CoreEvent) bool {
        return true;
    }
};

fn teamRoot(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(std.testing.io, buf);
    for (buf[0..n]) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buf[0..n];
}

test "L2 issue #277: a host-scheduled lead delegates by recording a spawn request, and a member Session joins and messages the lead" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try teamRoot(&tmp, &root_buf);

    // Lead: TeamCreate crew, then SpawnTeammate solver, then end.
    const lead_bodies = [_][]const u8{
        toolSse("t1", "TeamCreate", "{\\\"name\\\":\\\"crew\\\"}"),
        toolSse("t2", "SpawnTeammate", "{\\\"name\\\":\\\"solver\\\",\\\"prompt\\\":\\\"fix the parser\\\"}"),
        textSse("delegated"),
    };
    var lead_srv = try harness.MockServer.startCassette(&lead_bodies, 0);
    defer lead_srv.stop();
    const lead_url = try lead_srv.urlOwned(a);
    defer a.free(lead_url);

    const runtime = try AgentRuntime.create(a, .{ .builtin_tools = &.{}, .enable_teams = true });
    defer runtime.destroy() catch unreachable;

    const lead = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = lead_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .home = root, .state_root = root, .shell = .disabled },
        .allowed_tools = &.{ "TeamCreate", "SpawnTeammate", "SendMessage" },
        .team = .{ .role = .lead, .team_name = "" },
    });
    defer lead.destroy() catch unreachable;

    var sink: u8 = 0;
    const lead_result = try lead.runText(1, "form a team and delegate", 4, .{ .ctx = &sink, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, lead_result.stop_reason);

    // The team exists on disk, the lead keeps no in-process registry, and the
    // delegation is a pending host spawn request — not a running teammate.
    const sw = &lead.swarm.?;
    try std.testing.expect(sw.hasTeam());
    try std.testing.expect(sw.teammates == null);
    try std.testing.expectEqual(@as(usize, 1), sw.pending_spawns.items.len);
    try std.testing.expectEqualStrings("solver", sw.pending_spawns.items[0].name);
    try std.testing.expectEqualStrings("fix the parser", sw.pending_spawns.items[0].prompt);
    const lead_session_id = sw.session;

    // The Host fulfils the request: a member Session named solver, joining the
    // same team under the lead's session id and a fresh lease.
    const lease = cc.session_id.gen();
    const member_bodies = [_][]const u8{
        toolSse("s1", "SendMessage", "{\\\"to\\\":\\\"team-lead\\\",\\\"message\\\":\\\"done: 42\\\",\\\"summary\\\":\\\"done\\\"}"),
        textSse("idle"),
    };
    var member_srv = try harness.MockServer.startCassette(&member_bodies, 0);
    defer member_srv.stop();
    const member_url = try member_srv.urlOwned(a);
    defer a.free(member_url);

    const member = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = member_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .home = root, .state_root = root, .shell = .disabled },
        .allowed_tools = &.{"SendMessage"},
        .team = .{
            .role = .member,
            .team_name = "crew",
            .member_name = "solver",
            .lead_session_id = lead_session_id.asSlice(),
            .member_lease = lease.asSlice(),
        },
    });
    defer member.destroy() catch unreachable;

    const member_result = try member.runText(1, "work and report", 3, .{ .ctx = &sink, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, member_result.stop_reason);

    // The lead reads the member's reply from its inbox, formatted for the model.
    const mail = (try cc.swarm_tools.pollLeadInbox(a, sw)) orelse return error.NoLeadMail;
    defer a.free(mail);
    try std.testing.expect(std.mem.indexOf(u8, mail, "done: 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, mail, "teammate_id=\"solver\"") != null);
}
