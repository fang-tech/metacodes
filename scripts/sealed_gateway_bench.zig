//! Load benchmark for the sealed gateway (doc/SEALED_GATEWAY_SCALE_DESIGN.md
//! §10): N concurrent clients each run R sealed runs of S Steps against a
//! gateway whose upstream model is an in-process mock answering after a fixed
//! latency. No provider is paid; the mock is the only model.
//!
//! Reports Steps per second, the gateway's own overhead per Step (observed
//! Step latency minus the mock latency) at p50/p95/p99, admission counters
//! and the provider-cache hit ratio. The numbers are recorded in
//! doc/BENCHMARKS.md with the machine and commit they came from.
//!
//!   zig build sealed:bench -- --concurrency 64 --runs 256 --steps 4 --latency-ms 20

const std = @import("std");
const mc = @import("metacodes-core");
const net = @import("platform").net;
const pfs = @import("platform").fs;
const psync = @import("platform").sync;

const protocol = mc.skills_sealed_protocol;
const transport = mc.skills_sealed_transport;
const gateway_mod = mc.skills_sealed_gateway;
const util_time = mc.util_time;
const util_json = mc.util_json;

const MANIFEST =
    \\{"schema":"metask.sealed-skill.manifest/v1","skill_id":"ssk_bench","version":"1.0.0",
    \\"name":"bench","description":"Benchmark skill: reads one file and answers.",
    \\"tools":{"allow":["Read"]},"egress":{"classes":["file_contents"],"max_result_bytes":65536}}
;
const SKILL_MD = "---\nname: bench\ndescription: Benchmark skill.\n---\nRead the file the user names and summarize it.\n";
const TOOLS_JSON = "[{\"name\":\"Read\",\"description\":\"Read a file\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"file_path\":{\"type\":\"string\"}},\"required\":[\"file_path\"]}}]";

const TOOL_USE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":30,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"Read\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"data.txt\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":9}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";
const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"f\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":40,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Config = struct {
    concurrency: usize = 32,
    runs: usize = 128,
    steps: usize = 4,
    latency_ms: u64 = 20,
    workers: usize = 0,
    max_model_calls: usize = 0,
    provider_cache_ms: u64 = 60_000,
    /// Skip the gateway: POST straight to the mock model, one request per
    /// "Step". Separates what the host, loopback and mock cost from what the
    /// gateway adds.
    direct: bool = false,
};

