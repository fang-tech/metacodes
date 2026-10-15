//! `metacodes sealed …`: the operator surface of doc/SEALED_SKILL_PROTOCOL.md.
//!
//! - `install <gateway-url> <skill_id> [--token-env NAME] [--yes]` fetches the
//!   Entry, shows what the user consents to (§6.1) and pins it;
//! - `list` prints the pins under the state root;
//! - `ledger` prints the sealed usage ledger (§6.6);
//! - `serve --skills <dir> [--listen PORT] [--token T] [--provider KIND]
//!   [--model M] [--base-url U] [--api-key-env NAME]` runs the reference
//!   gateway on loopback with the server's own provider credentials.

const std = @import("std");
const pfs = @import("platform").fs;
const paths = @import("platform").paths;
const util_time = @import("../util/time.zig");
const protocol = @import("../skills/sealed/protocol.zig");
const transport = @import("../skills/sealed/transport.zig");
const pin_mod = @import("../skills/sealed/pin.zig");
const ledger = @import("../skills/sealed/ledger.zig");
const gateway_mod = @import("../skills/sealed/gateway.zig");
const provider_factory = @import("../api/provider_factory.zig");
const types = @import("../types.zig");

const USAGE =
    \\usage: metacodes sealed install <gateway-url> <skill_id> [--token-env NAME] [--yes]
    \\       metacodes sealed list
    \\       metacodes sealed ledger
    \\       metacodes sealed serve --skills <dir> [--listen PORT] [--token T]
    \\                              [--provider anthropic|openai|gemini] [--model M]
    \\                              [--base-url U] [--api-key-env NAME]
    \\
;

pub fn run(args: *std.process.Args.Iterator, allocator: std.mem.Allocator, io: std.Io, state_root: []const u8) u8 {
    const sub = args.next() orelse {
        std.debug.print("{s}", .{USAGE});
        return 2;
    };
    if (std.mem.eql(u8, sub, "install")) return install(args, allocator, io, state_root);
    if (std.mem.eql(u8, sub, "list")) return list(allocator, state_root);
    if (std.mem.eql(u8, sub, "ledger")) return printLedger(allocator, state_root);
    if (std.mem.eql(u8, sub, "serve")) return serve(args, allocator);
    std.debug.print("error: unknown sealed subcommand '{s}'\n{s}", .{ sub, USAGE });
    return 2;
}

fn envValue(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const z = allocator.dupeZ(u8, name) catch return null;
    defer allocator.free(z);
    const raw = std.c.getenv(z.ptr) orelse return null;
    return std.mem.span(raw);
}

fn install(args: *std.process.Args.Iterator, allocator: std.mem.Allocator, io: std.Io, state_root: []const u8) u8 {
    const url = args.next() orelse {
        std.debug.print("{s}", .{USAGE});
        return 2;
    };
    const skill_id = args.next() orelse {
        std.debug.print("{s}", .{USAGE});
        return 2;
    };
    var token_env: []const u8 = pin_mod.DEFAULT_TOKEN_ENV;
    var yes = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            yes = true;
        } else if (std.mem.eql(u8, arg, "--token-env")) {
            token_env = args.next() orelse {
                std.debug.print("error: --token-env needs a name\n", .{});
                return 2;
            };
        } else {
            std.debug.print("error: unknown install argument '{s}'\n", .{arg});
            return 2;
        }
    }
    if (state_root.len == 0) {
        std.debug.print("error: no state root; pass --state-dir or set METACODES_HOME\n", .{});
        return 1;
    }
    const token = envValue(allocator, token_env) orelse "";
    var client = transport.Client.init(allocator, io, url, token) catch |err| {
        std.debug.print("error: gateway URL rejected ({s})\n", .{@errorName(err)});
        return 1;
    };
    defer client.deinit();
    var params: std.Io.Writer.Allocating = .init(allocator);
    defer params.deinit();
    protocol.writeSkillsGetParams(&params.writer, skill_id) catch return 1;
    var response = client.call(.skills_get, params.written(), null) catch |err| {
        std.debug.print("error: gateway call failed ({s}, http {d})\n", .{ @errorName(err), client.last_http_status });
        return 1;
    };
    defer response.deinit();
    const entry_json = switch (response.response) {
        .result => |result| result,
        .err => |rpc| {
            std.debug.print("error: gateway refused ({s}): {s}\n", .{ if (rpc.known) |k| k.name() else "error", rpc.message });
            return 1;
        },
    };
    var parsed = protocol.parseEntry(allocator, entry_json) catch |err| {
        std.debug.print("error: the gateway's Entry does not verify ({s}); nothing pinned\n", .{@errorName(err)});
        return 1;
    };
    defer parsed.deinit();
    const entry = &parsed.entry;
    if (!entry.manifest.executionSupported()) {
        std.debug.print("error: this Skill needs execution classes this client does not run\n", .{});
        return 1;
    }
    printConsent(entry, url, token_env);
    if (!yes) {
        std.debug.print("Pin this manifest? [y/N] ", .{});
        if (!readYes()) {
            std.debug.print("Not installed.\n", .{});
            return 1;
        }
    }
    pin_mod.write(allocator, state_root, url, token_env, entry_json, entry) catch |err| {
        std.debug.print("error: could not write the pin ({s})\n", .{@errorName(err)});
        return 1;
    };
    std.debug.print("Installed /{s} (sealed, {s}). Run it with /{s} <arguments>.\n", .{ entry.manifest.name, entry.manifest_digest, entry.manifest.name });
    return 0;
}

