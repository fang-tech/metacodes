//! The client side of a sealed Skill run, shaped as a model Provider
//! (doc/SEALED_SKILL_PROTOCOL.md §9 "Activation").
//!
//! A forked Skill runs the ordinary subagent loop; this Provider replaces the
//! model. Its first `sendStream` opens the run (`runs.start`) with the user's
//! prompt and the tool definitions the pin allows; every later `sendStream`
//! takes the `tool_result` blocks the loop appended and sends them
//! (`runs.continue`). Each Step comes back as neutral stream events —
//! `tool_use_start` per call, `text`, `usage`, `done` — so dispatch,
//! permission, sandbox, artifact storage and observation are untouched.
//!
//! What this module enforces on its own, because the gateway is untrusted:
//! the hash chain and `seq` of every Step (§8.3), the result size caps (§6.3),
//! the policy-violation count that cancels a run (§6.2), the cost cap (§6.5),
//! the ledger (§6.6), credential substitution and redaction (§6.4), and the
//! `confirm: true` marks handed to the child's permission context through
//! its confirm gate (§6.2). An `input_required` Step is put to the user over
//! the session's UI requester and the answer goes back as the one result of
//! the next `runs.continue` (§4.3). The tool allowlist itself is enforced by
//! the Skill's policy frame before dispatch; this module only classifies the
//! refusal.

const std = @import("std");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const pin_mod = @import("pin.zig");
const ledger = @import("ledger.zig");
const credentials = @import("credentials.zig");
const util_time = @import("../../util/time.zig");
const provider_mod = @import("../../api/provider.zig");
const api_stream = @import("../../api/stream.zig");
const api_request = @import("../../api/request.zig");
const types = @import("../../types.zig");
const json_mod = @import("../../json.zig");
const log = @import("../../util/log.zig");
const rule_spec = @import("../../permission/rule_spec.zig");
const confirm_gate = @import("../../permission/confirm_gate.zig");
const ui_request = @import("../../core/protocol/ui_request.zig");
const tool_context = @import("../../tools/context.zig");
const SessionId = @import("../../core/session_id.zig").SessionId;
const AbortSignal = @import("../../util/abort.zig").AbortSignal;

pub const DEFAULT_MAX_COST_MICROS: i64 = 500_000;
pub const DEFAULT_MAX_STEPS: u64 = 200;
/// §6.2: policy violations in one run before the client cancels it.
pub const MAX_POLICY_VIOLATIONS: u8 = 3;
/// Model name the loop sees; its price table is only ever an estimate here.
pub const MODEL_PREFIX = "sealed:";
/// Longest answer accepted for an `input_required` question.
pub const MAX_ANSWER_BYTES: usize = 64 * 1024;

pub const Error = error{
    OutOfMemory,
    /// The pinned digest is no longer current (§6.1); re-consent is needed.
    SealedManifestChanged,
    SealedUnauthorized,
    SealedSubscriptionRequired,
    /// Gateway or transport failure named in the log.
    SealedGatewayError,
    /// A Step broke the hash chain or sequence (§8.3, §8.4).
    SealedChainBroken,
    /// The loop called again after the run ended.
    SealedRunFinished,
    SealedNoPrompt,
    /// `<state root>/sealed-credentials.json` exists but cannot be read.
    SealedCredentialsUnreadable,
};

pub const Options = struct {
    /// Owned by the provider from here on.
    pin: pin_mod.ParsedPin,
    token: []const u8,
    max_cost_micros: i64 = DEFAULT_MAX_COST_MICROS,
    max_steps: u64 = DEFAULT_MAX_STEPS,
    session_id: []const u8,
    /// "" disables the ledger and the credential store (tests without a
    /// state root).
    state_root: []const u8,
    client_version: []const u8,
    client_platform: []const u8,
    locale: []const u8 = "",
    /// Where an `input_required` question is put to the user. Null means no
    /// channel: such a Step ends the run with the question as the fork's text.
    ui: ?ui_request.UiRequester = null,
    /// The session the question dialog is routed to.
    session: SessionId = .single,
};

const PreRefusal = struct {
    refusal: protocol.Refusal,
    message: []const u8,
};

const CallRef = struct {
    id: []const u8,
    name: []const u8,
    result_limit_bytes: ?u64,
    confirm: bool,
    /// Credential references the call listed and this client bound; their
    /// values are substituted on the way in and redacted on the way out.
    credential_refs: []const []const u8,
    /// Set when the call must not reach dispatch (an unbound credential):
    /// no `tool_use` is streamed and this is its result.
    pre_refusal: ?PreRefusal,
};

const Run = struct {
    run_id: []const u8,
    run_state: []const u8,
    seq: u64,
    last_digest: []const u8,
    calls: []const CallRef,
    cumulative_cost_micros: i64 = 0,
    finished: bool = false,
    violations: u8 = 0,
};

