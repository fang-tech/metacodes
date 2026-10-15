//! Reference SSP/1 gateway: the server side of doc/SEALED_SKILL_PROTOCOL.md.
//!
//! `metacodes sealed serve` loads Skill packages (`<dir>/<name>/SKILL.md` +
//! `manifest.json`), answers the six protocol methods over a small HTTP/1.1
//! loop, and drives each run with the server's own model provider — the
//! provider's API key, never the client's. Every model call becomes one Step:
//! the model's tool calls are returned to the client instead of being
//! executed here, and the client's results come back as the next request.
//!
//! The gateway is stateless per run: the whole run (conversation, pending
//! calls, totals, caps) travels in `run_state`, sealed with XChaCha20-Poly1305
//! under a process key, so a tampered or replayed blob fails closed. Nothing
//! about a run is stored server-side, which is what `egress.retention: "run"`
//! promises.
//!
//! Metering is first-party: `usage.cost_micros` is computed from the
//! provider's reported tokens with the local price table, and is what the
//! `charge` receipt carries.
//!
//! Two things the model sees that are not client tools: the gateway's own
//! `AskUser` tool, whose call becomes an `input_required` Step (§4.3) and
//! whose answer comes back as that Step's one result; and the credential
//! placeholders `${SEALED_CRED:<ref>}` for the references the manifest
//! declares (§6.4) — a call whose input names one is annotated with
//! `credentials: [<ref>]` so the client substitutes and redacts it.

const std = @import("std");
const protocol = @import("protocol.zig");
const credentials = @import("credentials.zig");
const definition = @import("../runtime/definition.zig");
const provider_mod = @import("../../api/provider.zig");
const api_stream = @import("../../api/stream.zig");
const api_request = @import("../../api/request.zig");
const types = @import("../../types.zig");
const json_mod = @import("../../json.zig");
const pricing = @import("../../util/pricing.zig");
const log = @import("../../util/log.zig");
const net = @import("platform").net;
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;
const psync = @import("platform").sync;

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Base64 = std.base64.url_safe_no_pad;

pub const DEFAULT_OPERATOR = "metacodes";
pub const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_STATE_BYTES: usize = 256 * 1024;
/// Policy violations reported by the client before the gateway fails the run.
pub const MAX_POLICY_VIOLATIONS: u32 = 3;
/// The gateway's own tool: a call to it is an `input_required` Step (§4.3).
pub const ASK_USER_TOOL = "AskUser";
const ASK_USER_DESCRIPTION = "Ask the person running this Skill one question that only they can answer (a choice, a value, a confirmation of intent). Returns their answer as text. Prefer finishing with what you have over asking; never ask for secrets, use credential placeholders instead.";
const ASK_USER_SCHEMA_JSON =
    \\{"type":"object","properties":{"message":{"type":"string","description":"The question, in the user's language, with the context they need to answer it."},"schema":{"type":"object","description":"Optional elicitation form: a JSON Schema object whose single property may carry an enum of the choices."}},"required":["message"],"additionalProperties":false}
;

pub const Error = error{
    OutOfMemory,
    SkillsDirUnreadable,
    InvalidPackage,
};

/// One published Skill: its manifest as served, and the body that becomes
/// the model's system prompt. The body never leaves this struct.
pub const Package = struct {
    name: []const u8,
    body: []const u8,
    entry_json: []const u8,
    entry: protocol.Entry,
};

pub const Options = struct {
    operator_id: []const u8 = DEFAULT_OPERATOR,
    /// Shared bearer token every client must present; "" accepts any caller
    /// (loopback development only).
    token: []const u8 = "",
    /// Process key for `run_state`; random when null.
    state_key: ?[32]u8 = null,
    currency: []const u8 = "USD",
};

