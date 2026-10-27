//! L2: WebFetch decodes compressed responses or fails explicitly (#358).
//!
//! A loopback server answers with a fixed Content-Encoding whatever the
//! request advertised, as the issue's server did. Before the fix curl ran
//! without `--compressed`, passed the compressed bytes to HTML extraction and
//! WebFetch reported the garbage as a successful page. Every case runs the
//! production artifact path and the legacy inline path, through the real curl.

const std = @import("std");
const cc = @import("cc");
const net = @import("platform").net;

const MARKER = "ISSUE358 readable body: Python release 中文内容";
const PAGE = "<html><body><p>" ++ MARKER ++ "</p></body></html>";

// PAGE compressed by Python: gzip.compress(PAGE, mtime=0) and zlib.compress(PAGE).
const GZIP_PAGE =
    "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x0a\xb3\xc9\x28\xc9\xcd\xb1\xb3\x49\xca\x4f\xa9\xb4\xb3\x29" ++
    "\xb0\xf3\x0c\x0e\x0e\x75\x35\x36\xb5\x50\x28\x4a\x4d\x4c\x49\x4c\xca\x49\x55\x00\xc9\x58\x29\x04" ++
    "\x54\x96\x64\xe4\xe7\x01\x45\x73\x52\x13\x8b\x53\x15\x9e\xec\x58\xfb\x6c\x5a\xfb\xd3\xb6\xd6\xa7" ++
    "\xeb\x76\xda\xe8\x17\xd8\xd9\xe8\x43\x0c\xd0\x07\x9b\x06\x00\x85\xa2\x5f\xd1\x54\x00\x00\x00";
const DEFLATE_PAGE =
    "\x78\x9c\xb3\xc9\x28\xc9\xcd\xb1\xb3\x49\xca\x4f\xa9\xb4\xb3\x29\xb0\xf3\x0c\x0e\x0e\x75\x35\x36" ++
    "\xb5\x50\x28\x4a\x4d\x4c\x49\x4c\xca\x49\x55\x00\xc9\x58\x29\x04\x54\x96\x64\xe4\xe7\x01\x45\x73" ++
    "\x52\x13\x8b\x53\x15\x9e\xec\x58\xfb\x6c\x5a\xfb\xd3\xb6\xd6\xa7\xeb\x76\xda\xe8\x17\xd8\xd9\xe8" ++
    "\x43\x0c\xd0\x07\x9b\x06\x00\x28\x54\x20\xdc";
/// A valid Brotli stream of one uncompressed meta-block (RFC 7932 §9.2):
/// WBITS=16, ISLAST=0, MNIBBLES=4, MLEN-1, ISUNCOMPRESSED=1 in 21 bits padded
/// to three bytes, the raw bytes, then an empty last meta-block (0x03).
const BROTLI_PAGE = brotliStored(PAGE);
/// The gzip header and the first deflate bytes, then zeros: curl starts
/// decoding and fails mid-body.
const CORRUPT_GZIP_PAGE = GZIP_PAGE[0..20] ++ "\x00" ** 30;

fn brotliStored(comptime data: []const u8) *const [data.len + 4]u8 {
    comptime {
        std.debug.assert(data.len > 0 and data.len <= 1 << 16);
        const header: u24 = ((data.len - 1) << 4) | (1 << 20);
        const bytes = [3]u8{ @truncate(header), @truncate(header >> 8), @truncate(header >> 16) } ++ data[0..data.len].* ++ [1]u8{0x03};
        return &bytes;
    }
}

/// One-shot loopback server: records the request head, then answers with
/// `body` under `content_encoding` and closes.
const EncodedResponder = struct {
    listener: net.Listener,
    content_encoding: ?[]const u8,
    body: []const u8,
    request: [8192]u8 = undefined,
    request_len: usize = 0,

    fn serve(self: *EncodedResponder) void {
        // A client that never connects fails the test instead of hanging it.
        if (!net.pollReadable(self.listener.sock, 30_000)) return;
        const conn = net.acceptConn(self.listener.sock) orelse return;
        defer net.closeSocket(conn);
        while (self.request_len < self.request.len) {
            if (!net.pollReadable(conn, 10_000)) return;
            const n = net.recv(conn, self.request[self.request_len..]);
            if (n <= 0) return;
            self.request_len += @intCast(n);
            if (std.mem.indexOf(u8, self.request[0..self.request_len], "\r\n\r\n") != null) break;
        }
        var head_buffer: [512]u8 = undefined;
        var head: std.Io.Writer = .fixed(&head_buffer);
        head.print("HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: {d}\r\nconnection: close\r\n", .{self.body.len}) catch return;
        if (self.content_encoding) |encoding| head.print("content-encoding: {s}\r\n", .{encoding}) catch return;
        head.writeAll("\r\n") catch return;
        sendAll(conn, head.buffered());
        sendAll(conn, self.body);
    }

    fn sendAll(conn: net.Socket, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = net.send(conn, bytes[off..]);
            if (n <= 0) return;
            off += @intCast(n);
        }
    }

    /// The request's Accept-Encoding value, or null when it sent none.
    fn acceptEncoding(self: *const EncodedResponder) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.request[0..self.request_len], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "accept-encoding"))
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }
};

const Fetched = struct {
    /// The `content` of a successful result.
    content: ?[]const u8 = null,
    /// The error detail of a failed one.
    failure: ?[]const u8 = null,
    accept_encoding: ?[]const u8 = null,
};

