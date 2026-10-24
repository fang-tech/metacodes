//! Provider-scoped API keys at rest.
//!
//! `<state_root>/keys/<provider>.json`, mode 0600, written atomically like an
//! OAuth login (`oauth.writeAtomicPrivate`). One file per provider is the
//! scope: the resolver is handed a provider's own file and nothing else, so a
//! key stored for one vendor cannot satisfy another. `config.json` stays free
//! of secrets — it may only name environment variables.
//!
//! ```json
//! {"schema_version":1,"kind":"zai_coding_plan_api_key","key":"…","page":"cn-personal","stored_at":1793000000}
//! ```

const std = @import("std");
const ids = @import("ids.zig");
const credential = @import("credential.zig");
const oauth = @import("oauth.zig");
const pfs = @import("platform").fs;

const Slug = ids.Slug;

pub const SCHEMA_VERSION: u32 = 1;

pub const LoadError = error{ OutOfMemory, InvalidKeyFile, ReadFailed };

/// A stored key, owned. `deinit` zeroes the secret before freeing it.
pub const Stored = struct {
    allocator: std.mem.Allocator,
    kind: credential.CredentialKind,
    secret: []u8,
    /// The key page it was created on (`KeyPage.id`), when known.
    page: ?[]u8 = null,

    pub fn deinit(self: *Stored) void {
        oauth.secureFree(self.allocator, self.secret);
        if (self.page) |page| self.allocator.free(page);
        self.* = undefined;
    }

    /// The resolver's view: borrowed, valid while `self` is.
    pub fn entry(self: *const Stored) credential.StoredEntry {
        return .{ .kind = self.kind, .secret = self.secret };
    }
};

/// Where `provider_id`'s key lives (owned).
pub fn pathFor(allocator: std.mem.Allocator, state_root: []const u8, provider_id: Slug) error{ OutOfMemory, NoHome }![]u8 {
    if (state_root.len == 0) return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/keys/{s}.json", .{ state_root, provider_id.slice() });
}

pub fn save(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    provider_id: Slug,
    kind: credential.CredentialKind,
    secret: []const u8,
    page: ?[]const u8,
    now_seconds: i64,
) !void {
    if (secret.len == 0) return error.EmptyKey;
    const path = try pathFor(allocator, state_root, provider_id);
    defer allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    // The document holds the key: zero it whatever happens to the write.
    defer {
        std.crypto.secureZero(u8, out.writer.buffer[0..out.writer.end]);
        out.deinit();
    }
    const w = &out.writer;
    try w.print("{{\"schema_version\":{d},\"kind\":", .{SCHEMA_VERSION});
    try std.json.Stringify.value(kind.id(), .{}, w);
    try w.writeAll(",\"key\":");
    try std.json.Stringify.value(secret, .{}, w);
    if (page) |value| {
        try w.writeAll(",\"page\":");
        try std.json.Stringify.value(value, .{}, w);
    }
    try w.print(",\"stored_at\":{d}}}\n", .{now_seconds});
    try oauth.writeAtomicPrivate(allocator, path, out.writer.buffer[0..out.writer.end]);
}