pub const Gateway = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    provider: provider_mod.Provider,
    packages: []const Package,
    operator_id: []const u8,
    token: []const u8,
    currency: []const u8,
    state_key: [32]u8,
    /// Model calls are serialized: provider implementations own transport
    /// state that is not shared across threads.
    model_mutex: psync.Mutex = .{},
    next_run: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    pub fn init(allocator: std.mem.Allocator, provider: provider_mod.Provider, skills_dir: []const u8, options: Options) Error!*Gateway {
        const self = allocator.create(Gateway) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .provider = provider,
            .packages = &.{},
            .operator_id = "",
            .token = "",
            .currency = "",
            .state_key = undefined,
        };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.operator_id = arena.dupe(u8, options.operator_id) catch return error.OutOfMemory;
        self.token = arena.dupe(u8, options.token) catch return error.OutOfMemory;
        self.currency = arena.dupe(u8, options.currency) catch return error.OutOfMemory;
        if (options.state_key) |key| self.state_key = key else try fillRandom(&self.state_key);
        self.packages = try loadPackages(arena, skills_dir);
        return self;
    }

    pub fn deinit(self: *Gateway) void {
        self.arena.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn findPackage(self: *const Gateway, skill_id: []const u8) ?*const Package {
        for (self.packages) |*package| if (std.mem.eql(u8, package.entry.skill_id, skill_id)) return package;
        return null;
    }

    /// Whether `authorization` (the raw header value, or null) admits a caller.
    pub fn authorized(self: *const Gateway, authorization: ?[]const u8) bool {
        if (self.token.len == 0) return true;
        const header = authorization orelse return false;
        const prefix = "Bearer ";
        if (!std.ascii.startsWithIgnoreCase(header, prefix)) return false;
        const presented = std.mem.trim(u8, header[prefix.len..], " ");
        if (presented.len != self.token.len) return false;
        var diff: u8 = 0;
        for (presented, self.token) |lhs, rhs| diff |= lhs ^ rhs;
        return diff == 0;
    }

    /// Handle one JSON-RPC request body; the response document is owned by
    /// the caller. Transport-level problems (bad JSON) become JSON-RPC errors
    /// with a null id, never a crash.
    pub fn handle(self: *Gateway, allocator: std.mem.Allocator, body: []const u8) ![]u8 {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const request = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
            return rpcError(allocator, null, -32700, "parse error", null, null);
        };
        if (request != .object) return rpcError(allocator, null, -32600, "invalid request", null, null);
        const id = request.object.get("id");
        const method_value = request.object.get("method") orelse return rpcError(allocator, id, -32600, "invalid request", null, null);
        if (method_value != .string) return rpcError(allocator, id, -32600, "invalid request", null, null);
        const params = request.object.get("params") orelse std.json.Value{ .object = .{} };
        const method = method_value.string;
        const result: []const u8 = blk: {
            if (std.mem.eql(u8, method, protocol.Method.discover.wire())) break :blk try self.discover(arena);
            if (std.mem.eql(u8, method, protocol.Method.skills_list.wire())) break :blk try self.skillsList(arena);
            if (std.mem.eql(u8, method, protocol.Method.skills_get.wire())) break :blk self.skillsGet(arena, params) catch |err| return self.rpcFailure(allocator, id, err);
            if (std.mem.eql(u8, method, protocol.Method.runs_start.wire())) break :blk self.runsStart(arena, params) catch |err| return self.rpcFailure(allocator, id, err);
            if (std.mem.eql(u8, method, protocol.Method.runs_continue.wire())) break :blk self.runsContinue(arena, params) catch |err| return self.rpcFailure(allocator, id, err);
            if (std.mem.eql(u8, method, protocol.Method.runs_cancel.wire())) break :blk self.runsCancel(arena, params) catch |err| return self.rpcFailure(allocator, id, err);
            return rpcError(allocator, id, -32601, "method not found", null, null);
        };
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeId(&out.writer, id);
        try out.writer.writeAll(",\"result\":");
        try out.writer.writeAll(result);
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }

    const MethodError = error{
        OutOfMemory,
        InvalidParams,
        SkillNotFound,
        ManifestChanged,
        RunStateInvalid,
        UpstreamUnavailable,
    };

    fn rpcFailure(self: *Gateway, allocator: std.mem.Allocator, id: ?std.json.Value, err: MethodError) ![]u8 {
        _ = self;
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidParams => rpcError(allocator, id, -32602, "invalid params", null, null),
            error.SkillNotFound => rpcError(allocator, id, @intFromEnum(protocol.ErrorCode.skill_not_found), "unknown skill", .skill_not_found, null),
            error.ManifestChanged => rpcError(allocator, id, @intFromEnum(protocol.ErrorCode.manifest_changed), "pinned manifest is not current", .manifest_changed, null),
            error.RunStateInvalid => rpcError(allocator, id, @intFromEnum(protocol.ErrorCode.run_state_invalid), "run state rejected", .run_state_invalid, null),
            error.UpstreamUnavailable => rpcError(allocator, id, @intFromEnum(protocol.ErrorCode.upstream_unavailable), "model provider failed", .upstream_unavailable, null),
        };
    }

    // ── Methods ───────────────────────────────────────────────────────────

    fn discover(self: *Gateway, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.writeAll("{\"protocol\":\"" ++ protocol.PROTOCOL_ID ++ "\",\"revisions\":[\"" ++ protocol.REVISION ++ "\"],\"operator\":{\"id\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll(",\"display_name\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll("},\"identities\":{\"skill_host\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll(",\"inference_gateway\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll(",\"sealing_issuer\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll(",\"billing\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll("},\"capabilities\":{\"run_state\":\"opaque\",\"step_signature\":false,\"input_required\":true,\"prefetch\":false,\"client_sealed\":false,\"currencies\":[");
        try protocol.writeString(w, self.currency);
        try w.writeAll("]}}");
        return out.written();
    }

    fn skillsList(self: *Gateway, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.writeAll("{\"skills\":[");
        for (self.packages, 0..) |package, index| {
            if (index != 0) try w.writeByte(',');
            try w.writeAll(package.entry_json);
        }
        try w.writeAll("]}");
        return out.written();
    }

    fn skillsGet(self: *Gateway, arena: std.mem.Allocator, params: std.json.Value) MethodError![]const u8 {
        _ = arena;
        const skill_id = paramString(params, "skill_id") orelse return error.InvalidParams;
        const package = self.findPackage(skill_id) orelse return error.SkillNotFound;
        return package.entry_json;
    }

    fn runsStart(self: *Gateway, arena: std.mem.Allocator, params: std.json.Value) MethodError![]const u8 {
        const skill_id = paramString(params, "skill_id") orelse return error.InvalidParams;
        const digest = paramString(params, "manifest_digest") orelse return error.InvalidParams;
        const prompt = paramString(params, "prompt") orelse return error.InvalidParams;
        const package = self.findPackage(skill_id) orelse return error.SkillNotFound;
        if (!std.mem.eql(u8, digest, package.entry.manifest_digest)) return error.ManifestChanged;
        if (params != .object) return error.InvalidParams;
        const tools_value = params.object.get("tools") orelse std.json.Value{ .array = std.json.Array.init(arena) };
        if (tools_value != .array) return error.InvalidParams;
        var max_cost: i64 = 0;
        var max_steps: u64 = protocol_default_max_steps;
        if (params.object.get("budget")) |budget| {
            if (budget != .object) return error.InvalidParams;
            if (budget.object.get("max_cost_micros")) |v| {
                if (v != .integer or v.integer < 0) return error.InvalidParams;
                max_cost = v.integer;
            }
            if (budget.object.get("max_steps")) |v| {
                if (v != .integer or v.integer <= 0) return error.InvalidParams;
                max_steps = @intCast(v.integer);
            }
        }
        var confirm_all = false;
        if (params.object.get("confirmation")) |c| {
            if (c != .string) return error.InvalidParams;
            confirm_all = std.mem.eql(u8, c.string, "always");
        }
        const run_number = self.next_run.fetchAdd(1, .monotonic);
        var nonce: [8]u8 = undefined;
        fillRandom(&nonce) catch return error.OutOfMemory;
        const run_id = std.fmt.allocPrint(arena, "run_{d}_{s}", .{ run_number, std.fmt.bytesToHex(nonce, .lower) }) catch return error.OutOfMemory;

        var state = RunState{
            .run_id = run_id,
            .skill_id = skill_id,
            .seq = 0,
            .last_digest = protocol.GENESIS_DIGEST,
            .max_cost_micros = max_cost,
            .max_steps = max_steps,
            .confirm_all = confirm_all,
            .tools = tools_value,
            .messages = std.json.Array.init(arena),
            .pending = &.{},
        };
        var text_block = std.json.ObjectMap{};
        text_block.put(arena, "type", .{ .string = "text" }) catch return error.OutOfMemory;
        text_block.put(arena, "text", .{ .string = prompt }) catch return error.OutOfMemory;
        try appendMessage(arena, &state, "user", &.{.{ .object = text_block }});
        return self.advance(arena, package, &state);
    }

    fn runsContinue(self: *Gateway, arena: std.mem.Allocator, params: std.json.Value) MethodError![]const u8 {
        const run_id = paramString(params, "run_id") orelse return error.InvalidParams;
        const blob = paramString(params, "run_state") orelse return error.InvalidParams;
        if (params != .object) return error.InvalidParams;
        const seq_value = params.object.get("seq") orelse return error.InvalidParams;
        if (seq_value != .integer or seq_value.integer <= 0) return error.InvalidParams;
        const results = params.object.get("results") orelse return error.InvalidParams;
        if (results != .array) return error.InvalidParams;

        var state = try self.openState(arena, blob, run_id);
        if (!std.mem.eql(u8, state.run_id, run_id)) return error.RunStateInvalid;
        if (@as(u64, @intCast(seq_value.integer)) != state.seq) return error.RunStateInvalid;
        if (state.pending.len == 0) return error.RunStateInvalid;
        const package = self.findPackage(state.skill_id) orelse return error.SkillNotFound;

        // One result per pending call or question, matched by id. A call the
        // model issued beside a question was never sent (§4.3: a Step is one
        // kind); it is answered here so the conversation stays well-formed.
        var blocks: std.ArrayList(std.json.Value) = .empty;
        var matched: usize = 0;
        for (state.pending) |pending| {
            var content: []const u8 = skippedResultText(pending.kind);
            var is_error = true;
            if (pending.kind == .call or pending.kind == .question) {
                const result = findResult(results.array.items, pending.id) orelse return error.RunStateInvalid;
                matched += 1;
                content = valueString(result, "content") orelse "";
                is_error = valueBool(result, "is_error") orelse false;
                if (valueString(result, "refusal")) |refusal| {
                    if (std.mem.eql(u8, refusal, "policy_violation")) state.violations += 1;
                }
            }
            var block = std.json.ObjectMap{};
            block.put(arena, "type", .{ .string = "tool_result" }) catch return error.OutOfMemory;
            block.put(arena, "tool_use_id", .{ .string = pending.id }) catch return error.OutOfMemory;
            block.put(arena, "content", .{ .string = content }) catch return error.OutOfMemory;
            block.put(arena, "is_error", .{ .bool = is_error }) catch return error.OutOfMemory;
            blocks.append(arena, .{ .object = block }) catch return error.OutOfMemory;
        }
        if (matched != results.array.items.len) return error.RunStateInvalid;
        try appendMessage(arena, &state, "user", blocks.items);
        state.pending = &.{};
        if (state.violations >= MAX_POLICY_VIOLATIONS) {
            return self.finishRun(arena, &state, "policy_violation", "the client refused calls outside the pinned allowlist");
        }
        return self.advance(arena, package, &state);
    }

    fn runsCancel(self: *Gateway, arena: std.mem.Allocator, params: std.json.Value) MethodError![]const u8 {
        const run_id = paramString(params, "run_id") orelse return error.InvalidParams;
        const blob = paramString(params, "run_state") orelse return error.InvalidParams;
        var state = try self.openState(arena, blob, run_id);
        if (!std.mem.eql(u8, state.run_id, run_id)) return error.RunStateInvalid;
        return self.finishRun(arena, &state, "cancelled", "cancelled by the client");
    }

    // ── Run state ─────────────────────────────────────────────────────────

    /// What a pending id waits for: a client result (`call`, `question`), or
    /// nothing — the gateway answers it itself on continue (`skipped`: a call
    /// issued beside a question; `invalid_ask`: an `AskUser` without a message).
    const PendingKind = enum { call, question, skipped, invalid_ask };
    const Pending = struct { id: []const u8, name: []const u8, kind: PendingKind = .call };

    fn skippedResultText(kind: PendingKind) []const u8 {
        return switch (kind) {
            .call, .question => "",
            .skipped => "not executed: the Skill asked the user in the same turn; call it again now that the answer is in",
            .invalid_ask => "AskUser needs a non-empty string `message`; nothing was asked",
        };
    }

    const RunState = struct {
        run_id: []const u8,
        skill_id: []const u8,
        seq: u64,
        last_digest: []const u8,
        max_cost_micros: i64,
        max_steps: u64,
        confirm_all: bool,
        cost_micros: i64 = 0,
        input_tokens: u64 = 0,
        output_tokens: u64 = 0,
        violations: u32 = 0,
        tools: std.json.Value,
        messages: std.json.Array,
        pending: []const Pending,
    };

    fn appendMessage(arena: std.mem.Allocator, state: *RunState, role: []const u8, blocks: []const std.json.Value) MethodError!void {
        var message = std.json.ObjectMap{};
        message.put(arena, "role", .{ .string = role }) catch return error.OutOfMemory;
        var content = std.json.Array.init(arena);
        content.appendSlice(blocks) catch return error.OutOfMemory;
        message.put(arena, "content", .{ .array = content }) catch return error.OutOfMemory;
        state.messages.append(.{ .object = message }) catch return error.OutOfMemory;
    }

    /// Serialize, seal and encode a run state (§4.4).
    fn sealState(self: *Gateway, arena: std.mem.Allocator, state: *const RunState) MethodError![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.writeAll("{\"v\":1,\"run_id\":") catch return error.OutOfMemory;
        protocol.writeString(w, state.run_id) catch return error.OutOfMemory;
        w.writeAll(",\"skill_id\":") catch return error.OutOfMemory;
        protocol.writeString(w, state.skill_id) catch return error.OutOfMemory;
        w.print(",\"seq\":{d},\"last_digest\":", .{state.seq}) catch return error.OutOfMemory;
        protocol.writeString(w, state.last_digest) catch return error.OutOfMemory;
        w.print(",\"max_cost_micros\":{d},\"max_steps\":{d},\"confirm_all\":{},\"cost_micros\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"violations\":{d},\"tools\":", .{
            state.max_cost_micros, state.max_steps, state.confirm_all, state.cost_micros, state.input_tokens, state.output_tokens, state.violations,
        }) catch return error.OutOfMemory;
        std.json.Stringify.value(state.tools, .{}, w) catch return error.OutOfMemory;
        w.writeAll(",\"messages\":") catch return error.OutOfMemory;
        std.json.Stringify.value(std.json.Value{ .array = state.messages }, .{}, w) catch return error.OutOfMemory;
        w.writeAll(",\"pending\":[") catch return error.OutOfMemory;
        for (state.pending, 0..) |pending, index| {
            if (index != 0) w.writeByte(',') catch return error.OutOfMemory;
            w.writeAll("{\"id\":") catch return error.OutOfMemory;
            protocol.writeString(w, pending.id) catch return error.OutOfMemory;
            w.writeAll(",\"name\":") catch return error.OutOfMemory;
            protocol.writeString(w, pending.name) catch return error.OutOfMemory;
            w.print(",\"kind\":\"{s}\"}}", .{@tagName(pending.kind)}) catch return error.OutOfMemory;
        }
        w.writeAll("]}") catch return error.OutOfMemory;
        const plain = out.written();
        if (plain.len > MAX_STATE_BYTES) return error.RunStateInvalid;

        const raw = arena.alloc(u8, Aead.nonce_length + plain.len + Aead.tag_length) catch return error.OutOfMemory;
        const nonce = raw[0..Aead.nonce_length];
        fillRandom(nonce) catch return error.RunStateInvalid;
        const ciphertext = raw[Aead.nonce_length .. Aead.nonce_length + plain.len];
        const tag = raw[Aead.nonce_length + plain.len ..][0..Aead.tag_length];
        Aead.encrypt(ciphertext, tag, plain, state.run_id, nonce.*, self.state_key);
        const encoded = arena.alloc(u8, Base64.Encoder.calcSize(raw.len)) catch return error.OutOfMemory;
        return Base64.Encoder.encode(encoded, raw);
    }

    /// Decode, authenticate and parse a run state. The run id the request
    /// claims is the AEAD's associated data, so a blob presented under another
    /// run's id fails authentication rather than being parsed.
    fn openState(self: *Gateway, arena: std.mem.Allocator, blob: []const u8, claimed_run_id: []const u8) MethodError!RunState {
        const raw_len = Base64.Decoder.calcSizeForSlice(blob) catch return error.RunStateInvalid;
        if (raw_len < Aead.nonce_length + Aead.tag_length) return error.RunStateInvalid;
        const raw = arena.alloc(u8, raw_len) catch return error.OutOfMemory;
        Base64.Decoder.decode(raw, blob) catch return error.RunStateInvalid;
        const nonce = raw[0..Aead.nonce_length];
        const plain_len = raw_len - Aead.nonce_length - Aead.tag_length;
        const ciphertext = raw[Aead.nonce_length .. Aead.nonce_length + plain_len];
        const tag = raw[Aead.nonce_length + plain_len ..][0..Aead.tag_length];
        const plain = arena.alloc(u8, plain_len) catch return error.OutOfMemory;
        Aead.decrypt(plain, ciphertext, tag.*, claimed_run_id, nonce.*, self.state_key) catch return error.RunStateInvalid;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, plain, .{}) catch return error.RunStateInvalid;
        if (parsed != .object) return error.RunStateInvalid;
        const messages_value = parsed.object.get("messages") orelse return error.RunStateInvalid;
        if (messages_value != .array) return error.RunStateInvalid;
        const pending_value = parsed.object.get("pending") orelse return error.RunStateInvalid;
        if (pending_value != .array) return error.RunStateInvalid;
        const pending = arena.alloc(Pending, pending_value.array.items.len) catch return error.OutOfMemory;
        for (pending_value.array.items, pending) |item, *slot| {
            const kind_text = valueString(item, "kind") orelse "call";
            slot.* = .{
                .id = valueString(item, "id") orelse return error.RunStateInvalid,
                .name = valueString(item, "name") orelse return error.RunStateInvalid,
                .kind = std.meta.stringToEnum(PendingKind, kind_text) orelse return error.RunStateInvalid,
            };
        }
        return .{
            .run_id = valueString(parsed, "run_id") orelse return error.RunStateInvalid,
            .skill_id = valueString(parsed, "skill_id") orelse return error.RunStateInvalid,
            .seq = valueUnsigned(parsed, "seq") orelse return error.RunStateInvalid,
            .last_digest = valueString(parsed, "last_digest") orelse return error.RunStateInvalid,
            .max_cost_micros = valueInteger(parsed, "max_cost_micros") orelse 0,
            .max_steps = valueUnsigned(parsed, "max_steps") orelse protocol_default_max_steps,
            .confirm_all = valueBool(parsed, "confirm_all") orelse false,
            .cost_micros = valueInteger(parsed, "cost_micros") orelse 0,
            .input_tokens = valueUnsigned(parsed, "input_tokens") orelse 0,
            .output_tokens = valueUnsigned(parsed, "output_tokens") orelse 0,
            .violations = @intCast(valueUnsigned(parsed, "violations") orelse 0),
            .tools = parsed.object.get("tools") orelse std.json.Value{ .array = std.json.Array.init(arena) },
            .messages = messages_value.array,
            .pending = pending,
        };
    }

    // ── Steps ─────────────────────────────────────────────────────────────

    /// One model call: append the assistant turn to the state and return the
    /// Step that carries its tool calls, or the final text.
    fn advance(self: *Gateway, arena: std.mem.Allocator, package: *const Package, state: *RunState) MethodError![]const u8 {
        if (state.seq + 1 > state.max_steps) return self.finishRun(arena, state, "max_steps", "step limit reached");
        const messages = try apiMessages(arena, state.messages.items);
        const tools = try toolDefinitions(arena, state.tools);
        const system = try systemPrompt(arena, package);

        var text: std.ArrayList(u8) = .empty;
        var calls: std.ArrayList(protocol.Call) = .empty;
        // `AskUser` calls never reach the client as calls: the first valid one
        // is the Step's question, the rest are answered by the gateway.
        var asks: std.ArrayList(Pending) = .empty;
        var question: ?protocol.Question = null;
        var usage: api_stream.UsageDelta = .{};
        var stop: api_stream.StopReason = .unknown;
        {
            self.model_mutex.lock();
            defer self.model_mutex.unlock();
            const stream = self.provider.sendStream(messages, system, tools, null, null, null, "") catch |err| {
                log.warn("sealed-gw", "model call failed: {s}", .{@errorName(err)});
                return error.UpstreamUnavailable;
            };
            defer stream.deinit();
            while (stream.next() catch |err| {
                log.warn("sealed-gw", "model stream failed: {s}", .{@errorName(err)});
                return error.UpstreamUnavailable;
            }) |event| switch (event) {
                .text => |chunk| {
                    defer self.allocator.free(chunk);
                    text.appendSlice(arena, chunk) catch return error.OutOfMemory;
                },
                .thinking => |chunk| self.allocator.free(chunk),
                .reasoning_item => |chunk| self.allocator.free(chunk),
                .web_search_query => |chunk| self.allocator.free(chunk),
                .tool_use_start => |call| {
                    defer {
                        self.allocator.free(call.id);
                        self.allocator.free(call.name);
                        self.allocator.free(call.input_json);
                    }
                    const confirm = state.confirm_all or listContains(package.entry.manifest.confirmation_required_for, call.name);
                    const input_json = arena.dupe(u8, call.input_json) catch return error.OutOfMemory;
                    const id = arena.dupe(u8, call.id) catch return error.OutOfMemory;
                    if (std.mem.eql(u8, call.name, ASK_USER_TOOL)) {
                        const parsed_question: ?protocol.Question = questionFromInput(arena, id, input_json) catch null;
                        var kind: PendingKind = .skipped;
                        if (parsed_question) |q| {
                            if (question == null) {
                                question = q;
                                kind = .question;
                            }
                        } else kind = .invalid_ask;
                        asks.append(arena, .{ .id = id, .name = ASK_USER_TOOL, .kind = kind }) catch return error.OutOfMemory;
                        // The assistant turn still records the call (below).
                        calls.append(arena, .{ .id = id, .name = ASK_USER_TOOL, .input_json = input_json }) catch return error.OutOfMemory;
                        continue;
                    }
                    calls.append(arena, .{
                        .id = id,
                        .name = arena.dupe(u8, call.name) catch return error.OutOfMemory,
                        .input_json = input_json,
                        .confirm = confirm,
                        .deadline_ms = 300_000,
                        .credentials = try declaredCredentialRefs(arena, package, input_json),
                        .result_limit_bytes = package.entry.manifest.egress_max_result_bytes,
                    }) catch return error.OutOfMemory;
                },
                .usage => |delta| {
                    usage.input_tokens += delta.input_tokens;
                    usage.output_tokens += delta.output_tokens;
                    usage.cache_read_input_tokens += delta.cache_read_input_tokens;
                    usage.cache_creation_input_tokens += delta.cache_creation_input_tokens;
                },
                .web_search_result => {},
                .done => {},
            };
            stop = stream.stopReason();
        }
        const rates = pricing.rateFor(self.provider.model());
        const cost_usd = pricing.computeCost(rates, usage.input_tokens, usage.output_tokens, usage.cache_read_input_tokens, usage.cache_creation_input_tokens);
        const step_cost: i64 = @intFromFloat(@round(cost_usd * 1_000_000.0));
        state.cost_micros += step_cost;
        state.input_tokens += usage.input_tokens;
        state.output_tokens += usage.output_tokens;
        state.seq += 1;

        // The assistant turn enters the conversation whatever happens next.
        var blocks: std.ArrayList(std.json.Value) = .empty;
        if (text.items.len != 0) {
            var block = std.json.ObjectMap{};
            block.put(arena, "type", .{ .string = "text" }) catch return error.OutOfMemory;
            block.put(arena, "text", .{ .string = text.items }) catch return error.OutOfMemory;
            blocks.append(arena, .{ .object = block }) catch return error.OutOfMemory;
        }
        for (calls.items) |call| {
            var block = std.json.ObjectMap{};
            block.put(arena, "type", .{ .string = "tool_use" }) catch return error.OutOfMemory;
            block.put(arena, "id", .{ .string = call.id }) catch return error.OutOfMemory;
            block.put(arena, "name", .{ .string = call.name }) catch return error.OutOfMemory;
            block.put(arena, "input", .{ .string = call.input_json }) catch return error.OutOfMemory;
            blocks.append(arena, .{ .object = block }) catch return error.OutOfMemory;
        }
        if (blocks.items.len != 0) try appendMessage(arena, state, "assistant", blocks.items);

        const step_usage: protocol.Usage = .{
            .model = self.provider.model(),
            .input_tokens = usage.input_tokens,
            .output_tokens = usage.output_tokens,
            .cache_read_input_tokens = usage.cache_read_input_tokens,
            .cache_creation_input_tokens = usage.cache_creation_input_tokens,
            .cost_micros = step_cost,
            .currency = self.currency,
        };
        if (state.max_cost_micros > 0 and state.cost_micros > state.max_cost_micros) {
            return self.emitStep(arena, state, .{ .kind = .failed, .reason = "budget_exceeded", .message = "the run's cost cap was reached", .usage = step_usage });
        }
        if (calls.items.len != 0 and stop != .end_turn) {
            const pending = arena.alloc(Pending, calls.items.len) catch return error.OutOfMemory;
            var client_calls: std.ArrayList(protocol.Call) = .empty;
            for (calls.items, pending) |call, *slot| {
                const ask = findPending(asks.items, call.id);
                slot.* = if (ask) |a|
                    a
                else if (question != null)
                    // §4.3: an `input_required` Step carries the question
                    // alone; a sibling call waits for the next turn.
                    .{ .id = call.id, .name = call.name, .kind = .skipped }
                else blk: {
                    client_calls.append(arena, call) catch return error.OutOfMemory;
                    break :blk .{ .id = call.id, .name = call.name, .kind = .call };
                };
            }
            state.pending = pending;
            if (question) |q| {
                return self.emitStep(arena, state, .{ .kind = .input_required, .question = q, .text = text.items, .usage = step_usage });
            }
            if (client_calls.items.len != 0) {
                return self.emitStep(arena, state, .{ .kind = .tool_calls, .calls = client_calls.items, .text = text.items, .usage = step_usage });
            }
            // Only malformed `AskUser` calls: nothing for the client. Answer
            // them here and let the model try again (bounded by max_steps).
            var blocks_now: std.ArrayList(std.json.Value) = .empty;
            for (pending) |p| {
                var block = std.json.ObjectMap{};
                block.put(arena, "type", .{ .string = "tool_result" }) catch return error.OutOfMemory;
                block.put(arena, "tool_use_id", .{ .string = p.id }) catch return error.OutOfMemory;
                block.put(arena, "content", .{ .string = skippedResultText(p.kind) }) catch return error.OutOfMemory;
                block.put(arena, "is_error", .{ .bool = true }) catch return error.OutOfMemory;
                blocks_now.append(arena, .{ .object = block }) catch return error.OutOfMemory;
            }
            try appendMessage(arena, state, "user", blocks_now.items);
            state.pending = &.{};
            // No Step left the gateway for this model call, so it is not a
            // sequence number: the retry is the same client-visible Step. Its
            // cost is already in the cumulative totals.
            state.seq -= 1;
            return self.advance(arena, package, state);
        }
        if (stop == .max_tokens or stop == .refusal) {
            return self.emitStep(arena, state, .{ .kind = .failed, .reason = "skill_error", .message = @tagName(stop), .usage = step_usage });
        }
        return self.emitStep(arena, state, .{ .kind = .final, .text = text.items, .usage = step_usage });
    }

    fn finishRun(self: *Gateway, arena: std.mem.Allocator, state: *RunState, reason: []const u8, message: []const u8) MethodError![]const u8 {
        state.seq += 1;
        state.pending = &.{};
        return self.emitStep(arena, state, .{ .kind = .failed, .reason = reason, .message = message, .usage = .{ .currency = self.currency } });
    }

    const Emit = struct {
        kind: protocol.StepKind,
        calls: []const protocol.Call = &.{},
        question: ?protocol.Question = null,
        text: []const u8 = "",
        reason: []const u8 = "",
        message: []const u8 = "",
        usage: protocol.Usage,
    };

    /// Render a Step: digest first (over everything but `run_state`, `digest`
    /// and `sig`), then seal the state with that digest as its chain head, and
    /// only then attach both.
    fn emitStep(self: *Gateway, arena: std.mem.Allocator, state: *RunState, emit: Emit) MethodError![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        writeStepBody(w, self, state, emit) catch return error.OutOfMemory;
        var value = std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{}) catch return error.OutOfMemory;
        const digest = protocol.stepDigest(arena, value) catch return error.OutOfMemory;
        state.last_digest = digest;
        value.object.put(arena, "digest", .{ .string = digest }) catch return error.OutOfMemory;
        if (emit.kind == .tool_calls or emit.kind == .input_required) {
            const blob = try self.sealState(arena, state);
            value.object.put(arena, "run_state", .{ .string = blob }) catch return error.OutOfMemory;
        }
        return protocol.serializeValue(arena, value) catch return error.OutOfMemory;
    }

    fn writeStepBody(w: *std.Io.Writer, self: *Gateway, state: *const RunState, emit: Emit) !void {
        try w.writeAll("{\"run_id\":");
        try protocol.writeString(w, state.run_id);
        try w.print(",\"seq\":{d},\"kind\":\"{s}\"", .{ state.seq, @tagName(emit.kind) });
        if (emit.kind == .tool_calls) {
            try w.writeAll(",\"calls\":[");
            for (emit.calls, 0..) |call, index| {
                if (index != 0) try w.writeByte(',');
                try w.writeAll("{\"id\":");
                try protocol.writeString(w, call.id);
                try w.writeAll(",\"name\":");
                try protocol.writeString(w, call.name);
                try w.writeAll(",\"input\":");
                try w.writeAll(call.input_json);
                try w.print(",\"confirm\":{},\"deadline_ms\":{d},\"credentials\":[", .{ call.confirm, call.deadline_ms orelse 0 });
                for (call.credentials, 0..) |ref, ref_index| {
                    if (ref_index != 0) try w.writeByte(',');
                    try protocol.writeString(w, ref);
                }
                try w.print("],\"result_limit_bytes\":{d}}}", .{call.result_limit_bytes orelse protocol.DEFAULT_MAX_RESULT_BYTES});
            }
            try w.writeByte(']');
        }
        if (emit.kind == .input_required) {
            const q = emit.question orelse return error.InvalidParams;
            try w.writeAll(",\"question\":{\"id\":");
            try protocol.writeString(w, q.id);
            try w.writeAll(",\"message\":");
            try protocol.writeString(w, q.message);
            if (q.schema_json.len != 0) {
                try w.writeAll(",\"schema\":");
                try w.writeAll(q.schema_json);
            }
            try w.writeByte('}');
        }
        if (emit.text.len != 0) {
            try w.writeAll(",\"text\":");
            try protocol.writeString(w, emit.text);
        }
        if (emit.kind == .failed) {
            try w.writeAll(",\"reason\":");
            try protocol.writeString(w, emit.reason);
            try w.writeAll(",\"message\":");
            try protocol.writeString(w, emit.message);
        }
        try w.writeAll(",\"usage\":{\"model\":");
        try protocol.writeString(w, emit.usage.model);
        try w.print(",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_input_tokens\":{d},\"cache_creation_input_tokens\":{d},\"cost_micros\":{d},\"currency\":", .{
            emit.usage.input_tokens, emit.usage.output_tokens, emit.usage.cache_read_input_tokens, emit.usage.cache_creation_input_tokens, emit.usage.cost_micros,
        });
        try protocol.writeString(w, self.currency);
        try w.print("}},\"cumulative\":{{\"steps\":{d},\"cost_micros\":{d},\"currency\":", .{ state.seq, state.cost_micros });
        try protocol.writeString(w, self.currency);
        try w.print(",\"input_tokens\":{d},\"output_tokens\":{d}}},\"issuer\":{{\"skill_host\":", .{ state.input_tokens, state.output_tokens });
        try protocol.writeString(w, self.operator_id);
        try w.writeAll(",\"inference_gateway\":");
        try protocol.writeString(w, self.operator_id);
        try w.writeAll("},\"prev_digest\":");
        try protocol.writeString(w, state.last_digest);
        if (emit.kind == .final or emit.kind == .failed) {
            try w.writeAll(",\"charge\":{\"run_id\":");
            try protocol.writeString(w, state.run_id);
            try w.print(",\"cost_micros\":{d},\"currency\":", .{state.cost_micros});
            try protocol.writeString(w, self.currency);
            try w.print(",\"steps\":{d},\"issued_at\":\"\",\"digest\":\"\"}}", .{state.seq});
        }
        try w.writeByte('}');
    }
};