/// The mock model: an accept loop feeding a fixed pool of serving threads
/// (so the mock itself never serializes on thread creation), each answer
/// after `latency_ms`; a tool call until the request carries a tool result,
/// then the end of the turn. It records how long it actually slept, so the
/// benchmark subtracts the mock's real latency, not its nominal one.
const MockModel = struct {
    listener: net.Socket,
    port: u16,
    latency_ms: u64,
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    slept_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    mutex: psync.Mutex = .{},
    cond: psync.Condition = .{},
    queue: std.ArrayList(net.Socket) = .empty,
    accept_thread: std.Thread = undefined,
    servers: []std.Thread = &.{},

    const SERVERS: usize = 256;

    fn start(latency_ms: u64) !*MockModel {
        const listener = try net.listenLoopback(0, 1024);
        const self = try std.heap.page_allocator.create(MockModel);
        self.* = .{ .listener = listener.sock, .port = listener.port, .latency_ms = latency_ms };
        self.servers = try std.heap.page_allocator.alloc(std.Thread, SERVERS);
        for (self.servers) |*thread| thread.* = try std.Thread.spawn(.{}, serveLoop, .{self});
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    fn stop(self: *MockModel) void {
        self.closing.store(true, .release);
        if (net.connectLoopback(self.port)) |wake| net.closeSocket(wake) else |_| {}
        self.accept_thread.join();
        self.mutex.lock();
        self.cond.broadcast();
        self.mutex.unlock();
        for (self.servers) |thread| thread.join();
        for (self.queue.items) |fd| net.closeSocket(fd);
        net.closeSocket(self.listener);
    }

    fn averageLatencyMs(self: *MockModel) u64 {
        const n = self.requests.load(.monotonic);
        return if (n == 0) 0 else self.slept_ms.load(.monotonic) / n;
    }

    fn acceptLoop(self: *MockModel) void {
        while (true) {
            const conn = net.acceptConn(self.listener) orelse {
                if (self.closing.load(.acquire)) return;
                continue;
            };
            if (self.closing.load(.acquire)) {
                net.closeSocket(conn);
                return;
            }
            self.mutex.lock();
            self.queue.append(std.heap.page_allocator, conn) catch {
                self.mutex.unlock();
                net.closeSocket(conn);
                continue;
            };
            self.cond.signal();
            self.mutex.unlock();
        }
    }

    fn serveLoop(self: *MockModel) void {
        while (true) {
            self.mutex.lock();
            while (self.queue.items.len == 0 and !self.closing.load(.acquire)) self.cond.wait(&self.mutex);
            if (self.queue.items.len == 0) {
                self.mutex.unlock();
                return;
            }
            const fd = self.queue.orderedRemove(0);
            self.mutex.unlock();
            self.serve(fd);
        }
    }

    fn serve(self: *MockModel, fd: net.Socket) void {
        defer net.closeSocket(fd);
        net.setRecvTimeoutMs(fd, 10_000);
        var buf: [256 * 1024]u8 = undefined;
        var total: usize = 0;
        var headers_end: ?usize = null;
        var content_length: usize = 0;
        while (total < buf.len and headers_end == null) {
            const n = net.recv(fd, buf[total..]);
            if (n <= 0) return;
            total += @intCast(n);
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |i| {
                headers_end = i + 4;
                content_length = contentLength(buf[0..i]);
            }
        }
        const he = headers_end orelse return;
        if (content_length > buf.len - he) return;
        while (total - he < content_length) {
            const n = net.recv(fd, buf[total .. he + content_length]);
            if (n <= 0) return;
            total += @intCast(n);
        }
        const body = buf[he..total];
        _ = self.requests.fetchAdd(1, .monotonic);
        const before = util_time.nowMs();
        if (self.latency_ms != 0) util_time.sleepMs(self.latency_ms);
        _ = self.slept_ms.fetchAdd(@intCast(util_time.nowMs() - before), .monotonic);
        const sse = if (std.mem.indexOf(u8, body, "tool_result") != null) FINAL_SSE else TOOL_USE_SSE;
        var head_buf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{sse.len}) catch return;
        if (!writeAll(fd, head)) return;
        _ = writeAll(fd, sse);
    }
};

fn contentLength(head: []const u8) usize {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "content-length")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch 0;
    }
    return 0;
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