/// `provider_id`'s stored key, or null when none is stored. A file that does
/// not parse, carries a newer schema, or names a kind this build does not know
/// is an error rather than "no key": the user stored something and should
/// hear that it cannot be used.
pub fn load(allocator: std.mem.Allocator, state_root: []const u8, provider_id: Slug) LoadError!?Stored {
    const path = pathFor(allocator, state_root, provider_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoHome => return null,
    };
    defer allocator.free(path);
    const bytes = oauth.readFile(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Classified right after the failed open, before anything else can
        // set errno.
        error.OpenFailed => return if (pfs.lastErrnoIs(.NOENT)) null else error.ReadFailed,
        else => return error.ReadFailed,
    };
    defer oauth.secureFree(allocator, bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidKeyFile,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidKeyFile;
    const object = parsed.value.object;
    const version = object.get("schema_version") orelse return error.InvalidKeyFile;
    if (version != .integer or version.integer != SCHEMA_VERSION) return error.InvalidKeyFile;
    const kind_text = stringOf(object.get("kind")) orelse return error.InvalidKeyFile;
    const kind = credential.CredentialKind.parse(kind_text) orelse return error.InvalidKeyFile;
    const key = stringOf(object.get("key")) orelse return error.InvalidKeyFile;
    if (key.len == 0) return error.InvalidKeyFile;

    const secret = try allocator.dupe(u8, key);
    errdefer oauth.secureFree(allocator, secret);
    const page = if (stringOf(object.get("page"))) |text| try allocator.dupe(u8, text) else null;
    // The parse tree held the key too.
    zeroStrings(parsed.value);
    return .{ .allocator = allocator, .kind = kind, .secret = secret, .page = page };
}

/// Forget `provider_id`'s key. True when one was removed.
pub fn remove(allocator: std.mem.Allocator, state_root: []const u8, provider_id: Slug) !bool {
    const path = pathFor(allocator, state_root, provider_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoHome => return false,
    };
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (!pfs.exists(path_z)) return false;
    pfs.unlinkPath(path_z) catch return error.RemoveFailed;
    return true;
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}

fn zeroStrings(value: std.json.Value) void {
    switch (value) {
        .string => |text| std.crypto.secureZero(u8, @constCast(text)),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |pair| zeroStrings(pair.value_ptr.*);
        },
        .array => |array| for (array.items) |item| zeroStrings(item),
        else => {},
    }
}

const testing = std.testing;

fn testRoot(buffer: []u8, tmp: *std.testing.TmpDir) ![]const u8 {
    return buffer[0..try tmp.dir.realPath(std.testing.io, buffer)];
}

test "a stored key round-trips with its kind and page, in a private file" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try testRoot(&root_buf, &tmp);
    const zai = Slug.lit("zai-coding-plan");

    try testing.expect(try load(a, root, zai) == null);
    try save(a, root, zai, .zai_coding_plan_api_key, "plan-key-123", "cn-personal", 1_793_000_000);
    var stored = (try load(a, root, zai)).?;
    defer stored.deinit();
    try testing.expectEqual(credential.CredentialKind.zai_coding_plan_api_key, stored.kind);
    try testing.expectEqualStrings("plan-key-123", stored.secret);
    try testing.expectEqualStrings("cn-personal", stored.page.?);
    try testing.expectEqualStrings("plan-key-123", stored.entry().secret);

    // Another provider sees none of it.
    try testing.expect(try load(a, root, Slug.lit("openai")) == null);

    if (@import("builtin").os.tag != .windows) {
        const path = try pathFor(a, root, zai);
        defer a.free(path);
        const path_z = try a.dupeZ(u8, path);
        defer a.free(path_z);
        const fd = try pfs.openZ(path_z, .{ .ACCMODE = .RDONLY }, 0);
        defer pfs.close(fd);
        const info = try pfs.fileInfo(fd);
        try testing.expectEqual(@as(u32, 0o600), info.mode & 0o777);
    }

    try testing.expect(try remove(a, root, zai));
    try testing.expect(try load(a, root, zai) == null);
    try testing.expect(!try remove(a, root, zai));
}

test "a stored file that cannot be used is an error, not a missing key" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try testRoot(&root_buf, &tmp);
    try tmp.dir.createDirPath(std.testing.io, "keys");
    for ([_][]const u8{
        "not json",
        "{\"schema_version\":2,\"kind\":\"api_key\",\"key\":\"k\"}",
        "{\"schema_version\":1,\"kind\":\"martian_key\",\"key\":\"k\"}",
        "{\"schema_version\":1,\"kind\":\"api_key\",\"key\":\"\"}",
    }) |document| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keys/openai.json", .data = document });
        try testing.expectError(error.InvalidKeyFile, load(a, root, Slug.lit("openai")));
    }
}