const protocol_default_max_steps: u64 = 200;

/// The system prompt of a run: the Skill body, then what the model needs to
/// know about this gateway's own affordances (credential placeholders for the
/// declared references, and `AskUser`). Never anything per client or per run,
/// so the provider's prompt cache is not broken between Steps.
fn systemPrompt(arena: std.mem.Allocator, package: *const Package) Gateway.MethodError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, package.body) catch return error.OutOfMemory;
    const manifest = &package.entry.manifest;
    if (manifest.credentials.len != 0) {
        out.appendSlice(arena, "\n\n## Credentials\n\nThe user has bound these credential references on their machine. Write the placeholder literally wherever a tool input needs the value; the client substitutes it before executing and redacts it from the result. You never see the value and must not ask for it.\n") catch return error.OutOfMemory;
        for (manifest.credentials) |credential| {
            out.print(arena, "- `{s}{s}{s}`", .{ credentials.PLACEHOLDER_PREFIX, credential.ref, credentials.PLACEHOLDER_SUFFIX }) catch return error.OutOfMemory;
            if (credential.purpose.len != 0) out.print(arena, " — {s}", .{credential.purpose}) catch return error.OutOfMemory;
            out.append(arena, '\n') catch return error.OutOfMemory;
        }
    }
    out.appendSlice(arena, "\n\n## Asking the user\n\nWhen only the person running this Skill can supply what you need, call `" ++ ASK_USER_TOOL ++ "` with one clear question; the answer comes back as the tool result.\n") catch return error.OutOfMemory;
    return out.items;
}

