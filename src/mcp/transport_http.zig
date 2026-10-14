//! MCP Streamable HTTP transport (one endpoint, a POST per message).
//!
//! The client sees the same message stream as over stdio: `send` POSTs a
//! JSON-RPC message, `recvLine` yields the messages the server answered with —
//! the single JSON body, or each SSE `data` event of a `text/event-stream`
//! response, read lazily so a Classic server's mid-stream request can be
//! answered (on its own POST) before the stream delivers the final response.
//!
//! Headers (basic/transports/streamable-http.mdx):
//! - every POST: `Content-Type: application/json`,
//!   `Accept: application/json, text/event-stream`, configured headers and
//!   `Authorization: Bearer $bearer_token_env_var`;
//! - 2026-07-28: `MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name` for
//!   `tools/call` / `resources/read` / `prompts/get` (base64 sentinel when the
//!   value is not header-safe); no session;
//! - Classic: `MCP-Protocol-Version` after the handshake and the
//!   `MCP-Session-Id` the `initialize` response assigned; DELETE on close.
//!
//! 401/403 are `error.McpAuthRequired` (OAuth login is not implemented; a
//! static bearer token or headers authenticate). Cancellation and deadlines
//! shut the connection down through the provider client's request registry,
//! which also wakes a read blocked in the kernel.

const std = @import("std");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const provider = @import("../api/provider.zig");
const http_status = @import("../api/http_status.zig");
const util_time = @import("../util/time.zig");
const Capture = @import("../core/tool_result_artifact.zig").Capture;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const SendMeta = struct {
    /// JSON-RPC method of the message ("" for a response or unknown).
    method: []const u8 = "",
    /// `params.name` / `params.uri` for the 2026-07-28 `Mcp-Name` header.
    name: ?[]const u8 = null,
    /// `Mcp-Param-*` headers mirrored from `x-mcp-header` tool arguments.
    param_headers: []const Header = &.{},
};