pub const SealedSkillProvider = struct {
    allocator: std.mem.Allocator,
    transport: transport.Client,
    pin: pin_mod.ParsedPin,
    credentials: credentials.Store,
    max_cost_micros: i64,
    max_steps: u64,
    session_id: []u8,
    state_root: []u8,
    client_version: []u8,
    client_platform: []u8,
    model_name: []u8,
    ui: ?ui_request.UiRequester,
    session: SessionId,
    /// Everything the current run owns; reset per Step.
    run_arena: std.heap.ArenaAllocator,
    run: ?Run = null,
    /// Notes for the user that outlive the Step they arose in (a credential
    /// the Skill needed and the user has not bound); prepended to the final
    /// text so the person running the Skill sees what to do.
    notices: std.ArrayList([]u8) = .empty,
    /// The last failure `sendStream` returned. The child loop reports a model
    /// failure as an empty run; the fork reads this to surface the real cause.
    last_error: ?anyerror = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) !*SealedSkillProvider {
        const self = try allocator.create(SealedSkillProvider);
        errdefer allocator.destroy(self);
        var pin = options.pin;
        errdefer pin.deinit();
        const model_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ MODEL_PREFIX, pin.pin.entry.skill_id });
        errdefer allocator.free(model_name);
        const session_id = try allocator.dupe(u8, options.session_id);
        errdefer allocator.free(session_id);
        const state_root = try allocator.dupe(u8, options.state_root);
        errdefer allocator.free(state_root);
        const client_version = try allocator.dupe(u8, options.client_version);
        errdefer allocator.free(client_version);
        const client_platform = try allocator.dupe(u8, options.client_platform);
        errdefer allocator.free(client_platform);
        var store = credentials.load(allocator, options.state_root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("sealed", "credential store unreadable: {s}", .{@errorName(err)});
                return error.SealedCredentialsUnreadable;
            },
        };
        errdefer store.deinit();
        const client = try transport.Client.init(allocator, io, pin.pin.gateway_url, options.token);
        self.* = .{
            .allocator = allocator,
            .transport = client,
            .pin = pin,
            .credentials = store,
            .max_cost_micros = options.max_cost_micros,
            .max_steps = options.max_steps,
            .session_id = session_id,
            .state_root = state_root,
            .client_version = client_version,
            .client_platform = client_platform,
            .model_name = model_name,
            .ui = options.ui,
            .session = options.session,
            .run_arena = std.heap.ArenaAllocator.init(allocator),
        };
        return self;
    }

    pub fn destroy(self: *SealedSkillProvider) void {
        // A run the loop abandoned (abort, error) is cancelled so the gateway
        // charges nothing further; best effort, the ledger already holds what
        // was charged up to the last Step.
        if (self.run) |run| if (!run.finished) self.cancelRun(.client_error, null);
        for (self.notices.items) |notice| self.allocator.free(notice);
        self.notices.deinit(self.allocator);
        self.run_arena.deinit();
        self.transport.deinit();
        self.credentials.deinit();
        self.pin.deinit();
        self.allocator.free(self.model_name);
        self.allocator.free(self.client_platform);
        self.allocator.free(self.client_version);
        self.allocator.free(self.state_root);
        self.allocator.free(self.session_id);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn provider(self: *SealedSkillProvider) provider_mod.Provider {
        return .{
            .ctx = @ptrCast(self),
            .modelFn = modelFn,
            .sendStreamFn = sendStreamFn,
            .sendStreamRetryFn = sendStreamRetryFn,
            .sendFn = sendFn,
            .cancelFn = cancelFn,
            .maxTokensFn = maxTokensFn,
            .maxInputTokensFn = maxInputTokensFn,
            .reasoningEffortFn = reasoningEffortFn,
            .supportsFn = supportsFn,
            .endpointIdFn = endpointIdFn,
        };
    }

    /// The gate the child's permission context consults (§6.2 `confirm`):
    /// true for a call of the current Step the gateway marked `confirm: true`.
    pub fn confirmGate(self: *SealedSkillProvider) confirm_gate.ConfirmGate {
        return .{ .ctx = @ptrCast(self), .requiresFn = &confirmRequiresFn };
    }

    fn confirmRequiresFn(ctx: *anyopaque, tool_use_id: []const u8, _: []const u8) bool {
        const self = cast(ctx);
        const run = self.run orelse return false;
        const call = findCall(run.calls, tool_use_id) orelse return false;
        return call.confirm;
    }

    pub fn manifest(self: *const SealedSkillProvider) *const protocol.Manifest {
        return &self.pin.pin.entry.manifest;
    }

    /// The cap in the loop's own unit, for its secondary estimate-based stop.
    pub fn costBudgetUsd(self: *const SealedSkillProvider) ?f64 {
        if (self.max_cost_micros <= 0) return null;
        return @as(f64, @floatFromInt(self.max_cost_micros)) / 1_000_000.0;
    }

    pub fn cumulativeCostMicros(self: *const SealedSkillProvider) i64 {
        return if (self.run) |run| run.cumulative_cost_micros else 0;
    }

    // ── Provider vtable ───────────────────────────────────────────────────

    fn cast(ctx: *anyopaque) *SealedSkillProvider {
        return @ptrCast(@alignCast(ctx));
    }

    fn modelFn(ctx: *anyopaque) []const u8 {
        return cast(ctx).model_name;
    }

    fn endpointIdFn(ctx: *anyopaque) []const u8 {
        return cast(ctx).pin.pin.gateway_url;
    }

    fn sendStreamFn(
        ctx: *anyopaque,
        messages: []const types.ApiMessage,
        _: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
        _: ?[]const u8,
        _: ?json_mod.ToolChoice,
        _: []const u8,
    ) anyerror!provider_mod.StreamHandle {
        const self = cast(ctx);
        if (self.run) |run| if (run.finished) {
            self.last_error = error.SealedRunFinished;
            return error.SealedRunFinished;
        };
        const outcome = if (self.run != null) self.continueRun(messages, abort) else self.startRun(messages, tools, abort);
        return outcome catch |err| {
            self.last_error = err;
            return err;
        };
    }

    pub fn lastError(self: *const SealedSkillProvider) ?anyerror {
        return self.last_error;
    }

    fn sendStreamRetryFn(
        ctx: *anyopaque,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?json_mod.ToolChoice,
        _: u32,
        _: u64,
        _: ?provider_mod.RetryReporter,
        user_query: []const u8,
    ) anyerror!provider_mod.StreamHandle {
        // A gateway call is not idempotent at the protocol level (§8.4: a
        // re-sent `seq` is rejected), so there is no transport retry here.
        return sendStreamFn(ctx, messages, system, tools, abort, model_override, tool_choice, user_query);
    }

    fn sendFn(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?[]const u8) anyerror!provider_mod.ApiResponse {
        // Compaction summaries would send the fork's conversation to the
        // gateway as free text; a sealed run has no such request.
        return error.SealedProviderNoSummaries;
    }

    fn cancelFn(ctx: *anyopaque, signal: *const AbortSignal) void {
        cast(ctx).transport.cancel(signal);
    }

    fn maxTokensFn(_: *anyopaque) u32 {
        return 8192;
    }

    fn maxInputTokensFn(_: *anyopaque) u32 {
        return 200_000;
    }

    fn reasoningEffortFn(_: *anyopaque) ?types.ReasoningEffort {
        return null;
    }

    fn supportsFn(_: *anyopaque, _: provider_mod.Capability) bool {
        return false;
    }

    // ── Run lifecycle ─────────────────────────────────────────────────────

    fn startRun(
        self: *SealedSkillProvider,
        messages: []const types.ApiMessage,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
    ) anyerror!provider_mod.StreamHandle {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();

        const prompt = try firstUserText(arena, messages);
        if (prompt.len == 0) return error.SealedNoPrompt;
        const tools_json = try self.allowedToolsJson(arena, tools orelse &.{});
        var params: std.Io.Writer.Allocating = .init(arena);
        try protocol.writeStartParams(&params.writer, .{
            .skill_id = self.pin.pin.entry.skill_id,
            .manifest_digest = self.pin.pin.entry.manifest_digest,
            .prompt = prompt,
            .arguments = &.{},
            .tools_json = tools_json,
            .max_cost_micros = self.max_cost_micros,
            .max_steps = self.max_steps,
            .client_name = "metacodes",
            .client_version = self.client_version,
            .client_platform = self.client_platform,
            .run_ref = self.session_id,
        });
        var response = self.transport.call(.runs_start, params.written(), abort) catch |err| return self.transportFailure(err);
        defer response.deinit();
        return self.consumeResponse(&response, null);
    }

    fn continueRun(
        self: *SealedSkillProvider,
        messages: []const types.ApiMessage,
        abort: ?*const AbortSignal,
    ) anyerror!provider_mod.StreamHandle {
        const run = &self.run.?;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();

        var results: std.ArrayList(protocol.ResultEntry) = .empty;
        if (messages.len == 0) return error.SealedChainBroken;
        const last = messages[messages.len - 1];
        for (last.content) |block| switch (block) {
            .tool_result => |result| {
                const call = findCall(run.calls, result.tool_use_id) orelse continue;
                if (call.pre_refusal != null) continue; // never dispatched; answered below
                var entry: protocol.ResultEntry = .{
                    .tool_use_id = result.tool_use_id,
                    .content = result.content,
                    .is_error = result.is_error,
                };
                // §6.4: the secret's value never reaches the gateway. Redact
                // before truncation so a cut cannot leave part of it behind.
                if (call.credential_refs.len != 0) {
                    const redacted = try self.redact(arena, entry.content, call.credential_refs);
                    entry.content = redacted.content;
                    entry.redactions = redacted.refs;
                }
                const limit = @min(call.result_limit_bytes orelse std.math.maxInt(u64), self.manifest().egress_max_result_bytes);
                if (entry.content.len > limit) {
                    entry.content = try truncateResult(arena, entry.content, @intCast(limit));
                    entry.truncated = true;
                }
                if (!self.toolAllowed(call.name)) {
                    // The frame refused this before dispatch; the gateway is
                    // told so and the violation is counted (§6.2).
                    entry.refusal = .policy_violation;
                    entry.is_error = true;
                    run.violations +|= 1;
                } else if (entry.is_error and isPermissionDenied(entry.content)) {
                    // The user (or the permission chain) declined the call.
                    entry.refusal = .permission_denied;
                }
                try results.append(arena, entry);
            },
            else => {},
        };
        for (run.calls) |call| if (call.pre_refusal) |refusal| {
            try results.append(arena, .{
                .tool_use_id = call.id,
                .content = refusal.message,
                .is_error = true,
                .refusal = refusal.refusal,
            });
        };
        if (results.items.len != run.calls.len) {
            log.warn("sealed", "run {s}: {d} results for {d} calls", .{ run.run_id, results.items.len, run.calls.len });
            return error.SealedChainBroken;
        }
        if (run.violations >= MAX_POLICY_VIOLATIONS) {
            self.cancelRun(.policy, abort);
            return self.finishWithText("[sealed skill cancelled: the gateway requested tools outside the pinned allowlist]");
        }
        return self.sendResults(arena, results.items, abort);
    }

    /// `runs.continue` with `results` for the current Step, then the next Step.
    fn sendResults(
        self: *SealedSkillProvider,
        arena: std.mem.Allocator,
        results: []const protocol.ResultEntry,
        abort: ?*const AbortSignal,
    ) anyerror!provider_mod.StreamHandle {
        const run = &self.run.?;
        var params: std.Io.Writer.Allocating = .init(arena);
        try protocol.writeContinueParams(&params.writer, run.run_id, run.run_state, run.seq, results);
        var response = self.transport.call(.runs_continue, params.written(), abort) catch |err| return self.transportFailure(err);
        defer response.deinit();
        return self.consumeResponse(&response, abort);
    }

    fn consumeResponse(
        self: *SealedSkillProvider,
        response: *protocol.ParsedResponse,
        abort: ?*const AbortSignal,
    ) anyerror!provider_mod.StreamHandle {
        switch (response.response) {
            .err => |err| {
                log.warn("sealed", "gateway error {d} ({s}): {s}", .{ err.code, if (err.known) |k| k.name() else "unknown", err.message });
                if (err.known) |known| switch (known) {
                    .manifest_changed => return error.SealedManifestChanged,
                    .unauthorized => return error.SealedUnauthorized,
                    .subscription_required => return error.SealedSubscriptionRequired,
                    .budget_exceeded => {
                        self.markFinished();
                        return self.finishWithText("[sealed skill stopped: the gateway reached the run's cost cap]");
                    },
                    else => {},
                };
                return error.SealedGatewayError;
            },
            .result => |result_json| {
                var parsed = protocol.parseStep(self.allocator, result_json) catch |err| {
                    log.warn("sealed", "unparseable step: {s}", .{@errorName(err)});
                    return error.SealedChainBroken;
                };
                defer parsed.deinit();
                return self.acceptStep(&parsed.step, abort);
            },
        }
    }

    fn acceptStep(self: *SealedSkillProvider, step: *const protocol.Step, abort: ?*const AbortSignal) anyerror!provider_mod.StreamHandle {
        // Chain and sequence checks (§8.3, §8.4) before anything is recorded.
        const expected_seq: u64 = if (self.run) |run| run.seq + 1 else 1;
        const expected_prev: []const u8 = if (self.run) |run| run.last_digest else protocol.GENESIS_DIGEST;
        if (step.seq != expected_seq or !std.mem.eql(u8, step.prev_digest, expected_prev)) {
            log.warn("sealed", "step chain broken: seq {d} (expected {d})", .{ step.seq, expected_seq });
            return error.SealedChainBroken;
        }
        if (self.run) |run| if (!std.mem.eql(u8, run.run_id, step.run_id)) return error.SealedChainBroken;
        const continues = step.kind == .tool_calls or step.kind == .input_required;
        if (continues and step.run_state.len == 0) return error.SealedChainBroken;

        // Adopt the Step: the previous Step's strings die with the arena.
        const previous_violations: u8 = if (self.run) |run| run.violations else 0;
        _ = self.run_arena.reset(.retain_capacity);
        const arena = self.run_arena.allocator();
        const calls = try arena.alloc(CallRef, step.calls.len);
        for (step.calls, calls) |call, *slot| slot.* = try self.adoptCall(arena, call);
        self.run = .{
            .run_id = try arena.dupe(u8, step.run_id),
            .run_state = try arena.dupe(u8, step.run_state),
            .seq = step.seq,
            .last_digest = try arena.dupe(u8, step.digest),
            .calls = calls,
            .cumulative_cost_micros = step.cumulative.cost_micros,
            .finished = !continues,
            .violations = previous_violations,
        };
        self.recordStep(step);

        // §6.5: the client stops on its own as soon as the cap is passed.
        if (self.max_cost_micros > 0 and step.cumulative.cost_micros > self.max_cost_micros and continues) {
            self.cancelRun(.budget, abort);
            return self.finishWithText("[sealed skill stopped: cost cap reached before the run completed]");
        }
        if (continues and step.seq >= self.max_steps) {
            self.cancelRun(.client_error, abort);
            return self.finishWithText("[sealed skill stopped: step limit reached]");
        }

        switch (step.kind) {
            .tool_calls => return self.streamCalls(step, abort),
            .final => return self.finishWithText(step.text),
            .failed => {
                const text = try std.fmt.allocPrint(self.allocator, "[sealed skill failed: {s}{s}{s}]", .{
                    step.reason,
                    if (step.message.len != 0) ": " else "",
                    step.message,
                });
                defer self.allocator.free(text);
                return self.finishWithText(text);
            },
            .input_required => return self.answerQuestion(step, abort),
        }
    }

    /// Bind a Step's call to what this client will do with it: substitute the
    /// credentials it lists (§6.4), or refuse it before dispatch when one of
    /// them is not bound here.
    fn adoptCall(self: *SealedSkillProvider, arena: std.mem.Allocator, call: protocol.Call) !CallRef {
        var ref: CallRef = .{
            .id = try arena.dupe(u8, call.id),
            .name = try arena.dupe(u8, call.name),
            .result_limit_bytes = call.result_limit_bytes,
            .confirm = call.confirm,
            .credential_refs = &.{},
            .pre_refusal = null,
        };
        if (call.credentials.len == 0) return ref;
        const skill_id = self.pin.pin.entry.skill_id;
        const skill_name = self.manifest().name;
        const refs = try arena.alloc([]const u8, call.credentials.len);
        for (call.credentials, refs) |name, *slot| {
            slot.* = try arena.dupe(u8, name);
            const declared = for (self.manifest().credentials) |declared| {
                if (std.mem.eql(u8, declared.ref, name)) break true;
            } else false;
            if (!declared) {
                ref.pre_refusal = .{
                    .refusal = .permission_denied,
                    .message = try std.fmt.allocPrint(arena, "credential reference '{s}' is not declared by the pinned manifest; the call was not executed", .{name}),
                };
                return ref;
            }
            if (!self.credentials.isBound(skill_id, name)) {
                const hint = try std.fmt.allocPrint(arena, "credential '{s}' is not bound on this client; bind it with: metacodes sealed bind {s} {s}", .{ name, skill_name, name });
                ref.pre_refusal = .{ .refusal = .permission_denied, .message = hint };
                try self.addNotice(hint);
                return ref;
            }
        }
        ref.credential_refs = refs;
        return ref;
    }

    fn addNotice(self: *SealedSkillProvider, text: []const u8) !void {
        for (self.notices.items) |known| if (std.mem.eql(u8, known, text)) return;
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.notices.append(self.allocator, owned);
    }

    fn streamCalls(self: *SealedSkillProvider, step: *const protocol.Step, abort: ?*const AbortSignal) anyerror!provider_mod.StreamHandle {
        const run = &self.run.?;
        var dispatched: usize = 0;
        for (run.calls) |call| {
            if (call.pre_refusal == null) dispatched += 1;
        }
        if (dispatched == 0) {
            // Nothing for the loop to run: answer the gateway now with the
            // refusals and go on to the next Step.
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const arena = scratch.allocator();
            var results: std.ArrayList(protocol.ResultEntry) = .empty;
            for (run.calls) |call| try results.append(arena, .{
                .tool_use_id = call.id,
                .content = call.pre_refusal.?.message,
                .is_error = true,
                .refusal = call.pre_refusal.?.refusal,
            });
            return self.sendResults(arena, results.items, abort);
        }
        const stream = try StreamResponse.create(self.allocator, .tool_use);
        errdefer stream.destroy();
        if (step.text.len != 0) try stream.pushText(step.text);
        for (step.calls, run.calls) |call, ref| {
            if (ref.pre_refusal != null) continue;
            if (ref.credential_refs.len == 0) {
                try stream.pushToolUse(call);
                continue;
            }
            const input = try self.substitute(self.allocator, call.input_json, ref.credential_refs);
            defer self.allocator.free(input);
            try stream.pushToolUse(.{ .id = call.id, .name = call.name, .input_json = input });
        }
        stream.pushUsage(step.usage);
        return stream.handle();
    }

    /// §6.4: `${SEALED_CRED:<ref>}` in `input_json` becomes the bound secret
    /// (JSON-escaped, so the document stays valid) for every ref in `refs`.
    fn substitute(self: *const SealedSkillProvider, allocator: std.mem.Allocator, input_json: []const u8, refs: []const []const u8) ![]u8 {
        var current = try allocator.dupe(u8, input_json);
        errdefer allocator.free(current);
        const skill_id = self.pin.pin.entry.skill_id;
        for (refs) |ref| {
            const secret = self.credentials.lookup(skill_id, ref) orelse continue;
            const needle = try credentials.placeholder(allocator, ref);
            defer allocator.free(needle);
            const escaped = try credentials.jsonEscaped(allocator, secret);
            defer @import("../../core/auth.zig").secureFree(allocator, escaped);
            const next = try credentials.replaceAll(allocator, current, needle, escaped);
            allocator.free(current);
            current = next;
        }
        return current;
    }

    const Redacted = struct { content: []const u8, refs: []const []const u8 };

    /// §6.4: every occurrence of a bound secret's value in `content` becomes
    /// `[redacted:<ref>]`; `refs` lists the references that were redacted.
    fn redact(self: *const SealedSkillProvider, arena: std.mem.Allocator, content: []const u8, refs: []const []const u8) !Redacted {
        var current = content;
        var redacted: std.ArrayList([]const u8) = .empty;
        const skill_id = self.pin.pin.entry.skill_id;
        for (refs) |ref| {
            const secret = self.credentials.lookup(skill_id, ref) orelse continue;
            if (secret.len == 0 or std.mem.indexOf(u8, current, secret) == null) continue;
            const marker = try std.fmt.allocPrint(arena, "[redacted:{s}]", .{ref});
            current = try credentials.replaceAll(arena, current, secret, marker);
            try redacted.append(arena, ref);
        }
        return .{ .content = current, .refs = redacted.items };
    }

    /// §4.3 `input_required`: put the question to the user over the UI
    /// requester and send the answer as the Step's one result. Without a
    /// channel the run is released and the question becomes the fork's text.
    fn answerQuestion(self: *SealedSkillProvider, step: *const protocol.Step, abort: ?*const AbortSignal) anyerror!provider_mod.StreamHandle {
        const question = step.question.?;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const asked = self.askUser(arena, question) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => Asked{ .declined = {} },
        };
        switch (asked) {
            .unavailable => {
                const text = try std.fmt.allocPrint(arena, "[sealed skill needs input] {s}", .{question.message});
                self.cancelRun(.client_error, abort);
                return self.finishWithText(text);
            },
            .declined => {
                const result: protocol.ResultEntry = .{
                    .tool_use_id = question.id,
                    .content = "the user did not answer the question",
                    .is_error = true,
                    .refusal = .aborted,
                };
                return self.sendResults(arena, &.{result}, abort);
            },
            .answered => |answer| {
                const result: protocol.ResultEntry = .{ .tool_use_id = question.id, .content = answer };
                return self.sendResults(arena, &.{result}, abort);
            },
        }
    }

    const Asked = union(enum) { unavailable, declined, answered: []const u8 };

    /// One `ask_question` dialog for the Step's question. Options come from a
    /// single-property `enum` in the elicitation schema when there is one;
    /// otherwise the dialog's free-text entry is the answer.
    fn askUser(self: *SealedSkillProvider, arena: std.mem.Allocator, question: protocol.Question) !Asked {
        const requester = self.ui orelse return .unavailable;
        const options = try enumOptions(arena, question.schema_json);
        const header = try std.fmt.allocPrint(arena, "/{s}", .{self.manifest().name});
        const questions = [_]tool_context.AskQuestion{.{
            .question = question.message,
            .header = header,
            .multi = false,
            .options = options,
        }};
        const req = ui_request.UiRequest{ .ask_question = &questions };
        var resp: ui_request.UiResponse = undefined;
        const outcome = try requester.request(self.session, arena, &req, &resp);
        switch (outcome) {
            .answered => {},
            // An asynchronous front end stashed the question; a provider
            // cannot suspend the fork, so this run cannot take the answer.
            .pending, .unavailable => return .unavailable,
        }
        switch (resp) {
            .answers => |answers| {
                if (answers.len == 0) return .declined;
                const answer = answers[0];
                if (answer.len == 0) return .declined;
                if (answer.len > MAX_ANSWER_BYTES) return .{ .answered = answer[0..MAX_ANSWER_BYTES] };
                return .{ .answered = answer };
            },
            else => return .declined,
        }
    }

    fn finishWithText(self: *SealedSkillProvider, text: []const u8) anyerror!provider_mod.StreamHandle {
        const stream = try StreamResponse.create(self.allocator, .end_turn);
        errdefer stream.destroy();
        for (self.notices.items) |notice| {
            const line = try std.fmt.allocPrint(self.allocator, "[sealed skill] {s}\n", .{notice});
            defer self.allocator.free(line);
            try stream.pushText(line);
        }
        if (text.len != 0) try stream.pushText(text);
        return stream.handle();
    }

    fn markFinished(self: *SealedSkillProvider) void {
        if (self.run) |*run| run.finished = true;
    }

    fn cancelRun(self: *SealedSkillProvider, reason: protocol.CancelReason, abort: ?*const AbortSignal) void {
        const run = &(self.run orelse return);
        if (run.finished) return;
        run.finished = true;
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        protocol.writeCancelParams(&params.writer, run.run_id, run.run_state, reason) catch return;
        var response = self.transport.call(.runs_cancel, params.written(), abort) catch |err| {
            log.warn("sealed", "cancel of run {s} failed: {s}", .{ run.run_id, @errorName(err) });
            return;
        };
        defer response.deinit();
        if (response.response == .result) {
            var parsed = protocol.parseStep(self.allocator, response.response.result) catch return;
            defer parsed.deinit();
            self.recordStep(&parsed.step);
        }
    }

    fn transportFailure(self: *SealedSkillProvider, err: transport.Error) anyerror {
        log.warn("sealed", "gateway {s}: {s} (http {d})", .{ self.pin.pin.gateway_url, @errorName(err), self.transport.last_http_status });
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Aborted => error.Aborted,
            error.Unauthorized => error.SealedUnauthorized,
            else => error.SealedGatewayError,
        };
    }

    fn recordStep(self: *SealedSkillProvider, step: *const protocol.Step) void {
        if (self.state_root.len == 0) return;
        const entry = &self.pin.pin.entry;
        const now: i64 = @intCast(@divTrunc(util_time.nowWallNs(), std.time.ns_per_ms));
        ledger.append(self.allocator, self.state_root, .{
            .kind = .step,
            .ts = now,
            .session_id = self.session_id,
            .gateway = self.pin.pin.gateway_url,
            .skill_id = entry.skill_id,
            .run_id = step.run_id,
            .seq = step.seq,
            .step_kind = @tagName(step.kind),
            .model = step.usage.model,
            .input_tokens = step.usage.input_tokens,
            .output_tokens = step.usage.output_tokens,
            .cache_read_tokens = step.usage.cache_read_input_tokens,
            .cache_creation_tokens = step.usage.cache_creation_input_tokens,
            .cost_micros = step.usage.cost_micros,
            .cumulative_cost_micros = step.cumulative.cost_micros,
            .currency = step.usage.currency,
            .digest = step.digest,
            .prev_digest = step.prev_digest,
            .issuer_skill_host = step.issuer_skill_host,
            .issuer_inference_gateway = step.issuer_inference_gateway,
            .calls = step.calls.len,
        }) catch |err| log.warn("sealed", "ledger append failed: {s}", .{@errorName(err)});
        if (step.charge) |charge| {
            ledger.append(self.allocator, self.state_root, .{
                .kind = .charge,
                .ts = now,
                .session_id = self.session_id,
                .gateway = self.pin.pin.gateway_url,
                .skill_id = entry.skill_id,
                .run_id = charge.run_id,
                .seq = step.seq,
                .step_kind = @tagName(step.kind),
                .cost_micros = charge.cost_micros,
                .cumulative_cost_micros = charge.cost_micros,
                .currency = charge.currency,
                .digest = charge.digest,
                .issuer_skill_host = step.issuer_skill_host,
                .issuer_inference_gateway = step.issuer_inference_gateway,
                .calls = charge.steps,
            }) catch |err| log.warn("sealed", "ledger append failed: {s}", .{@errorName(err)});
        }
    }

    // ── Allowlist projection ──────────────────────────────────────────────

    /// The definitions the gateway may call: those in `tools` whose name the
    /// pinned allowlist admits (§3.4 `tools`). Serialized as a JSON array in
    /// the client's own schema dialect.
    fn allowedToolsJson(self: *const SealedSkillProvider, arena: std.mem.Allocator, tools: []const json_mod.ToolDefinition) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.append(arena, '[');
        var first = true;
        for (tools) |tool| {
            if (tool.server_type != null or tool.deferred) continue;
            if (!self.toolAllowed(tool.name)) continue;
            if (!first) try buf.append(arena, ',');
            first = false;
            try api_request.serializeOneTool(tool, &buf, arena);
        }
        try buf.append(arena, ']');
        return buf.items;
    }

    /// Name-level admission against the pinned manifest: a `deny` rule that
    /// names the whole tool wins, then any `allow` rule for the tool admits
    /// it (argument patterns are the policy frame's job at dispatch time).
    pub fn toolAllowed(self: *const SealedSkillProvider, tool_name: []const u8) bool {
        const m = self.manifest();
        for (m.tools_deny) |raw| if (ruleNamesWholeTool(raw, tool_name)) return false;
        for (m.tools_allow) |raw| if (ruleCoversTool(raw, tool_name)) return true;
        return false;
    }
};