/// The gateway's `AskUser` definition (§4.3), appended to the client's tools.
fn askUserDefinition(arena: std.mem.Allocator) Gateway.MethodError!json_mod.ToolDefinition {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, ASK_USER_SCHEMA_JSON, .{}) catch return error.OutOfMemory;
    var schema: json_mod.InputSchema = .{};
    schema.properties = parsed.object.get("properties").?.object;
    const required = arena.alloc([]const u8, 1) catch return error.OutOfMemory;
    required[0] = "message";
    schema.required = required;
    schema.additional_properties = false;
    return .{ .name = ASK_USER_TOOL, .description = ASK_USER_DESCRIPTION, .input_schema = schema };
}

/// An `AskUser` call's input as the Step's question: `message` is required,
/// `schema` is passed through canonicalized.
fn questionFromInput(arena: std.mem.Allocator, id: []const u8, input_json: []const u8) !protocol.Question {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, input_json, .{});
    if (parsed != .object) return error.InvalidParams;
    const message = valueString(parsed, "message") orelse return error.InvalidParams;
    if (message.len == 0) return error.InvalidParams;
    var schema_json: []const u8 = "";
    if (parsed.object.get("schema")) |schema| {
        if (schema == .object) schema_json = try protocol.canonicalize(arena, schema);
    }
    return .{ .id = id, .message = message, .schema_json = schema_json };
}