const MAX_MESSAGE_BYTES: usize = 128 * 1024 * 1024 + 1024 * 1024;

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    url: []u8,
    uri: std.Uri,
    /// Configured headers plus Authorization, owned.
    headers: []Header,
    /// Negotiated revision for `MCP-Protocol-Version` (null before a Classic
    /// handshake completes). Static string.
    protocol_version: ?[]const u8 = null,
    modern: bool = false,
    session_id: ?[]u8 = null,
    deadline_ms: ?i64 = null,
    abort: ?*const AbortSignal = null,
    registry: provider.RequestAbortRegistry = .{},
    /// Messages already received but not yet consumed.
    queue: std.ArrayList([]u8) = .empty,
    /// The open SSE response, read lazily by `recvLine`.
    stream: ?*Exchange = null,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        headers: []const Header,
    ) !*HttpTransport {
        const self = try allocator.create(HttpTransport);
        errdefer allocator.destroy(self);
        const owned_url = try allocator.dupe(u8, url);
        errdefer allocator.free(owned_url);
        const uri = std.Uri.parse(owned_url) catch return error.McpInvalidUrl;
        const owned_headers = try allocator.alloc(Header, headers.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_headers[0..initialized]) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }
            allocator.free(owned_headers);
        }
        for (headers, owned_headers) |header, *slot| {
            slot.* = .{ .name = try allocator.dupe(u8, header.name), .value = undefined };
            slot.value = allocator.dupe(u8, header.value) catch |err| {
                allocator.free(slot.name);
                return err;
            };
            initialized += 1;
        }
        self.* = .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io },
            .url = owned_url,
            .uri = uri,
            .headers = owned_headers,
        };
        return self;
    }

    pub fn close(self: *HttpTransport) void {
        self.closeStream();
        if (self.session_id != null and !self.modern) {
            // Classic: end the session (SHOULD); failures are irrelevant now.
            self.deleteSession() catch {};
        }
        for (self.queue.items) |message| self.allocator.free(message);
        self.queue.deinit(self.allocator);
        if (self.session_id) |id| self.allocator.free(id);
        for (self.headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.url);
        self.client.deinit();
        self.registry.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// POST one JSON-RPC message. Responses the server sends back (if any)
    /// become available to `recvLine`.
    pub fn send(self: *HttpTransport, json: []const u8, meta: SendMeta) !void {
        // A reply posted while a request's SSE stream is still open (Classic
        // server→client request) uses its own connection; the open stream
        // keeps its place.
        var exchange = try self.post(json, meta);
        errdefer exchange.destroy(self);
        switch (exchange.kind) {
            .empty => exchange.destroy(self),
            .json => {
                const body = try exchange.readAll(self, MAX_MESSAGE_BYTES);
                exchange.destroy(self);
                errdefer self.allocator.free(body);
                if (std.mem.trim(u8, body, " \t\r\n").len == 0) {
                    self.allocator.free(body);
                    return;
                }
                try self.queue.append(self.allocator, body);
            },
            .sse => {
                if (self.stream) |previous| {
                    // Only one request is in flight per client (request
                    // mutex), so an older stream has nothing left we need.
                    previous.destroy(self);
                }
                self.stream = exchange;
            },
        }
    }

    pub fn recvLine(self: *HttpTransport) ![]u8 {
        if (self.queue.items.len != 0) return self.queue.orderedRemove(0);
        const exchange = self.stream orelse return error.Eof;
        const message = exchange.nextEvent(self, MAX_MESSAGE_BYTES) catch |err| {
            self.closeStream();
            return err;
        } orelse {
            self.closeStream();
            // The stream ended without the awaited response: in 2026-07-28 the
            // request is lost and must be re-issued by the caller.
            return error.Eof;
        };
        return message;
    }

    pub fn recvLineCapture(self: *HttpTransport, capture: *Capture) !void {
        const message = try self.recvLine();
        defer self.allocator.free(message);
        try capture.write(message);
    }

    fn closeStream(self: *HttpTransport) void {
        if (self.stream) |exchange| exchange.destroy(self);
        self.stream = null;
    }

    fn deleteSession(self: *HttpTransport) !void {
        var extra: std.ArrayList(std.http.Header) = .empty;
        defer extra.deinit(self.allocator);
        try self.appendCommonHeaders(&extra, .{});
        var request = try self.client.request(.DELETE, self.uri, .{
            .keep_alive = false,
            .headers = .{ .accept_encoding = .omit },
            .extra_headers = extra.items,
        });
        defer request.deinit();
        try request.sendBodiless();
        var redirect: [1024]u8 = undefined;
        _ = try request.receiveHead(&redirect);
    }

    fn appendCommonHeaders(self: *HttpTransport, list: *std.ArrayList(std.http.Header), meta: SendMeta) !void {
        for (self.headers) |header| try list.append(self.allocator, .{ .name = header.name, .value = header.value });
        if (self.protocol_version) |version| try list.append(self.allocator, .{ .name = "MCP-Protocol-Version", .value = version });
        if (self.session_id) |id| try list.append(self.allocator, .{ .name = "MCP-Session-Id", .value = id });
        if (self.modern and meta.method.len != 0) {
            try list.append(self.allocator, .{ .name = "Mcp-Method", .value = meta.method });
            if (meta.name) |name| try list.append(self.allocator, .{ .name = "Mcp-Name", .value = name });
            for (meta.param_headers) |header| try list.append(self.allocator, .{ .name = header.name, .value = header.value });
        }
    }

    fn post(self: *HttpTransport, json: []const u8, meta: SendMeta) !*Exchange {
        if (self.abort) |abort| if (abort.isAborted()) return error.Aborted;
        if (self.deadline_ms) |deadline| if (util_time.nowMs() >= deadline) return error.Timeout;

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var extra: std.ArrayList(std.http.Header) = .empty;
        try extra.append(scratch.allocator(), .{ .name = "Accept", .value = "application/json, text/event-stream" });
        var encoded_meta = meta;
        if (meta.name) |name| encoded_meta.name = try headerSafe(scratch.allocator(), name);
        var encoded_params: std.ArrayList(Header) = .empty;
        for (meta.param_headers) |header| {
            try encoded_params.append(scratch.allocator(), .{ .name = header.name, .value = try headerSafe(scratch.allocator(), header.value) });
        }
        encoded_meta.param_headers = encoded_params.items;
        {
            // appendCommonHeaders allocates with self.allocator; copy into scratch.
            var common: std.ArrayList(std.http.Header) = .empty;
            defer common.deinit(self.allocator);
            try self.appendCommonHeaders(&common, encoded_meta);
            try extra.appendSlice(scratch.allocator(), common.items);
        }

        const exchange = try self.allocator.create(Exchange);
        errdefer self.allocator.destroy(exchange);
        exchange.* = .{ .request = undefined };
        exchange.request = self.client.request(.POST, self.uri, .{
            .keep_alive = false,
            .headers = .{
                .accept_encoding = .omit,
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = extra.items,
        }) catch return error.McpConnectFailed;
        errdefer exchange.request.deinit();
        const remaining: u64 = if (self.deadline_ms) |deadline| @intCast(@max(deadline - util_time.nowMs(), 1)) else 0;
        try self.registry.registerMonitored(self.allocator, self.abort, @ptrCast(&exchange.request), shutdownRequest, remaining);
        exchange.registered = true;
        errdefer self.registry.unregister(@ptrCast(&exchange.request));

        exchange.request.sendBodyComplete(@constCast(json)) catch return self.transportError();
        var redirect: [4096]u8 = undefined;
        exchange.response = exchange.request.receiveHead(&redirect) catch return self.transportError();
        exchange.has_response = true;
        const status = http_status.ResponseStatus.capture(&exchange.response).code;
        const head = exchange.response.head;

        // Classic: the server assigns its session on the initialize response.
        var headers = head.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id") and !self.modern) {
                if (self.session_id) |old| self.allocator.free(old);
                self.session_id = try self.allocator.dupe(u8, std.mem.trim(u8, header.value, " "));
            }
        }
        const content_type = head.content_type orelse "";
        const is_sse = std.mem.startsWith(u8, content_type, "text/event-stream");

        switch (status) {
            200...201 => exchange.kind = if (is_sse) .sse else .json,
            202, 204 => exchange.kind = .empty,
            401, 403 => return error.McpAuthRequired,
            404 => {
                // A Classic session the server no longer knows (404 with a
                // session id) must be re-initialized. A JSON-RPC body (e.g.
                // 2026-07-28 method-not-found) is still delivered.
                if (self.session_id != null and !self.modern) return error.McpSessionExpired;
                exchange.kind = if (is_sse) .sse else .json;
            },
            400, 402, 405...499 => exchange.kind = if (is_sse) .sse else .json,
            else => return error.McpServerError,
        }
        // Keep only the abort routing for the body; a deadline still applies.
        return exchange;
    }

    fn transportError(self: *HttpTransport) anyerror {
        if (self.abort) |abort| if (abort.isAborted()) return error.Aborted;
        if (self.deadline_ms) |deadline| if (util_time.nowMs() >= deadline) return error.Timeout;
        return error.McpConnectFailed;
    }
};