/// Fetch `body` served under `content_encoding` with WebFetch. An empty
/// `artifact_root` takes the legacy inline path. Results live in `arena`.
fn fetchEncoded(
    arena: std.mem.Allocator,
    artifact_root: []const u8,
    content_encoding: ?[]const u8,
    body: []const u8,
) !Fetched {
    const allocator = std.testing.allocator;
    var responder = EncodedResponder{
        .listener = try net.listenLoopback(0, 1),
        .content_encoding = content_encoding,
        .body = body,
    };
    defer net.closeSocket(responder.listener.sock);
    const thread = try std.Thread.spawn(.{}, EncodedResponder.serve, .{&responder});
    var joined = false;
    defer if (!joined) thread.join();

    const args = try std.fmt.allocPrint(arena, "{{\"url\":\"http://127.0.0.1:{d}/page\"}}", .{responder.listener.port});
    var detail: ?[]const u8 = null;
    defer if (detail) |text| allocator.free(text);
    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.artifact_root = artifact_root;
    ctx.error_detail = &detail;

    var fetched: Fetched = .{};
    if (cc.tools.dispatch(&ctx, "WebFetch", args)) |outcome_value| {
        var outcome = outcome_value;
        defer outcome.deinit(allocator);
        if (outcome != .ok or outcome.ok != .@"inline") return error.UnexpectedResultShape;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, outcome.ok.@"inline".bytes, .{});
        fetched.content = parsed.object.get("content").?.string;
    } else |err| {
        if (err != error.FetchFailed) return err;
        fetched.failure = try arena.dupe(u8, detail orelse "");
    }
    thread.join();
    joined = true;
    if (responder.acceptEncoding()) |value| fetched.accept_encoding = try arena.dupe(u8, value);
    return fetched;
}

/// Both WebFetch paths: the production artifact path and the legacy one.
fn forEachPath(comptime check: anytype) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    for ([_][]const u8{ root_buffer[0..root_len], "" }) |artifact_root| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        try check(arena_state.allocator(), artifact_root);
    }
}

fn expectPage(fetched: Fetched) !void {
    if (fetched.failure) |failure| {
        std.debug.print("WebFetch failed: {s}\n", .{failure});
        return error.TestUnexpectedFailure;
    }
    // Equal, not merely containing: the stored Brotli stream carries the page
    // verbatim, so an undecoded fetch would still contain the marker, between
    // the stream's header and trailer bytes.
    try std.testing.expectEqualStrings(MARKER, std.mem.trim(u8, fetched.content.?, " \t\r\n"));
}

fn expectUndecodable(fetched: Fetched) !void {
    if (fetched.content) |content| {
        std.debug.print("WebFetch returned a page: {s}\n", .{content});
        return error.TestUnexpectedSuccess;
    }
    try std.testing.expect(std.mem.indexOf(u8, fetched.failure.?, "could not decode the response body: curl: (61)") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched.failure.?, "OFFLINE") == null);
}

test "WebFetch advertises the encodings curl decodes and reads an uncompressed page" {
    try forEachPath(struct {
        fn check(arena: std.mem.Allocator, artifact_root: []const u8) !void {
            const fetched = try fetchEncoded(arena, artifact_root, null, PAGE);
            try expectPage(fetched);
            const accept = fetched.accept_encoding orelse return error.NoAcceptEncoding;
            try std.testing.expect(std.mem.indexOf(u8, accept, "gzip") != null);
            try std.testing.expect(std.mem.indexOf(u8, accept, "deflate") != null);
        }
    }.check);
}

test "WebFetch decodes a gzip response the server sends unasked" {
    try forEachPath(struct {
        fn check(arena: std.mem.Allocator, artifact_root: []const u8) !void {
            try expectPage(try fetchEncoded(arena, artifact_root, "gzip", GZIP_PAGE));
        }
    }.check);
}

test "WebFetch decodes a deflate response" {
    try forEachPath(struct {
        fn check(arena: std.mem.Allocator, artifact_root: []const u8) !void {
            try expectPage(try fetchEncoded(arena, artifact_root, "deflate", DEFLATE_PAGE));
        }
    }.check);
}

test "WebFetch decodes a Brotli response, or fails explicitly where curl has no Brotli" {
    try forEachPath(struct {
        fn check(arena: std.mem.Allocator, artifact_root: []const u8) !void {
            const fetched = try fetchEncoded(arena, artifact_root, "br", BROTLI_PAGE);
            if (fetched.content != null) return expectPage(fetched);
            try expectUndecodable(fetched);
        }
    }.check);
}

test "WebFetch fails explicitly on an encoding curl does not know" {
    try forEachPath(struct {
        fn check(arena: std.mem.Allocator, artifact_root: []const u8) !void {
            try expectUndecodable(try fetchEncoded(arena, artifact_root, "x-metacodes-unknown", PAGE));
        }
    }.check);
}

test "WebFetch fails explicitly on a corrupt gzip body instead of returning its decoded prefix" {
    try forEachPath(struct {
        fn check(arena: std.mem.Allocator, artifact_root: []const u8) !void {
            try expectUndecodable(try fetchEncoded(arena, artifact_root, "gzip", CORRUPT_GZIP_PAGE));
        }
    }.check);
}