/// §6.4: the manifest-declared references whose placeholder appears in the
/// call's input, so the client knows which secrets the call needs.
fn declaredCredentialRefs(arena: std.mem.Allocator, package: *const Package, input_json: []const u8) Gateway.MethodError![]const []const u8 {
    const found = credentials.placeholderRefs(arena, input_json) catch return error.OutOfMemory;
    var declared: std.ArrayList([]const u8) = .empty;
    for (found) |ref| {
        for (package.entry.manifest.credentials) |credential| {
            if (std.mem.eql(u8, credential.ref, ref)) {
                declared.append(arena, ref) catch return error.OutOfMemory;
                break;
            }
        }
    }
    return declared.items;
}

// ── Packages ──────────────────────────────────────────────────────────────

fn loadPackages(arena: std.mem.Allocator, skills_dir: []const u8) Error![]const Package {
    const dir_z = arena.dupeZ(u8, skills_dir) catch return error.OutOfMemory;
    var iterator = pdir.open(dir_z) orelse return error.SkillsDirUnreadable;
    defer pdir.close(&iterator);
    var packages: std.ArrayList(Package) = .empty;
    while (pdir.next(&iterator)) |entry| {
        if (!entry.is_dir) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const name = arena.dupe(u8, entry.name) catch return error.OutOfMemory;
        const package_dir = std.fs.path.join(arena, &.{ skills_dir, name }) catch return error.OutOfMemory;
        const package = try loadPackage(arena, package_dir, name);
        packages.append(arena, package) catch return error.OutOfMemory;
    }
    std.mem.sort(Package, packages.items, {}, packageLessThan);
    return packages.toOwnedSlice(arena) catch return error.OutOfMemory;
}