fn shutdownRequest(raw: *anyopaque) void {
    const request: *std.http.Client.Request = @ptrCast(@alignCast(raw));
    provider.abortHttpRequest(request);
}

const Exchange = struct {
    request: std.http.Client.Request,
    response: std.http.Client.Response = undefined,
    has_response: bool = false,
    registered: bool = false,
    kind: Kind = .empty,
    transfer: [16 * 1024]u8 = undefined,
    body: ?*std.Io.Reader = null,
    /// Bytes of an SSE line carried over between reads.
    pending: std.ArrayList(u8) = .empty,
    finished: bool = false,

    const Kind = enum { empty, json, sse };

    fn destroy(self: *Exchange, transport: *HttpTransport) void {
        if (self.registered) transport.registry.unregister(@ptrCast(&self.request));
        self.pending.deinit(transport.allocator);
        self.request.deinit();
        transport.allocator.destroy(self);
    }

    fn reader(self: *Exchange) *std.Io.Reader {
        if (self.body) |body| return body;
        self.body = self.response.reader(&self.transfer);
        return self.body.?;
    }

    fn readAll(self: *Exchange, transport: *HttpTransport, limit: usize) ![]u8 {
        return self.reader().allocRemaining(transport.allocator, .limited(limit)) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => error.McpLineTooLarge,
            else => transport.transportError(),
        };
    }

    /// Next SSE `data` payload, or null at the end of the stream. Comments
    /// (keep-alives), empty priming events and non-message fields are skipped.
    fn nextEvent(self: *Exchange, transport: *HttpTransport, limit: usize) !?[]u8 {
        if (self.finished) return null;
        const allocator = transport.allocator;
        var data: std.ArrayList(u8) = .empty;
        errdefer data.deinit(allocator);
        var has_data = false;
        const input = self.reader();
        while (true) {
            const line = readLine(input, allocator, &self.pending, limit) catch |err| switch (err) {
                error.EndOfStream => {
                    self.finished = true;
                    if (has_data and data.items.len != 0) return try data.toOwnedSlice(allocator);
                    data.deinit(allocator);
                    return null;
                },
                error.OutOfMemory => return error.OutOfMemory,
                error.McpLineTooLarge => return error.McpLineTooLarge,
                else => return transport.transportError(),
            };
            defer allocator.free(line);
            if (line.len == 0) {
                if (has_data and data.items.len != 0) return try data.toOwnedSlice(allocator);
                data.clearRetainingCapacity();
                has_data = false;
                continue;
            }
            if (line[0] == ':') continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
            const field = line[0..colon];
            var value = if (colon < line.len) line[colon + 1 ..] else "";
            if (value.len != 0 and value[0] == ' ') value = value[1..];
            if (!std.mem.eql(u8, field, "data")) continue;
            if (has_data) try data.append(allocator, '\n');
            try data.appendSlice(allocator, value);
            has_data = true;
            if (data.items.len > limit) return error.McpLineTooLarge;
        }
    }
};