/// `Tool`, `Tool(pattern)`, or `prefix*` (MCP wildcard) covers `tool_name`.
fn ruleCoversTool(raw: []const u8, tool_name: []const u8) bool {
    const paren = std.mem.indexOfScalar(u8, raw, '(') orelse raw.len;
    const head = std.mem.trim(u8, raw[0..paren], " ");
    if (head.len == 0) return false;
    if (head[head.len - 1] == '*') return std.mem.startsWith(u8, tool_name, head[0 .. head.len - 1]);
    return std.mem.eql(u8, head, tool_name);
}

/// A rule without an argument pattern that covers the tool.
fn ruleNamesWholeTool(raw: []const u8, tool_name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, raw, '(') != null) return false;
    return ruleCoversTool(raw, tool_name);
}

fn findCall(calls: []const CallRef, id: []const u8) ?*const CallRef {
    for (calls) |*call| if (std.mem.eql(u8, call.id, id)) return call;
    return null;
}

/// Whether an error result is the loop's permission denial (user prompt or
/// permission chain): `{"error":{"code":"permission_denied",…}}`.
fn isPermissionDenied(content: []const u8) bool {
    return std.mem.indexOf(u8, content, "\"code\":\"permission_denied\"") != null;
}

/// Options for an `input_required` dialog from an elicitation schema whose
/// single property is an enum (`{"type":"object","properties":{"x":{"enum":
/// ["a","b"]}}}`); anything else yields no options, and the dialog's own
/// free-text entry takes the answer.
fn enumOptions(arena: std.mem.Allocator, schema_json: []const u8) ![]const tool_context.AskOption {
    if (schema_json.len == 0) return &.{};
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, schema_json, .{}) catch return &.{};
    if (parsed != .object) return &.{};
    const properties = parsed.object.get("properties") orelse return &.{};
    if (properties != .object or properties.object.count() != 1) return &.{};
    const only = properties.object.values()[0];
    if (only != .object) return &.{};
    const values = only.object.get("enum") orelse return &.{};
    if (values != .array or values.array.items.len == 0) return &.{};
    const options = try arena.alloc(tool_context.AskOption, values.array.items.len);
    for (values.array.items, options) |value, *slot| {
        if (value != .string) return &.{};
        slot.* = .{ .label = value.string, .description = "" };
    }
    return options;
}