fn packageLessThan(_: void, lhs: Package, rhs: Package) bool {
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

pub fn loadPackage(arena: std.mem.Allocator, package_dir: []const u8, name: []const u8) Error!Package {
    const md_path = std.fs.path.join(arena, &.{ package_dir, "SKILL.md" }) catch return error.OutOfMemory;
    const md = readFile(arena, md_path) catch return error.InvalidPackage;
    const skill = definition.parseSkillMdWithFallback(arena, md, md_path, name) catch return error.InvalidPackage;
    const manifest_path = std.fs.path.join(arena, &.{ package_dir, "manifest.json" }) catch return error.OutOfMemory;
    const manifest_json = readFile(arena, manifest_path) catch return error.InvalidPackage;
    const manifest_value = std.json.parseFromSliceLeaky(std.json.Value, arena, manifest_json, .{}) catch return error.InvalidPackage;
    const canonical = protocol.canonicalize(arena, manifest_value) catch return error.InvalidPackage;
    const digest = protocol.digestHex(arena, canonical) catch return error.OutOfMemory;
    const manifest = protocol.manifestFromValue(arena, manifest_value) catch return error.InvalidPackage;
    if (!std.mem.eql(u8, manifest.name, name)) return error.InvalidPackage;
    const entry_json = std.fmt.allocPrint(
        arena,
        "{{\"skill_id\":{s},\"version\":{s},\"manifest\":{s},\"manifest_digest\":\"{s}\",\"subscription\":{{\"state\":\"active\"}}}}",
        .{ quoted(arena, manifest.skill_id) catch return error.OutOfMemory, quoted(arena, manifest.version) catch return error.OutOfMemory, canonical, digest },
    ) catch return error.OutOfMemory;
    const parsed = protocol.parseEntry(arena, entry_json) catch return error.InvalidPackage;
    // The entry's arena is a child of ours; keep the parsed view alive by
    // never calling deinit (it is freed with `arena`).
    return .{
        .name = name,
        .body = std.mem.trim(u8, skill.body, " \r\n\t"),
        .entry_json = entry_json,
        .entry = parsed.entry,
    };
}

fn quoted(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try protocol.writeString(&out.writer, value);
    return out.written();
}

fn readFile(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    const z = try arena.dupeZ(u8, path);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return error.NotFound;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &chunk);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(arena, chunk[0..@intCast(n)]);
        if (out.items.len > MAX_REQUEST_BYTES) return error.TooLarge;
    }
    return out.items;
}

