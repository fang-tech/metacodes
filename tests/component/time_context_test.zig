//! Issue #276: the CLI tells the model today's date and its time zone with no
//! CLAUDE.md, memory or KG in play, and tells it once more - in the turn it
//! happens - when the local date changes. These tests drive the real agent
//! loop against a cassette server with a controlled clock and read the
//! request bytes the provider actually receives.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const time_context = cc.time_context;

const FINAL =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Clock = struct {
    var now: i64 = 0;
    fn read() i64 {
        return now;
    }
};

fn dateText(buf: []u8, unix_seconds: i64, zone: *const time_context.Zone) ![]const u8 {
    const date = time_context.localDate(unix_seconds, zone.offset_minutes);
    return std.fmt.bufPrint(buf, "Today's date is {d}-{d:0>2}-{d:0>2} ({s}).", .{ date.year, date.month, date.day, @tagName(date.weekday) });
}

fn runTurn(
    a: std.mem.Allocator,
    conv: *cc.conversation.Conversation,
    provider: cc.api_provider.Provider,
    user_context: []const u8,
    announcer: *time_context.Announcer,
    question: []const u8,
) !void {
    try conv.appendText(.user, question);
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = try agent_loop.run(conv, provider, &.{}, &perm, .{
        .max_turns = 1,
        .inject_user_context = user_context,
        .time_announcer = announcer,
    }, &be, a);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |i| : (at = i + needle.len) n += 1;
    return n;
}

test "L2 issue #276: the CLI request carries the date and zone with no project context, and the first run after local midnight is told the new date once" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&.{ FINAL, FINAL, FINAL }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "key", "model", url);
    defer client.deinit();

    // Local noon of a fixed day in this process's zone.
    const zone = time_context.systemZone(1_792_000_000);
    const offset_seconds = @as(i64, zone.offset_minutes) * 60;
    const noon = 1_792_000_000 - @mod(1_792_000_000 + offset_seconds, std.time.s_per_day) + 12 * 3600;
    Clock.now = noon;

    // No CLAUDE.md, no memory, no KG: the session-start context is the date alone.
    const user_context = try cc.user_context.build(a, .{ .cwd = "", .home = "", .now = noon, .zone = zone });
    defer a.free(user_context);
    try std.testing.expect(std.mem.indexOf(u8, user_context, "# claudeMd") == null);
    var announcer = time_context.Announcer.init(noon, &zone, Clock.read);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();

    var day_one_buf: [64]u8 = undefined;
    const day_one = try dateText(&day_one_buf, noon, &zone);
    var day_two_buf: [64]u8 = undefined;
    const day_two = try dateText(&day_two_buf, noon + 24 * 3600, &zone);

    // Run 1, the session's own day: the date and zone ride the first message.
    try runTurn(a, &conv, client.provider(), user_context, &announcer, "first question");
    const first = (srv.requestAt(0) orelse return error.MissingRequest).body();
    try std.testing.expect(std.mem.indexOf(u8, first, day_one) != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "Time zone: ") != null or std.mem.indexOf(u8, first, "time zone is unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "The date has changed") == null);

    // Run 2, past local midnight: told once, in this turn.
    Clock.now = noon + 13 * 3600;
    try runTurn(a, &conv, client.provider(), user_context, &announcer, "second question");
    const second = (srv.requestAt(1) orelse return error.MissingRequest).body();
    var notice_buf: [96]u8 = undefined;
    const notice = try std.fmt.bufPrint(&notice_buf, "The date has changed. {s}", .{day_two});
    try std.testing.expectEqual(@as(usize, 1), count(second, notice));
    // The session-start date in the first message is unchanged, and the
    // notice comes after the turn's question.
    try std.testing.expect(std.mem.indexOf(u8, second, day_one) != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "second question").? < std.mem.indexOf(u8, second, notice).?);

    // Run 3, the same new day: no second notice; the first stays in history.
    Clock.now += 3600;
    try runTurn(a, &conv, client.provider(), user_context, &announcer, "third question");
    const third = (srv.requestAt(2) orelse return error.MissingRequest).body();
    try std.testing.expectEqual(@as(usize, 1), count(third, "The date has changed."));
}

test "L2 issue #276: a notice that left the conversation is given again" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&.{ FINAL, FINAL }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "key", "model", url);
    defer client.deinit();

    const zone = time_context.systemZone(1_792_000_000);
    const offset_seconds = @as(i64, zone.offset_minutes) * 60;
    const noon = 1_792_000_000 - @mod(1_792_000_000 + offset_seconds, std.time.s_per_day) + 12 * 3600;
    Clock.now = noon + 24 * 3600;
    const user_context = try cc.user_context.build(a, .{ .cwd = "", .home = "", .now = noon, .zone = zone });
    defer a.free(user_context);
    var announcer = time_context.Announcer.init(noon, &zone, Clock.read);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try runTurn(a, &conv, client.provider(), user_context, &announcer, "first question");
    try std.testing.expectEqual(@as(usize, 1), count((srv.requestAt(0) orelse return error.MissingRequest).body(), "The date has changed."));

    // The history that held the notice is gone (as after /clear or a resume
    // without it); the model again sees only the session-start date.
    var fresh = cc.conversation.Conversation.init(a);
    defer fresh.deinit();
    try runTurn(a, &fresh, client.provider(), user_context, &announcer, "after the history was dropped");
    try std.testing.expectEqual(@as(usize, 1), count((srv.requestAt(1) orelse return error.MissingRequest).body(), "The date has changed."));
}
