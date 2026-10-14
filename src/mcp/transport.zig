//! The two MCP transports behind one message-stream interface.

const std = @import("std");
const StdioTransport = @import("transport_stdio.zig").StdioTransport;
const http = @import("transport_http.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const Capture = @import("../core/tool_result_artifact.zig").Capture;

pub const HttpTransport = http.HttpTransport;
pub const SendMeta = http.SendMeta;
pub const Header = http.Header;

pub const Transport = union(enum) {
    stdio: StdioTransport,
    http: *HttpTransport,

    pub fn send(self: *Transport, json: []const u8, meta: SendMeta) !void {
        return switch (self.*) {
            .stdio => |*stdio| stdio.send(json),
            .http => |transport| transport.send(json, meta),
        };
    }

    pub fn recvLine(self: *Transport) ![]u8 {
        return switch (self.*) {
            .stdio => |*stdio| stdio.recvLine(),
            .http => |transport| transport.recvLine(),
        };
    }

    pub fn recvLineCapture(self: *Transport, capture: *Capture) !void {
        return switch (self.*) {
            .stdio => |*stdio| stdio.recvLineCapture(capture),
            .http => |transport| transport.recvLineCapture(capture),
        };
    }

    pub fn setDeadline(self: *Transport, deadline_ms: ?i64) void {
        switch (self.*) {
            .stdio => |*stdio| stdio.deadline_ms = deadline_ms,
            .http => |transport| transport.deadline_ms = deadline_ms,
        }
    }

    pub fn setAbort(self: *Transport, abort: ?*const AbortSignal) void {
        switch (self.*) {
            .stdio => |*stdio| stdio.abort = abort,
            .http => |transport| transport.abort = abort,
        }
    }

    pub fn close(self: *Transport) void {
        switch (self.*) {
            .stdio => |*stdio| stdio.close(),
            .http => |transport| transport.close(),
        }
    }

    pub fn isHttp(self: *const Transport) bool {
        return self.* == .http;
    }
};