// ── Conversions ───────────────────────────────────────────────────────────

fn apiMessages(arena: std.mem.Allocator, messages: []const std.json.Value) Gateway.MethodError![]const types.ApiMessage {
    const out = arena.alloc(types.ApiMessage, messages.len) catch return error.OutOfMemory;
    for (messages, out) |message, *slot| {
        const role_text = valueString(message, "role") orelse return error.RunStateInvalid;
        const role: types.MessageRole = if (std.mem.eql(u8, role_text, "user")) .user else .assistant;
        const content = (if (message == .object) message.object.get("content") else null) orelse return error.RunStateInvalid;
        if (content != .array) return error.RunStateInvalid;
        const blocks = arena.alloc(types.ApiContent, content.array.items.len) catch return error.OutOfMemory;
        for (content.array.items, blocks) |block, *target| {
            const kind = valueString(block, "type") orelse return error.RunStateInvalid;
            if (std.mem.eql(u8, kind, "text")) {
                target.* = .{ .text = valueString(block, "text") orelse "" };
            } else if (std.mem.eql(u8, kind, "tool_use")) {
                target.* = .{ .tool_use = .{
                    .id = valueString(block, "id") orelse return error.RunStateInvalid,
                    .name = valueString(block, "name") orelse return error.RunStateInvalid,
                    .input = valueString(block, "input") orelse "{}",
                } };
            } else if (std.mem.eql(u8, kind, "tool_result")) {
                target.* = .{ .tool_result = .{
                    .tool_use_id = valueString(block, "tool_use_id") orelse return error.RunStateInvalid,
                    .content = valueString(block, "content") orelse "",
                    .is_error = valueBool(block, "is_error") orelse false,
                } };
            } else return error.RunStateInvalid;
        }
        slot.* = .{ .role = role, .content = blocks };
    }
    return out;
}

/// The client's tool definitions (§4.1) in the neutral request type.
fn toolDefinitions(arena: std.mem.Allocator, tools: std.json.Value) Gateway.MethodError![]const json_mod.ToolDefinition {
    if (tools != .array) return error.InvalidParams;
    const out = arena.alloc(json_mod.ToolDefinition, tools.array.items.len + 1) catch return error.OutOfMemory;
    // The gateway's own tool comes last; a client tool of the same name is
    // refused, since its call would never reach the client as a call.
    out[tools.array.items.len] = try askUserDefinition(arena);
    for (tools.array.items, out[0..tools.array.items.len]) |tool, *slot| {
        const name = valueString(tool, "name") orelse return error.InvalidParams;
        if (std.mem.eql(u8, name, ASK_USER_TOOL)) return error.InvalidParams;
        var schema: json_mod.InputSchema = .{};
        if (tool == .object) if (tool.object.get("input_schema")) |raw| {
            if (raw != .object) return error.InvalidParams;
            if (raw.object.get("properties")) |properties| {
                if (properties != .object) return error.InvalidParams;
                schema.properties = properties.object;
            }
            if (raw.object.get("required")) |required| {
                if (required != .array) return error.InvalidParams;
                const names = arena.alloc([]const u8, required.array.items.len) catch return error.OutOfMemory;
                for (required.array.items, names) |item, *target| {
                    if (item != .string) return error.InvalidParams;
                    target.* = item.string;
                }
                schema.required = names;
            }
            if (raw.object.get("additionalProperties")) |extra| {
                if (extra == .bool) schema.additional_properties = extra.bool;
            }
        };
        slot.* = .{
            .name = name,
            .description = valueString(tool, "description") orelse "",
            .input_schema = schema,
        };
    }
    return out;
}

