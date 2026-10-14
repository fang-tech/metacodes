//! Streamable HTTP MCP client against tests/_harness/mock_mcp_http_server.py:
//! the Classic session/SSE flow (a mid-stream server ping answered on its own
//! POST), the 2026-07-28 routing headers, pagination and `x-mcp-header`, and
//! 401 as an authentication error.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const process = @import("platform").process;

const MOCK = "tests/_harness/mock_mcp_http_server.py";

const Mock = struct {
    child: process.PipeChild,
    port: u16,

    fn start() !?Mock {
        if (builtin.os.tag == .windows) return null; // POSIX: shebang script
        if (std.c.access(MOCK, 1) != 0) return null;
        const argv = [_]?[*:0]const u8{ MOCK, null };
        const child = process.spawnPipes(&argv, true, null) catch return null;
        var buffer: [16]u8 = undefined;
        var length: usize = 0;
        while (length < buffer.len) {
            var byte: [1]u8 = undefined;
            if (!child.pollReadable(5000)) break;
            if (child.read(&byte) != 1) break;
            if (byte[0] == '\n') break;
            buffer[length] = byte[0];
            length += 1;
        }
        const port = std.fmt.parseInt(u16, buffer[0..length], 10) catch {
            child.closeStdin();
            child.closeStdout();
            child.terminate();
            return null;
        };
        return .{ .child = child, .port = port };
    }

    fn stop(self: *Mock) void {
        self.child.closeStdin();
        self.child.closeStdout();
        self.child.terminate();
    }

    fn url(self: *const Mock, buffer: []u8, path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/{s}", .{ self.port, path });
    }

    fn log(self: *const Mock, allocator: std.mem.Allocator) ![]u8 {
        var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
        defer client.deinit();
        var buffer: [128]u8 = undefined;
        const target = try self.url(&buffer, "log");
        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();
        _ = try client.fetch(.{ .location = .{ .url = target }, .response_writer = &body.writer });
        return body.toOwnedSlice();
    }
};

test "MCP HTTP: Classic session, SSE with a server ping, and DELETE on close" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var buffer: [128]u8 = undefined;
    {
        var client = try cc.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = try mock.url(&buffer, "classic"),
            .headers = &.{ .{ .name = "X-Team", .value = "t1" }, .{ .name = "Authorization", .value = "Bearer tok" } },
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        try std.testing.expect(!client.modern);
        try std.testing.expectEqualStrings("2025-06-18", client.protocol_version);
        client.transport.setDeadline(cc.util_time.nowMs() + 10_000);
        const tools = try client.listTools();
        defer a.free(tools);
        try std.testing.expect(std.mem.indexOf(u8, tools, "\"sse_tool\"") != null);
        client.transport.setDeadline(null);
        const called = try client.callTool("sse_tool", "{}");
        defer a.free(called);
        try std.testing.expect(std.mem.indexOf(u8, called, "classic:sse_tool") != null);
    }
    const log = try mock.log(a);
    defer a.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"ping_answered\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"authorization\": \"Bearer tok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"x-team\": \"t1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"method\": \"DELETE\", \"session\": \"session-1\"") != null);
}

test "MCP HTTP: 2026-07-28 headers, empty-cursor pagination and x-mcp-header" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var buffer: [128]u8 = undefined;
    var client = try cc.mcp_client.McpClient.connectHttp(a, .{
        .io = std.testing.io,
        .url = try mock.url(&buffer, "modern"),
    }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
    defer client.close();
    try std.testing.expect(client.modern);

    var registry = cc.tools_dynamic.DynRegistry.init(a);
    defer registry.deinit();
    var session = cc.mcp_registry_bridge.McpSession.init(a, &client);
    defer session.deinit();
    try session.registerToolsFiltered(&registry, "m", .{ .http_param_headers = true });
    // The tool with an invalid annotation is excluded; the second page is listed.
    try std.testing.expect(registry.find("mcp__m__regional") != null);
    try std.testing.expect(registry.find("mcp__m__badannot") == null);
    try std.testing.expect(registry.find("mcp__m__second_page") != null);

    var ctx = cc.tools.ToolContext.simple(a);
    ctx.artifact_root = root;
    const entry = registry.find("mcp__m__regional").?;
    var body = try entry.execute(&ctx, "{\"region\":\"eu-west\",\"q\":\"x\"}");
    defer body.deinit(a);
    const text = body.@"inline".bytes;
    try std.testing.expect(std.mem.indexOf(u8, text, "name-header:regional") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "region-header:eu-west") != null);
}

test "MCP HTTP: 401 is an authentication error, not a protocol fallback" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    var buffer: [128]u8 = undefined;
    try std.testing.expectError(error.McpAuthRequired, cc.mcp_client.McpClient.connectHttp(std.testing.allocator, .{
        .io = std.testing.io,
        .url = try mock.url(&buffer, "auth"),
    }, .{ .spawn = undefined, .startup_timeout_ms = 5_000 }));
}