/// One line (without its CR/LF) from `input`, accumulating partial bytes in
/// `pending` across calls.
fn readLine(input: *std.Io.Reader, allocator: std.mem.Allocator, pending: *std.ArrayList(u8), limit: usize) ![]u8 {
    while (true) {
        if (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline| {
            const line = try allocator.dupe(u8, std.mem.trimEnd(u8, pending.items[0..newline], "\r"));
            const rest = pending.items.len - newline - 1;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[newline + 1 ..]);
            pending.items.len = rest;
            return line;
        }
        if (pending.items.len > limit) return error.McpLineTooLarge;
        // Take whatever has arrived (at least one byte): an SSE server sends a
        // short event and then waits, so filling a fixed-size chunk would block.
        const available = input.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => {
                if (pending.items.len == 0) return error.EndOfStream;
                // A final line without a newline.
                const line = try allocator.dupe(u8, std.mem.trimEnd(u8, pending.items, "\r"));
                pending.items.len = 0;
                return line;
            },
            else => return err,
        };
        try pending.appendSlice(allocator, available);
        input.toss(available.len);
    }
}

/// `Mcp-Name` / `Mcp-Param-*` values that are not printable ASCII (or that
/// look like the sentinel) travel as `=?base64?<b64 of UTF-8>?=`.
pub fn headerSafe(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var safe = !std.mem.startsWith(u8, value, "=?base64?");
    for (value) |byte| {
        if (byte < 0x20 or byte > 0x7e) safe = false;
    }
    if (value.len != 0 and (value[0] == ' ' or value[value.len - 1] == ' ')) safe = false;
    if (safe) return value;
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(value.len));
    _ = encoder.encode(encoded, value);
    return std.fmt.allocPrint(allocator, "=?base64?{s}?=", .{encoded});
}

const testing = std.testing;

test "header values that are not header-safe use the base64 sentinel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("get_weather", try headerSafe(a, "get_weather"));
    try testing.expectEqualStrings("=?base64?5Zyw5Z2A?=", try headerSafe(a, "地址"));
    try testing.expectEqualStrings("=?base64?ID1sZWFkaW5n?=", try headerSafe(a, " =leading"));
    try testing.expect(std.mem.startsWith(u8, try headerSafe(a, "=?base64?x?="), "=?base64?PT9"));
}

test "SSE lines split across reads are reassembled" {
    var input = std.Io.Reader.fixed("data: {\"a\":\r\ndata: 1}\r\n\r\n: keep-alive\n\nevent: x\ndata: two\n");
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(testing.allocator);
    const first = try readLine(&input, testing.allocator, &pending, 1024);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("data: {\"a\":", first);
}