/// One client thread: its share of the runs, each `steps` tool Steps and a
/// final Step; every Step's latency is recorded.
const Worker = struct {
    allocator: std.mem.Allocator,
    gateway_url: []const u8,
    model_url: []const u8,
    manifest_digest: []const u8,
    runs: usize,
    steps: usize,
    direct: bool = false,
    latencies: std.ArrayList(u64) = .empty,
    admissions: u64 = 0,
    failures: u64 = 0,

    fn run(self: *Worker) void {
        self.runAll() catch |err| {
            std.debug.print("worker failed: {s}\n", .{@errorName(err)});
            self.failures += 1;
        };
    }

    fn runAll(self: *Worker) !void {
        // One I/O runtime per client thread: a runtime shared by every
        // client would serialize their connections and measure itself.
        var io_runtime = @import("platform").signal.threadedIo(self.allocator, .{});
        defer io_runtime.deinit();
        if (self.direct) return self.runDirect(io_runtime.io());
        var client = try transport.Client.init(self.allocator, io_runtime.io(), self.gateway_url, "");
        defer client.deinit();
        client.provider_credential = "bench-credential";
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        for (0..self.runs) |_| {
            _ = scratch.reset(.retain_capacity);
            const arena = scratch.allocator();
            var params: std.Io.Writer.Allocating = .init(arena);
            try protocol.writeStartParams(&params.writer, .{
                .skill_id = "ssk_bench",
                .manifest_digest = self.manifest_digest,
                .prompt = "summarize data.txt",
                .tools_json = TOOLS_JSON,
                .max_cost_micros = 0,
                .max_steps = 64,
                .client_name = "sealed-bench",
                .client_version = "0",
                .client_platform = "bench",
                .base_dir = "/bench/skill",
                .provider_kind = "anthropic",
                .provider_base_url = self.model_url,
                .model = "claude-sonnet-4-20250514",
            });
            var step = try self.call(&client, .runs_start, params.written());
            defer step.deinit();
            var taken: usize = 0;
            while (step.step.kind == .tool_calls) {
                taken += 1;
                if (taken > self.steps + 2) return error.StepRunaway;
                var results: std.ArrayList(protocol.ResultEntry) = .empty;
                for (step.step.calls) |pending| {
                    // The last tool Step of a run answers with a result the mock
                    // reads as "end the turn"; earlier ones keep it calling.
                    try results.append(arena, .{ .tool_use_id = pending.id, .content = if (taken >= self.steps) "DATA (final)" else "DATA" });
                }
                var cont: std.Io.Writer.Allocating = .init(arena);
                try protocol.writeContinueParams(&cont.writer, step.step.run_id, step.step.run_state, step.step.seq, results.items);
                const next = try self.call(&client, .runs_continue, cont.written());
                step.deinit();
                step = next;
            }
            if (step.step.kind != .final) return error.RunNotFinal;
        }
    }

    /// `--direct`: the same number of requests straight at the mock model.
    fn runDirect(self: *Worker, io: std.Io) !void {
        var http: std.http.Client = .{ .allocator = self.allocator, .io = io };
        defer http.deinit();
        const total = self.runs * (self.steps + 1);
        for (0..total) |index| {
            const started = util_time.nowMs();
            var body: std.Io.Writer.Allocating = .init(self.allocator);
            defer body.deinit();
            const payload: []const u8 = if (index % (self.steps + 1) == self.steps) "{\"tool_result\":1}" else "{}";
            _ = try http.fetch(.{
                .location = .{ .url = self.model_url },
                .method = .POST,
                .payload = payload,
                .keep_alive = false,
                .response_writer = &body.writer,
            });
            try self.latencies.append(self.allocator, @intCast(util_time.nowMs() - started));
        }
    }

    /// One admitted call: resend on `rate_limited` / 503 as a client does.
    fn call(self: *Worker, client: *transport.Client, method: protocol.Method, params_json: []const u8) !protocol.ParsedStep {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const started = util_time.nowMs();
            var response = client.call(method, params_json, null) catch |err| switch (err) {
                error.Overloaded => {
                    self.admissions += 1;
                    util_time.sleepMs(@max(client.last_retry_after_ms, 50));
                    continue;
                },
                else => return err,
            };
            defer response.deinit();
            switch (response.response) {
                .err => |rpc| {
                    if (rpc.known) |known| if (known == .rate_limited and attempt < 1000) {
                        self.admissions += 1;
                        util_time.sleepMs(@max(util_json.extractIntField(rpc.data_json, "retry_after_ms"), 50));
                        continue;
                    };
                    std.debug.print("gateway error {d}: {s}\n", .{ rpc.code, rpc.message });
                    return error.GatewayError;
                },
                .result => |result| {
                    try self.latencies.append(self.allocator, @intCast(util_time.nowMs() - started));
                    return try protocol.parseStep(self.allocator, result);
                },
            }
        }
    }
};

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var z_buf: [4096]u8 = undefined;
    if (path.len >= z_buf.len) return error.PathTooLong;
    @memcpy(z_buf[0..path.len], path);
    z_buf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&z_buf), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (fd < 0) return error.WriteFailed;
    defer pfs.close(fd);
    const n = pfs.write(fd, bytes);
    if (n < 0 or @as(usize, @intCast(n)) != bytes.len) return error.WriteFailed;
}

fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const index: usize = @intFromFloat(@floor(p * @as(f64, @floatFromInt(sorted.len - 1))));
    return sorted[@min(index, sorted.len - 1)];
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    var config = Config{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        const value = args.next() orelse "";
        if (std.mem.eql(u8, arg, "--concurrency")) config.concurrency = try std.fmt.parseInt(usize, value, 10);
        if (std.mem.eql(u8, arg, "--runs")) config.runs = try std.fmt.parseInt(usize, value, 10);
        if (std.mem.eql(u8, arg, "--steps")) config.steps = try std.fmt.parseInt(usize, value, 10);
        if (std.mem.eql(u8, arg, "--latency-ms")) config.latency_ms = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, arg, "--workers")) config.workers = try std.fmt.parseInt(usize, value, 10);
        if (std.mem.eql(u8, arg, "--max-model-calls")) config.max_model_calls = try std.fmt.parseInt(usize, value, 10);
        if (std.mem.eql(u8, arg, "--provider-cache-ms")) config.provider_cache_ms = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, arg, "--direct")) config.direct = std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
    }

    // Package directory under the platform temp root.
    var root_buf: [512]u8 = undefined;
    const root = mc.util_fs.testing.perPidDir(&root_buf, "cc-zig-sealed-bench");
    const packages = try std.fmt.allocPrint(allocator, "{s}/packages", .{root});
    defer allocator.free(packages);
    const skill_dir = try std.fmt.allocPrint(allocator, "{s}/bench", .{packages});
    defer allocator.free(skill_dir);
    try mc.util_fs.mkdirParents(skill_dir);
    const md_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
    defer allocator.free(md_path);
    try writeFile(md_path, SKILL_MD);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{skill_dir});
    defer allocator.free(manifest_path);
    try writeFile(manifest_path, MANIFEST);
    defer mc.util_fs.testing.rmrfBestEffort(root);

    const model = try MockModel.start(config.latency_ms);
    defer model.stop();
    const model_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1/messages", .{model.port});
    defer allocator.free(model_url);

    const gateway = try gateway_mod.Gateway.init(allocator, packages, .{ .provider_cache_ms = config.provider_cache_ms });
    defer gateway.deinit();
    const server = try gateway_mod.Server.startWith(allocator, gateway, .{ .workers = config.workers, .max_model_calls = config.max_model_calls, .keepalive_ms = 0 });
    defer server.stop();
    const gateway_url = try server.url(allocator);
    defer allocator.free(gateway_url);
    const manifest_digest = gateway.packages[0].entry.manifest_digest;

    const workers = try allocator.alloc(Worker, config.concurrency);
    defer allocator.free(workers);
    const threads = try allocator.alloc(std.Thread, config.concurrency);
    defer allocator.free(threads);
    for (workers, 0..) |*worker, index| {
        worker.* = .{
            .allocator = allocator,
            .gateway_url = gateway_url,
            .model_url = model_url,
            .manifest_digest = manifest_digest,
            .runs = config.runs / config.concurrency + @as(usize, if (index < config.runs % config.concurrency) 1 else 0),
            .steps = config.steps,
            .direct = config.direct,
        };
    }
    const started = util_time.nowMs();
    for (workers, threads) |*worker, *thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    for (threads) |thread| thread.join();
    const elapsed_ms: u64 = @intCast(@max(util_time.nowMs() - started, 1));

    var all: std.ArrayList(u64) = .empty;
    defer all.deinit(allocator);
    var admissions: u64 = 0;
    var failures: u64 = 0;
    for (workers) |*worker| {
        try all.appendSlice(allocator, worker.latencies.items);
        worker.latencies.deinit(allocator);
        admissions += worker.admissions;
        failures += worker.failures;
    }
    std.mem.sort(u64, all.items, {}, std.sort.asc(u64));
    const stats = server.stats();
    const pool = gateway.poolStats();
    const steps = all.items.len;
    const per_second = @as(f64, @floatFromInt(steps)) * 1000.0 / @as(f64, @floatFromInt(elapsed_ms));
    const mock_actual_ms = model.averageLatencyMs();
    const overhead = struct {
        fn of(latency: u64, mock: u64) u64 {
            return if (latency > mock) latency - mock else 0;
        }
    };
    const p50 = percentile(all.items, 0.50);
    const p95 = percentile(all.items, 0.95);
    const p99 = percentile(all.items, 0.99);
    std.debug.print(
        \\sealed gateway bench
        \\  concurrency={d} runs={d} steps/run={d} mock_latency_ms={d} (actual avg {d}) workers={d} model_slots={d} queue={d}
        \\  steps={d} elapsed_ms={d} steps_per_s={d:.1} failures={d}
        \\  step_latency_ms p50={d} p95={d} p99={d}  (overhead above the mock's actual latency: p50={d} p95={d} p99={d})
        \\  admission: rejected_model={d} rejected_queue={d} client_resends={d}
        \\  provider cache: hits={d} misses={d} size={d}  mock requests={d}
        \\  gateway internals (avg ms per Step): queue wait={d} handle={d} shadow loop={d}
        \\
    , .{
        config.concurrency,
        config.runs,
        config.steps,
        config.latency_ms,
        mock_actual_ms,
        stats.workers,
        stats.max_model_calls,
        stats.queue_depth,
        steps,
        elapsed_ms,
        per_second,
        failures,
        p50,
        p95,
        p99,
        overhead.of(p50, mock_actual_ms),
        overhead.of(p95, mock_actual_ms),
        overhead.of(p99, mock_actual_ms),
        stats.rejected_model,
        stats.rejected_queue,
        admissions,
        pool.hits,
        pool.misses,
        pool.size,
        model.requests.load(.monotonic),
        if (stats.served == 0) 0 else stats.queue_wait_ms / stats.served,
        if (gateway.timing_steps.load(.monotonic) == 0) 0 else gateway.timing_handle_ms.load(.monotonic) / gateway.timing_steps.load(.monotonic),
        if (gateway.timing_steps.load(.monotonic) == 0) 0 else gateway.timing_loop_ms.load(.monotonic) / gateway.timing_steps.load(.monotonic),
    });
    std.debug.print(
        "{{\"schema\":\"metacodes.sealed-bench/v1\",\"concurrency\":{d},\"runs\":{d},\"steps\":{d},\"mock_latency_ms\":{d},\"mock_actual_ms\":{d},\"elapsed_ms\":{d},\"steps_per_s\":{d:.1},\"p50_ms\":{d},\"p95_ms\":{d},\"p99_ms\":{d},\"overhead_p50_ms\":{d},\"overhead_p99_ms\":{d},\"rejected_model\":{d},\"rejected_queue\":{d},\"resends\":{d},\"pool_hits\":{d},\"pool_misses\":{d},\"failures\":{d}}}\n",
        .{
            config.concurrency,
            config.runs,
            steps,
            config.latency_ms,
            mock_actual_ms,
            elapsed_ms,
            per_second,
            p50,
            p95,
            p99,
            overhead.of(p50, mock_actual_ms),
            overhead.of(p99, mock_actual_ms),
            stats.rejected_model,
            stats.rejected_queue,
            admissions,
            pool.hits,
            pool.misses,
            failures,
        },
    );
    return if (failures == 0) 0 else 1;
}
