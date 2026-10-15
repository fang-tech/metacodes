//! Durable per-Step usage and per-run charge ledger for sealed Skill runs
//! (doc/SEALED_SKILL_PROTOCOL.md §6.6, §9 "Ledger").
//!
//! `<state root>/ledger/sealed.ndjson`, one JSON object per line. A `step`
//! record is written for every Step the gateway returned (its own usage and
//! the hash-chain link), a `charge` record for the receipt on `final` and
//! `failed`. The gateway's `cost_micros` is recorded as served; the client
//! never recomputes it.

const std = @import("std");
const pfs = @import("platform").fs;
const fs_util = @import("../../util/fs.zig");
const protocol = @import("protocol.zig");

pub const FILE_NAME = "sealed.ndjson";

pub const Kind = enum { step, charge };

pub const Record = struct {
    kind: Kind,
    ts: i64,
    session_id: []const u8,
    gateway: []const u8,
    skill_id: []const u8,
    run_id: []const u8,
    seq: u64,
    step_kind: []const u8 = "",
    model: []const u8 = "",
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    cost_micros: i64 = 0,
    cumulative_cost_micros: i64 = 0,
    currency: []const u8 = "",
    digest: []const u8 = "",
    prev_digest: []const u8 = "",
    issuer_skill_host: []const u8 = "",
    issuer_inference_gateway: []const u8 = "",
    /// Number of tool calls the Step carried.
    calls: u64 = 0,
};

/// `METACODES_LEDGER_DIR/sealed.ndjson`, else `<state_root>/ledger/sealed.ndjson`.
pub fn ledgerPath(allocator: std.mem.Allocator, state_root: []const u8) ![]u8 {
    if (std.c.getenv("METACODES_LEDGER_DIR")) |raw|
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, std.mem.span(raw), "/"), FILE_NAME });
    if (state_root.len == 0) return error.NoHome;
    return std.fs.path.join(allocator, &.{ state_root, "ledger", FILE_NAME });
}

pub fn render(allocator: std.mem.Allocator, record: Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"schema\":\"metacodes.sealed-ledger/v1\",\"kind\":");
    try protocol.writeString(w, @tagName(record.kind));
    try w.print(",\"ts\":{d},\"session_id\":", .{record.ts});
    try protocol.writeString(w, record.session_id);
    try w.writeAll(",\"gateway\":");
    try protocol.writeString(w, record.gateway);
    try w.writeAll(",\"skill_id\":");
    try protocol.writeString(w, record.skill_id);
    try w.writeAll(",\"run_id\":");
    try protocol.writeString(w, record.run_id);
    try w.print(",\"seq\":{d},\"step_kind\":", .{record.seq});
    try protocol.writeString(w, record.step_kind);
    try w.writeAll(",\"model\":");
    try protocol.writeString(w, record.model);
    try w.print(
        ",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_creation_tokens\":{d},\"cost_micros\":{d},\"cumulative_cost_micros\":{d},\"currency\":",
        .{ record.input_tokens, record.output_tokens, record.cache_read_tokens, record.cache_creation_tokens, record.cost_micros, record.cumulative_cost_micros },
    );
    try protocol.writeString(w, record.currency);
    try w.writeAll(",\"digest\":");
    try protocol.writeString(w, record.digest);
    try w.writeAll(",\"prev_digest\":");
    try protocol.writeString(w, record.prev_digest);
    try w.writeAll(",\"issuer\":{\"skill_host\":");
    try protocol.writeString(w, record.issuer_skill_host);
    try w.writeAll(",\"inference_gateway\":");
    try protocol.writeString(w, record.issuer_inference_gateway);
    try w.print("}},\"calls\":{d}}}\n", .{record.calls});
    return out.toOwnedSlice();
}

pub fn append(allocator: std.mem.Allocator, state_root: []const u8, record: Record) !void {
    const path = try ledgerPath(allocator, state_root);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try fs_util.mkdirParents(dir);
    const line = try render(allocator, record);
    defer allocator.free(line);
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true }, 0o600);
    if (fd < 0) return error.WriteFailed;
    defer pfs.close(fd);
    var written: usize = 0;
    while (written < line.len) {
        const n = pfs.write(fd, line[written..]);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

/// Whole ledger, or `error.NotFound`.
pub fn read(allocator: std.mem.Allocator, state_root: []const u8) ![]u8 {
    const path = try ledgerPath(allocator, state_root);
    defer allocator.free(path);
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.NotFound;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &chunk);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(allocator);
}

test "ledger line carries the gateway's charge verbatim" {
    const a = std.testing.allocator;
    const line = try render(a, .{
        .kind = .charge,
        .ts = 1,
        .session_id = "s",
        .gateway = "http://g/ssp",
        .skill_id = "ssk",
        .run_id = "run_1",
        .seq = 3,
        .step_kind = "final",
        .cost_micros = 24400,
        .cumulative_cost_micros = 24400,
        .currency = "USD",
        .digest = "sha256:ab",
    });
    defer a.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"charge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"cost_micros\":24400") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
}