/// All text blocks of the first user message, joined with blank lines.
fn firstUserText(arena: std.mem.Allocator, messages: []const types.ApiMessage) ![]const u8 {
    for (messages) |message| {
        if (message.role != .user) continue;
        var out: std.ArrayList(u8) = .empty;
        for (message.content) |block| switch (block) {
            .text => |text| {
                if (out.items.len != 0) try out.appendSlice(arena, "\n\n");
                try out.appendSlice(arena, text);
            },
            else => {},
        };
        return out.items;
    }
    return "";
}

/// Head of the result plus a marker and a short tail, within `limit` bytes.
fn truncateResult(arena: std.mem.Allocator, content: []const u8, limit: usize) ![]const u8 {
    const marker = "\n…[truncated by client result cap]…\n";
    if (limit <= marker.len + 64) return content[0..@min(content.len, limit)];
    const tail_len: usize = @min(256, (limit - marker.len) / 4);
    const head_len = limit - marker.len - tail_len;
    return std.mem.concat(arena, u8, &.{ content[0..head_len], marker, content[content.len - tail_len ..] });
}

// ── Stream replay of one Step ─────────────────────────────────────────────

const StreamResponse = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(api_stream.StreamEvent) = .empty,
    index: usize = 0,
    stop: api_stream.StopReason,
    request_id: log.RequestId,

    fn create(allocator: std.mem.Allocator, stop: api_stream.StopReason) !*StreamResponse {
        const self = try allocator.create(StreamResponse);
        self.* = .{ .allocator = allocator, .stop = stop, .request_id = log.genRequestId() };
        return self;
    }

    fn destroy(self: *StreamResponse) void {
        // Events the consumer has not taken are still ours (`index` runs one
        // past the end once `.done` has been handed out).
        const taken = @min(self.index, self.events.items.len);
        for (self.events.items[taken..]) |event| freeEvent(self.allocator, event);
        self.events.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn pushText(self: *StreamResponse, text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.events.append(self.allocator, .{ .text = owned });
    }

    fn pushToolUse(self: *StreamResponse, call: protocol.Call) !void {
        const id = try self.allocator.dupe(u8, call.id);
        errdefer self.allocator.free(id);
        const name = try self.allocator.dupe(u8, call.name);
        errdefer self.allocator.free(name);
        const input = try self.allocator.dupe(u8, call.input_json);
        errdefer self.allocator.free(input);
        try self.events.append(self.allocator, .{ .tool_use_start = .{ .id = id, .name = name, .input_json = input } });
    }

    fn pushUsage(self: *StreamResponse, usage: protocol.Usage) void {
        self.events.append(self.allocator, .{ .usage = .{
            .input_tokens = usage.input_tokens,
            .output_tokens = usage.output_tokens,
            .cache_read_input_tokens = usage.cache_read_input_tokens,
            .cache_creation_input_tokens = usage.cache_creation_input_tokens,
        } }) catch {};
    }

    fn handle(self: *StreamResponse) provider_mod.StreamHandle {
        return .{
            .ctx = @ptrCast(self),
            .image_placeholder_ids = &.{},
            .nextFn = nextFn,
            .deinitFn = deinitFn,
            .stopReasonFn = stopReasonFn,
            .requestIdFn = requestIdFn,
        };
    }

    fn cast(ctx: *anyopaque) *StreamResponse {
        return @ptrCast(@alignCast(ctx));
    }

    fn nextFn(ctx: *anyopaque) anyerror!?api_stream.StreamEvent {
        const self = cast(ctx);
        if (self.index < self.events.items.len) {
            const event = self.events.items[self.index];
            self.index += 1;
            return event;
        }
        if (self.index == self.events.items.len) {
            self.index += 1;
            return .done;
        }
        return null;
    }

    fn deinitFn(ctx: *anyopaque) void {
        cast(ctx).destroy();
    }

    fn stopReasonFn(ctx: *anyopaque) api_stream.StopReason {
        return cast(ctx).stop;
    }

    fn requestIdFn(ctx: *anyopaque) log.RequestId {
        return cast(ctx).request_id;
    }
};

