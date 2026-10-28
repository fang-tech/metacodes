const std = @import("std");
const net = @import("platform").net;

pub const Server = struct {
    listener: net.Socket,
    port: u16,
    bodies: []const []const u8,
    thread: std.Thread,
    closing: std.atomic.Value(bool) = .init(false),
    /// Revision 25: the authorization header value each of the first
    /// `MAX_RECORDED` requests carried. Read only after `join` has waited for
    /// the serving thread.
    authorizations: [MAX_RECORDED][128]u8 = undefined,
    authorization_lens: [MAX_RECORDED]usize = [_]usize{0} ** MAX_RECORDED,

    pub const MAX_RECORDED = 8;

    /// The authorization header value request `index` carried ("" when none).
    pub fn authorization(self: *const Server, index: usize) []const u8 {
        return self.authorizations[index][0..self.authorization_lens[index]];
    }

    pub fn start(_: std.Io, bodies: []const []const u8) !*Server {
        const listener = try net.listenLoopback(0, 16);
        errdefer net.closeSocket(listener.sock);
        const self = try std.heap.page_allocator.create(Server);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{
            .listener = listener.sock,
            .port = listener.port,
            .bodies = bodies,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    pub fn url(self: *const Server, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1/messages", .{self.port});
    }

    pub fn stop(self: *Server) void {
        self.join();
        self.destroy();
    }

    /// Stop serving and wait for the serving thread. The recorded
    /// authorizations stay readable until `destroy`.
    pub fn join(self: *Server) void {
        self.closing.store(true, .release);
        // Closing a socket does not reliably wake accept on every supported
        // Windows build. A loopback connection is a deterministic wake-up.
        if (net.connectLoopback(self.port)) |wake| net.closeSocket(wake) else |_| {}
        net.closeSocket(self.listener);
        self.thread.join();
    }

    pub fn destroy(self: *Server) void {
        std.heap.page_allocator.destroy(self);
    }

    fn serve(self: *Server) void {
        for (self.bodies, 0..) |body, index| {
            if (self.closing.load(.acquire)) return;
            const conn = net.acceptConn(self.listener) orelse return;
            if (self.closing.load(.acquire)) {
                net.closeSocket(conn);
                return;
            }
            const record: ?*[128]u8 = if (index < MAX_RECORDED) &self.authorizations[index] else null;
            const record_len: ?*usize = if (index < MAX_RECORDED) &self.authorization_lens[index] else null;
            serveResponse(conn, body, record, record_len);
            net.closeSocket(conn);
        }
    }
};

fn serveResponse(conn: net.Socket, body: []const u8, authorization: ?*[128]u8, authorization_len: ?*usize) void {
    // Winsock resets a connection that is closed while request bytes remain
    // unread.  The reset can discard an already-sent response, so consume the
    // complete fixed-length provider request before returning the SSE body.
    net.setRecvTimeoutMs(conn, 10_000);
    net.setSendTimeoutMs(conn, 10_000);
    if (!drainRequest(conn, authorization, authorization_len)) return;

    var header: [256]u8 = undefined;
    const header_bytes = std.fmt.bufPrint(
        &header,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body.len},
    ) catch return;
    sendAll(conn, header_bytes);
    sendAll(conn, body);
}

fn drainRequest(conn: net.Socket, authorization: ?*[128]u8, authorization_len: ?*usize) bool {
    var header: [16 * 1024]u8 = undefined;
    var total: usize = 0;
    var header_end: ?usize = null;
    var content_length: usize = 0;
    while (total < header.len and header_end == null) {
        const received = net.recv(conn, header[total..]);
        if (received <= 0) return false;
        total += @intCast(received);
        if (std.mem.indexOf(u8, header[0..total], "\r\n\r\n")) |index| {
            header_end = index + 4;
            content_length = parseContentLength(header[0..index]) orelse 0;
            if (authorization) |out| {
                const value = headerValue(header[0..index], "authorization") orelse "";
                const len = @min(value.len, out.len);
                @memcpy(out[0..len], value[0..len]);
                authorization_len.?.* = len;
            }
        }
    }

    const body_start = header_end orelse return false;
    const buffered_body = total - body_start;
    if (buffered_body >= content_length) return true;

    var remaining = content_length - buffered_body;
    var discard: [16 * 1024]u8 = undefined;
    while (remaining > 0) {
        const received = net.recv(conn, discard[0..@min(remaining, discard.len)]);
        if (received <= 0) return false;
        remaining -= @intCast(received);
    }
    return true;
}

fn parseContentLength(header: []const u8) ?usize {
    const value = headerValue(header, "Content-Length") orelse return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn headerValue(header: []const u8, wanted: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, wanted)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn sendAll(conn: net.Socket, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = net.send(conn, bytes[offset..]);
        if (written <= 0) return;
        offset += @intCast(written);
    }
}
