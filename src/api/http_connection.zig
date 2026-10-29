//! Sending a std.http request without handing a broken connection back to the
//! client's pool.
//!
//! `Request.deinit` (Zig 0.16) returns the connection to the pool unless it is
//! marked `closing`, and it counts a request that never received a response
//! head (`reader.state == .ready`) as reusable. `receiveHead` marks the
//! connection when its read fails; a failed send marks nothing. A connection
//! the peer reset in the middle of a request body therefore goes back to the
//! pool, the next request to that host takes it again, its first write fails
//! at once, and so does every retry after it: the client never opens another
//! connection for the rest of the process. `keep_alive = false` does not
//! prevent it, because std applies that option only once a head arrives.
//!
//! Seen 2026-10-29: a 2.5 MB Messages request cut off 71 s into its upload
//! left a TUI failing every later request in 4 ms, ten retries a message, with
//! no new TCP connection, while a fresh process on the same network worked.
//!
//! Every request in `src/` sends through these two functions instead of the
//! `Request` methods of the same names; a source guard in
//! tests/component/http_send_failure_test.zig keeps it that way.

const std = @import("std");

const Request = std.http.Client.Request;

/// `request.sendBodyComplete(body)`. A connection the send failed on is closed
/// by `Request.deinit` instead of being pooled.
pub fn sendBodyComplete(request: *Request, body: []u8) std.Io.Writer.Error!void {
    request.sendBodyComplete(body) catch |err| return dropConnection(request, err);
}

/// `request.sendBodiless()`, with the same rule as `sendBodyComplete`.
pub fn sendBodiless(request: *Request) std.Io.Writer.Error!void {
    request.sendBodiless() catch |err| return dropConnection(request, err);
}

fn dropConnection(request: *Request, err: std.Io.Writer.Error) std.Io.Writer.Error {
    if (request.connection) |connection| connection.closing = true;
    return err;
}