fn freeEvent(allocator: std.mem.Allocator, event: api_stream.StreamEvent) void {
    switch (event) {
        .text => |text| allocator.free(text),
        .tool_use_start => |tool| {
            allocator.free(tool.id);
            allocator.free(tool.name);
            allocator.free(tool.input_json);
        },
        else => {},
    }
}

test "allowlist rules cover plain names, patterns and MCP wildcards" {
    try std.testing.expect(ruleCoversTool("Read", "Read"));
    try std.testing.expect(!ruleCoversTool("Read", "Write"));
    try std.testing.expect(ruleCoversTool("Bash(python3 *)", "Bash"));
    try std.testing.expect(ruleCoversTool("mcp__playwright__*", "mcp__playwright__browser_click"));
    try std.testing.expect(!ruleCoversTool("mcp__playwright__*", "mcp__github__issue"));
    try std.testing.expect(ruleNamesWholeTool("Bash", "Bash"));
    try std.testing.expect(!ruleNamesWholeTool("Bash(rm *)", "Bash"));
}

test "result truncation keeps a head, a marker and a tail within the cap" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const content = "x" ** 1000 ++ "TAIL";
    const out = try truncateResult(arena.allocator(), content, 300);
    try std.testing.expect(out.len <= 300);
    try std.testing.expect(std.mem.endsWith(u8, out, "TAIL"));
    try std.testing.expect(std.mem.indexOf(u8, out, "truncated by client") != null);
}