/// What the user consents to when pinning (§6.1): identity, allowlist,
/// egress, credentials and price. Printed in full; never summarized away.
fn printConsent(entry: *const protocol.Entry, url: []const u8, token_env: []const u8) void {
    const m = &entry.manifest;
    std.debug.print("\nSealed Skill /{s} v{s}\n", .{ m.name, m.version });
    std.debug.print("  gateway:     {s} (token from ${s})\n", .{ url, token_env });
    std.debug.print("  skill id:    {s}\n", .{entry.skill_id});
    std.debug.print("  manifest:    {s}\n", .{entry.manifest_digest});
    std.debug.print("  creator:     {s}{s}{s}\n", .{ m.creator_display_name, if (m.creator_id.len != 0) " / " else "", m.creator_id });
    std.debug.print("  description: {s}\n", .{m.description});
    std.debug.print("  tools allowed:", .{});
    for (m.tools_allow) |rule| std.debug.print(" {s}", .{rule});
    std.debug.print("\n", .{});
    if (m.tools_deny.len != 0) {
        std.debug.print("  tools denied: ", .{});
        for (m.tools_deny) |rule| std.debug.print(" {s}", .{rule});
        std.debug.print("\n", .{});
    }
    if (m.confirmation_required_for.len != 0) {
        std.debug.print("  always confirms:", .{});
        for (m.confirmation_required_for) |rule| std.debug.print(" {s}", .{rule});
        std.debug.print("\n", .{});
    }
    std.debug.print("  data leaving this machine as tool results:", .{});
    if (m.egress_classes.len == 0) std.debug.print(" (none declared)", .{});
    for (m.egress_classes) |class| std.debug.print(" {s}", .{class});
    std.debug.print(" (up to {d} bytes per result, retention: {s})\n", .{ m.egress_max_result_bytes, m.egress_retention });
    if (m.credentials.len != 0) {
        std.debug.print("  credentials it will ask for:", .{});
        for (m.credentials) |credential| std.debug.print(" {s} ({s})", .{ credential.ref, credential.purpose });
        std.debug.print("\n", .{});
    }
    if (m.pricing_estimate_micros != 0 or m.pricing_model.len != 0) {
        std.debug.print("  pricing:     {s}, about {d}.{d:0>6} {s} per run\n", .{
            m.pricing_model,
            @divTrunc(m.pricing_estimate_micros, 1_000_000),
            @as(u64, @intCast(@mod(m.pricing_estimate_micros, 1_000_000))),
            m.pricing_currency,
        });
    }
    std.debug.print("  Skill content stays on the gateway; every tool call is approved here.\n\n", .{});
}

fn readYes() bool {
    var buf: [16]u8 = undefined;
    const n = pfs.read(0, &buf);
    if (n <= 0) return false;
    const line = std.mem.trim(u8, buf[0..@intCast(n)], " \r\n\t");
    return line.len != 0 and (line[0] == 'y' or line[0] == 'Y');
}

fn list(allocator: std.mem.Allocator, state_root: []const u8) u8 {
    var listing = pin_mod.list(allocator, state_root) catch |err| {
        std.debug.print("error: could not read pins ({s})\n", .{@errorName(err)});
        return 1;
    };
    defer listing.deinit();
    if (listing.pins.len == 0) {
        std.debug.print("No sealed Skills pinned.\n", .{});
        return 0;
    }
    for (listing.pins) |pin| {
        if (pin.broken) |err| {
            std.debug.print("/{s}  BROKEN ({s})\n", .{ pin.name, @errorName(err) });
            continue;
        }
        std.debug.print("/{s}  v{s}  {s}  {s}  {s}\n", .{ pin.name, pin.version, pin.gateway_url, pin.creator, pin.manifest_digest });
    }
    return 0;
}

