//! L2 evidence: Gemini thought signatures go back where they came from.
//!
//! Gemini 3 and later reject a request whose current turn returns a model
//! functionCall without the `thoughtSignature` it arrived with (400, "...is
//! missing a thought_signature"). Before this, the client dropped every
//! signature, so the second request of any turn that called a tool failed on
//! the current frontier models.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const gemini = cc.api_gemini;
const types = cc.types_mod;

const SIGNED_CALL_SSE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[" ++
    "{\"functionCall\":{\"name\":\"read_file\",\"args\":{\"path\":\"a.zig\"}},\"thoughtSignature\":\"SIG-A\"}," ++
    "{\"functionCall\":{\"name\":\"read_file\",\"args\":{\"path\":\"b.zig\"}}}" ++
    "]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":2}}\n\n";
const TEXT_SSE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"done\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":20,\"candidatesTokenCount\":1}}\n\n";

/// Drain one streamed response; the ids of the calls it carried, in order.
fn drain(a: std.mem.Allocator, handle: *cc.api_provider.StreamHandle, ids: *std.ArrayList([]u8)) !void {
    while (try handle.next()) |event| switch (event) {
        .tool_use_start => |call| {
            try ids.append(a, try a.dupe(u8, call.id));
            a.free(call.id);
            a.free(call.name);
            a.free(call.input_json);
        },
        .text => |text| a.free(text),
        else => {},
    };
}

/// The model functionCall part for `path` in a request body, from its
/// `functionCall` key to the end of the part.
fn callPart(body: []const u8, path: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"path\":\"{s}\"", .{path}) catch return null;
    const at = std.mem.indexOf(u8, body, needle) orelse return null;
    const start = std.mem.lastIndexOf(u8, body[0..at], "{\"functionCall\"") orelse return null;
    // `"path":"..."}}` closes args and functionCall; the part closes at the
    // next `}` that is followed by the next part or the end of the parts.
    const after_call = (std.mem.indexOfPos(u8, body, at, "}}") orelse return null) + 2;
    const next_part = std.mem.indexOfPos(u8, body, after_call, "},") orelse body.len;
    const last_part = std.mem.indexOfPos(u8, body, after_call, "}]") orelse body.len;
    const end = @min(next_part, last_part);
    if (end == body.len) return null;
    return body[start .. end + 1];
}

test "L2 gemini: a received thought signature returns in the part it came on" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ SIGNED_CALL_SSE, TEXT_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-4-argon", url);
    defer client.deinit();

    const first_turn = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "read both" }} },
    };
    var ids: std.ArrayList([]u8) = .empty;
    defer {
        for (ids.items) |id| a.free(id);
        ids.deinit(a);
    }
    var first = try client.provider().sendStream(&first_turn, null, null, null, null, null, "");
    try drain(a, &first, &ids);
    first.deinit();
    try std.testing.expectEqual(@as(usize, 2), ids.items.len);

    // The same turn's next request: both calls and their results, plus a call
    // this client never received (history from another model).
    const history = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "read both" }} },
        .{ .role = .assistant, .content = &[_]types.ApiContent{
            .{ .tool_use = .{ .id = ids.items[0], .name = "read_file", .input = "{\"path\":\"a.zig\"}" } },
            .{ .tool_use = .{ .id = ids.items[1], .name = "read_file", .input = "{\"path\":\"b.zig\"}" } },
        } },
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .tool_result = .{ .tool_use_id = ids.items[0], .content = "A" } },
            .{ .tool_result = .{ .tool_use_id = ids.items[1], .content = "B" } },
        } },
        .{ .role = .assistant, .content = &[_]types.ApiContent{
            .{ .tool_use = .{ .id = "call_from_elsewhere", .name = "read_file", .input = "{\"path\":\"c.zig\"}" } },
        } },
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .tool_result = .{ .tool_use_id = "call_from_elsewhere", .content = "C" } },
        } },
    };
    var second = try client.provider().sendStream(&history, null, null, null, null, null, "");
    var no_calls: std.ArrayList([]u8) = .empty;
    defer no_calls.deinit(a);
    try drain(a, &second, &no_calls);
    second.deinit();

    const body = srv.lastRequest().?.body();
    // The signature rides on the part it arrived on, verbatim.
    const part_a = callPart(body, "a.zig") orelse return error.PartMissing;
    try std.testing.expect(std.mem.indexOf(u8, part_a, "\"thoughtSignature\":\"SIG-A\"") != null);
    // A parallel call after the first carried none and sends none.
    const part_b = callPart(body, "b.zig") orelse return error.PartMissing;
    try std.testing.expect(std.mem.indexOf(u8, part_b, "thoughtSignature") == null);
    // A step's first call this client never received gets the documented
    // placeholder rather than failing validation.
    const part_c = callPart(body, "c.zig") orelse return error.PartMissing;
    try std.testing.expect(std.mem.indexOf(u8, part_c, "\"thoughtSignature\":\"skip_thought_signature_validator\"") != null);
}

test "L2 gemini: a model that does not validate signatures gets no placeholder" {
    const a = std.testing.allocator;
    const history = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
        .{ .role = .assistant, .content = &[_]types.ApiContent{
            .{ .tool_use = .{ .id = "call_old", .name = "read_file", .input = "{\"path\":\"a.zig\"}" } },
        } },
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .tool_result = .{ .tool_use_id = "call_old", .content = "A" } },
        } },
    };
    const body = try gemini.serializeGeminiRequest(a, &history, null, null, null, "gemini-2.5-flash", null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "thoughtSignature") == null);
    const modern = try gemini.serializeGeminiRequest(a, &history, null, null, null, "gemini-3.8-flash", null, null);
    defer a.free(modern);
    try std.testing.expect(std.mem.indexOf(u8, modern, "\"thoughtSignature\":\"skip_thought_signature_validator\"") != null);
}