test "a permission denial in a tool result is recognized by its error code" {
    try std.testing.expect(isPermissionDenied("{\"error\":{\"code\":\"permission_denied\",\"category\":\"safety\",\"detail\":\"user declined 'Read' via prompt\",\"recoverable\":false}}"));
    try std.testing.expect(!isPermissionDenied("{\"error\":{\"code\":\"not_found\",\"detail\":\"x\"}}"));
    try std.testing.expect(!isPermissionDenied("plain output"));
}

test "input_required options come from a single enum property only" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const with_enum = try enumOptions(arena.allocator(), "{\"type\":\"object\",\"properties\":{\"ledger\":{\"type\":\"string\",\"enum\":[\"main\",\"test\"]}}}");
    try std.testing.expectEqual(@as(usize, 2), with_enum.len);
    try std.testing.expectEqualStrings("test", with_enum[1].label);
    try std.testing.expectEqual(@as(usize, 0), (try enumOptions(arena.allocator(), "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}}}")).len);
    try std.testing.expectEqual(@as(usize, 0), (try enumOptions(arena.allocator(), "")).len);
    try std.testing.expectEqual(@as(usize, 0), (try enumOptions(arena.allocator(), "not json")).len);
}

test "stream replays text, calls, usage, then done" {
    const a = std.testing.allocator;
    const stream = try StreamResponse.create(a, .tool_use);
    try stream.pushText("hi");
    try stream.pushToolUse(.{ .id = "c1", .name = "Read", .input_json = "{}" });
    stream.pushUsage(.{ .input_tokens = 3 });
    const h = stream.handle();
    defer h.deinit();
    const first = (try h.next()).?;
    try std.testing.expectEqualStrings("hi", first.text);
    a.free(first.text);
    const second = (try h.next()).?;
    try std.testing.expectEqualStrings("Read", second.tool_use_start.name);
    freeEvent(a, second);
    const third = (try h.next()).?;
    try std.testing.expectEqual(@as(u64, 3), third.usage.input_tokens);
    try std.testing.expect((try h.next()).? == .done);
    try std.testing.expect((try h.next()) == null);
    try std.testing.expectEqual(api_stream.StopReason.tool_use, h.stopReason());
}