fn printLedger(allocator: std.mem.Allocator, state_root: []const u8) u8 {
    const bytes = ledger.read(allocator, state_root) catch |err| {
        if (err == error.NotFound) return 0;
        std.debug.print("error: could not read the sealed ledger ({s})\n", .{@errorName(err)});
        return 1;
    };
    defer allocator.free(bytes);
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = pfs.write(1, bytes[pos..]);
        if (n <= 0) break;
        pos += @intCast(n);
    }
    return 0;
}

fn serve(args: *std.process.Args.Iterator, allocator: std.mem.Allocator) u8 {
    var skills_dir: ?[]const u8 = null;
    var port: u16 = 8787;
    var token: []const u8 = "";
    var kind: types.ProviderKind = .anthropic;
    var model: []const u8 = "claude-sonnet-4-5";
    var base_url: ?[]const u8 = null;
    var api_key_env: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--skills")) {
            skills_dir = args.next() orelse return usageError("--skills needs a directory");
        } else if (std.mem.eql(u8, arg, "--listen")) {
            const raw = args.next() orelse return usageError("--listen needs a port");
            port = std.fmt.parseInt(u16, raw, 10) catch return usageError("--listen takes a loopback port number");
        } else if (std.mem.eql(u8, arg, "--token")) {
            token = args.next() orelse return usageError("--token needs a value");
        } else if (std.mem.eql(u8, arg, "--provider")) {
            const raw = args.next() orelse return usageError("--provider needs a kind");
            kind = std.meta.stringToEnum(types.ProviderKind, raw) orelse return usageError("--provider is anthropic, openai or gemini");
        } else if (std.mem.eql(u8, arg, "--model")) {
            model = args.next() orelse return usageError("--model needs a name");
        } else if (std.mem.eql(u8, arg, "--base-url")) {
            base_url = args.next() orelse return usageError("--base-url needs a URL");
        } else if (std.mem.eql(u8, arg, "--api-key-env")) {
            api_key_env = args.next() orelse return usageError("--api-key-env needs a name");
        } else {
            std.debug.print("error: unknown serve argument '{s}'\n", .{arg});
            return 2;
        }
    }
    const dir = skills_dir orelse return usageError("--skills <dir> is required");
    const key_env = api_key_env orelse switch (kind) {
        .anthropic => "ANTHROPIC_API_KEY",
        .openai => "OPENAI_API_KEY",
        .gemini => "GEMINI_API_KEY",
    };
    const api_key = envValue(allocator, key_env) orelse {
        std.debug.print("error: the gateway's provider key must be in ${s} (it is the operator's key, never a client's)\n", .{key_env});
        return 1;
    };
    var owned = provider_factory.makeProvider(allocator, kind, api_key, model, base_url) catch |err| {
        std.debug.print("error: provider setup failed ({s})\n", .{@errorName(err)});
        return 1;
    };
    defer owned.deinit();
    const gateway = gateway_mod.Gateway.init(allocator, owned.provider(), dir, .{ .token = token }) catch |err| {
        std.debug.print("error: could not load Skill packages from {s} ({s})\n", .{ dir, @errorName(err) });
        return 1;
    };
    defer gateway.deinit();
    const server = gateway_mod.Server.start(allocator, gateway, port) catch |err| {
        std.debug.print("error: could not listen on 127.0.0.1:{d} ({s})\n", .{ port, @errorName(err) });
        return 1;
    };
    defer server.stop();
    std.debug.print("sealed gateway: {d} Skill package(s) from {s}\n", .{ gateway.packages.len, dir });
    for (gateway.packages) |package| std.debug.print("  {s}  {s}  {s}\n", .{ package.entry.skill_id, package.name, package.entry.manifest_digest });
    std.debug.print("listening on http://127.0.0.1:{d}/ssp (provider {s}, model {s}{s})\n", .{ server.port, @tagName(kind), model, if (token.len == 0) ", no token: open to every local caller" else "" });
    while (true) util_time.sleepMs(1000);
}

fn usageError(message: []const u8) u8 {
    std.debug.print("error: {s}\n{s}", .{ message, USAGE });
    return 2;
}