fn findPending(list: []const Gateway.Pending, id: []const u8) ?Gateway.Pending {
    for (list) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

fn listContains(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn findResult(results: []const std.json.Value, id: []const u8) ?std.json.Value {
    for (results) |result| {
        const got = valueString(result, "tool_use_id") orelse continue;
        if (std.mem.eql(u8, got, id)) return result;
    }
    return null;
}

fn paramString(params: std.json.Value, key: []const u8) ?[]const u8 {
    return valueString(params, key);
}

fn valueString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn valueBool(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .bool) field.bool else null;
}

fn valueInteger(value: std.json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .integer) field.integer else null;
}

fn valueUnsigned(value: std.json.Value, key: []const u8) ?u64 {
    const raw = valueInteger(value, key) orelse return null;
    return if (raw >= 0) @intCast(raw) else null;
}

fn writeId(w: *std.Io.Writer, id: ?std.json.Value) !void {
    if (id) |value| {
        try std.json.Stringify.value(value, .{}, w);
    } else try w.writeAll("null");
}

fn rpcError(allocator: std.mem.Allocator, id: ?std.json.Value, code: i64, message: []const u8, known: ?protocol.ErrorCode, data_json: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try protocol.writeString(w, message);
    if (known != null or data_json != null) {
        try w.writeAll(",\"data\":{");
        var first = true;
        if (known) |k| {
            try w.writeAll("\"code\":");
            try protocol.writeString(w, k.name());
            first = false;
        }
        if (data_json) |data| {
            if (!first) try w.writeByte(',');
            try w.writeAll("\"current\":");
            try w.writeAll(data);
        }
        try w.writeByte('}');
    }
    try w.writeAll("}}");
    return out.toOwnedSlice();
}

// ── HTTP server ───────────────────────────────────────────────────────────

/// Loopback HTTP/1.1 front for a Gateway: one accept loop, requests handled
/// in order. A reverse proxy terminates TLS and fans out in production; the
/// reference server exists to run the protocol end to end.
pub const Server = struct {
    allocator: std.mem.Allocator,
    gateway: *Gateway,
    listener: net.Socket,
    port: u16,
    thread: std.Thread = undefined,
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn start(allocator: std.mem.Allocator, gateway: *Gateway, port: u16) !*Server {
        const listener = try net.listenLoopback(port, 16);
        errdefer net.closeSocket(listener.sock);
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .gateway = gateway, .listener = listener.sock, .port = listener.port };
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn stop(self: *Server) void {
        self.closing.store(true, .release);
        // Wake a blocked accept deterministically on every platform.
        if (net.connectLoopback(self.port)) |wake| net.closeSocket(wake) else |_| {}
        self.thread.join();
        net.closeSocket(self.listener);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn url(self: *const Server, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/ssp", .{self.port});
    }

    fn acceptLoop(self: *Server) void {
        while (true) {
            const conn = net.acceptConn(self.listener) orelse {
                if (self.closing.load(.acquire)) return;
                continue;
            };
            if (self.closing.load(.acquire)) {
                net.closeSocket(conn);
                return;
            }
            self.handleConn(conn);
        }
    }

    fn handleConn(self: *Server, fd: net.Socket) void {
        defer net.closeSocket(fd);
        net.setRecvTimeoutMs(fd, 30_000);
        net.setSendTimeoutMs(fd, 30_000);
        const cap = MAX_REQUEST_BYTES;
        const buf = self.allocator.alloc(u8, cap) catch return;
        defer self.allocator.free(buf);
        var total: usize = 0;
        var headers_end: ?usize = null;
        var content_length: usize = 0;
        while (total < cap and headers_end == null) {
            const n = net.recv(fd, buf[total..cap]);
            if (n <= 0) return;
            total += @intCast(n);
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |i| {
                headers_end = i + 4;
                content_length = headerUnsigned(buf[0..i], "content-length") orelse 0;
            }
        }
        const he = headers_end orelse return;
        const head = buf[0..(he - 4)];
        if (content_length > cap - he) {
            writeResponse(fd, "413 Payload Too Large", "{\"error\":\"too large\"}");
            return;
        }
        while ((total - he) < content_length) {
            const n = net.recv(fd, buf[total .. he + content_length]);
            if (n <= 0) return;
            total += @intCast(n);
        }
        const body = buf[he..total];

        const version = headerValue(head, protocol.VERSION_HEADER);
        if (version == null or !std.mem.eql(u8, std.mem.trim(u8, version.?, " "), protocol.VERSION_HEADER_VALUE)) {
            const err = rpcError(self.allocator, null, @intFromEnum(protocol.ErrorCode.unsupported_version), "Sealed-Skill-Version 1 required", .unsupported_version, null) catch return;
            defer self.allocator.free(err);
            writeResponse(fd, "400 Bad Request", err);
            return;
        }
        if (!self.gateway.authorized(headerValue(head, "authorization"))) {
            writeResponse(fd, "401 Unauthorized", "{\"error\":\"unauthorized\"}");
            return;
        }
        const response = self.gateway.handle(self.allocator, body) catch |err| {
            log.warn("sealed-gw", "request failed: {s}", .{@errorName(err)});
            writeResponse(fd, "500 Internal Server Error", "{\"error\":\"internal\"}");
            return;
        };
        defer self.allocator.free(response);
        writeResponse(fd, "200 OK", response);
    }
};

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn headerUnsigned(head: []const u8, name: []const u8) ?usize {
    const value = headerValue(head, name) orelse return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn writeResponse(fd: net.Socket, status: []const u8, body: []const u8) void {
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len }) catch return;
    if (!writeAll(fd, head)) return;
    _ = writeAll(fd, body);
}

fn writeAll(fd: net.Socket, bytes: []const u8) bool {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = net.send(fd, bytes[pos..]);
        if (n <= 0) return false;
        pos += @intCast(n);
    }
    return true;
}

const rng = @import("platform").rng;

fn fillRandom(buf: []u8) error{OutOfMemory}!void {
    // The platform RNG is the OS CSPRNG; a failure to read it is fatal for a
    // key or nonce, so it surfaces as an error instead of a predictable value.
    if (!rng.randomBytes(buf)) return error.OutOfMemory;
}
