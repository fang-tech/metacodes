# PERF_MEMORY_PRINCIPLES — cc-zig 极致性能/内存 设计原则 + 量化指标

> 来源:2026-06-05 session。用户定架构总目标:**极致的性能和内存使用**。本文是所有后续改动(含 UI 解耦/事件协议)的总约束。
> 基线实测(2026-06-05,ReleaseSmall,macOS):见 §1。任何改动不得显著回退基线。
> 关联:TUI_STATE_ARCHITECTURE(UI 解耦)、UI 双向协议设计——它们必须遵守本文热路径零分配约束。

## §1 实测基线

| 维度 | 2026-06-05 | 2026-10-18(`main` @ `7efc170`) | 说明 |
|------|--------|--------|------|
| 二进制体积(ReleaseSmall) | **1.29 MB** | **5.50 MB**(strip 后 4.9 MB,gzip 2.6 MB) | metacodes 单体;06-05 时 Debug 8.6 MB |
| 启动时间(暖) | **<10 ms** | **5.1–7.2 ms**(6 次) | --help 路径;首次冷启是磁盘加载非代码 |
| 常驻内存峰值(空闲) | **1.78 MB RSS / 1.08 MB footprint** | **2.7 MB RSS / 1.7 MB footprint** | --help 路径(未含对话/工具/网络) |
| 典型会话 | 未测 | **23 MB RSS / 13.9 MB footprint** | headless,20 轮 Glob 工具,本地 Anthropic-SSE mock;TinyKG 未 stage(降级)、Jev 关 |
| 源码规模 | 127 文件 / 40K 行 | 460 文件 / 300K 行 | `src/**/*.zig` |

两列都是 macOS Apple Silicon 上单机单次实测;10-18 一列的方法见
[BENCHMARKS.md](BENCHMARKS.md#footprint-snapshot)。

**Linux x86_64(2026-10-29,WSL2 Ubuntu 22.04,`scripts/perf_baseline.sh` 各 5 次)**:`main` @ `8060498d` 本机构建
6.60 MB / `--help` RSS 3120 KB,glibc 2.31 + baseline CPU 构建 6.56 MB / 3088 KB,体积与 RSS 两条红线均超。
按 §3g 修完(#379 与其后续)后分别为 6098 KB / 2272 KB 与 6078 KB / 2620 KB,两条红线都回到线内,但体积余量只有 0.7% / 1.1%;
再去掉 Linux 的 `.eh_frame`(#381,§3f),在 `main` @ `dd95365c`(含 #382、#383)上:本机构建 6117 → 5815 KB / RSS 2400 KB;发布构建(`-Dtarget=x86_64-linux-gnu.2.31 -Drelease-layout=true -Drelease-symbols=true`,objcopy 拆分后的 `bin/metacodes`)6097 → 5794 KB / 2376 KB;体积余量 5.4% / 5.7%。
同一提交 Linux 比 macOS 大约 1 MB:arm64 默认开 LLVM MachineOutliner(x86_64 不开),`__text` 比 `.text` 小 1.6 MiB;
macOS 保留的符号表(约 0.6 MB)抵掉一部分。`--help` RSS 的文件页部分随代码布局和内核页缓存而变(±0.2 MB)。

对比 Claude Code(Node/TS):同机 2026-10-18 实测 Claude Code 2.1.278 `--help` 峰值 RSS 121 MB(仅进程底座,非会话)。cc-zig 已是**数量级优势**——目标是**守住并扩大**,绝不因功能堆叠回退。

## §2 量化目标指标(后续对标)

- **二进制**:ReleaseSmall ≤ 6 MiB(2026-10-18 按实测 5.50 MB 重新标定,留约 14% 给新功能;超了要查 bloat)。初版红线 1.5 MB 是按 06-05 的 1.29 MB 定的。
- **启动(暖)**:≤ 20 ms 到首个 prompt 可交互。
- **常驻内存**:空闲(无对话) ≤ 3 MB RSS;典型会话(20 轮 + 工具)≤ 30 MB RSS。
- **流式热路径**:每 token(text_chunk)**零堆分配**;spinner tick(100ms)单帧渲染 ≤ 单次 scratch 复用,无 per-tick alloc。
- **工具并发**:每工具独立 arena,批结束整体释放(已有)。

(指标是初版,实测校准。每次 release 跑基线脚本对比,回退 >10% 要查因。)

> **重新标定(2026-10-18,owner 决定按实际情况)**:二进制已从 1.29 MB 长到 5.50 MB,超出初版
> 1.5 MB 体积红线;体积红线改为 6 MiB,`scripts/perf_baseline.sh` 同步。启动(≤ 20 ms)、
> 空闲 RSS(≤ 3 MB)与典型会话(≤ 30 MB)三条红线不变,实测均在线内。

**CI 报告(#303)**:`ci.yml` 的 Linux 与 macOS `release` leg 各跑一次 `scripts/perf_baseline.sh --build`
(体积、暖启动、空闲 RSS 三条红线),输出写进该 job 的 summary。目前只报告不阻塞
(`continue-on-error`):超线或量不到时该 step 标红并发 warning,leg 仍为绿;攒够几周数据再决定是否改为阻塞。

## §3 设计原则(所有改动遵守)

### 3a. 热路径零分配(最高优先级)
- **流式文本/spinner/工具进度** = 热路径(每 token / 每 100ms)。**绝不 per-event 堆分配**。
- 手段:借用 slice 同步消费(不持有)、定长数组(current_tool[48]/tool_cards)、scratch writer 复用(resetScratch 非重建)、行缓冲 line_buf 复用容量(clearRetainingCapacity)。
- **UI 事件协议(CoreEvent)**:emit 的 slice 是 borrow,backend 同步消费(写 scrollback/拷定长),**不堆分配、不持有**。进程内 vtable = 零序列化零拷贝。

### 3b. Arena 批量释放优于逐个 free
- 临时分配(一轮工具/一次请求)挂 arena,批量释放(已有)。命名:gpa(调用者释放)/arena(批量)/scratch(不逃逸)。
- 避免长生命周期持有短期数据（工具结果从 byte zero 写 Session CAS，Conversation 只持 artifact receipt）。
- 静态工具必须声明 `ResultProduction`：未知规模的外部生产者只能是 `byte_zero_spool`，并由
  comptime 拒绝 legacy callback；确定有界结果用 `bounded_inline`，编辑类结果用
  `input_derived`。不能用“之后会投影”替代生成期 OOM 边界。

### 3c. 定长 + 值语义优于动态 + 指针
- 跨线程状态用定长数组 + 持锁拷贝(防 {ptr,len} 撕裂 + 防悬挂)——见 UiState.tools。
- ID/key 用定长数组值语义(防 collection grow 悬挂)。

### 3d. comptime 消除 vs 运行时分发的权衡
- 进程内热路径:能 comptime 特化的(如 headless 无 UI 方法编译期消失)优先。
- 但 UI 解耦要 vtable(运行时分发)以支持 GUI/语音/跨进程——vtable 调用开销(一次间接跳转)远小于序列化,可接受;**热路径(text_chunk)的 vtable emit 仍须零分配**。

### 3e. 序列化只在跨进程边界付代价
- 进程内 vtable backend:CoreEvent 直传,**不序列化**。
- 进程外 WsBackend(未来):才 JSON 序列化。协议可序列化是为了**能**跨进程,不是**总是**序列化。token 级事件量大,进程内绝不序列化。

### 3f. 二进制体积:ReleaseSmall + 按需链接
- 默认 ReleaseSmall(已 1.29 MB)。新依赖/大表(verb 库/工具 schema)评估体积。vendor 工具(ripgrep)进程外调用,不进二进制。
- **Linux 发布件不带 `.eh_frame`**(`build.zig` 给 release_mod 设 `unwind_tables = .none`,仅 Linux;省 300 KB)。
  - 程序自身从不读它:ReleaseSmall 默认 strip,`std.Options.allow_stack_tracing` 因此为 false,panic 只打印消息;没有任何依赖导入 `_Unwind_*` / `pthread_cancel` / `pthread_exit`。帧指针保留,`libc.so.6` 自带 `.eh_frame`。
  - 取舍在外部调试工具:**没有符号文件时**,gdb 看 core 只能展开到第一个 Zig 帧,`perf --call-graph=dwarf`、systemd-coredump 这类靠 CFI 的展开也会退化;`perf --call-graph=fp` 照常可用。**有发布的符号文件时**(`-Drelease-symbols` 从同一次链接拆出的 `metacodes.debug`,其 DWARF 带 `.debug_frame`;见 [RELEASE_RUNNER.md](RELEASE_RUNNER.md#debug-symbols)),gdb 能完整展开、带函数名和源码行。
  - 实测(#381,core 取自真实运行,停在第一次 `connect`):`gdb -s metacodes.debug -e bin/metacodes -c core` 三个线程 47 帧全部展开,参数值正确;从 `metacodes.debug` 删掉 `.debug_frame` 后帧名不变、参数读成 `0x0`。带 `.eh_frame` 的旧构建用同一命令也读成 `0x0`:`-e` 不从可执行文件取展开信息,`--only-keep-debug` 又把 `.eh_frame` 留成 NOBITS;去掉 unwind tables 后 LLVM 把 CFI 写进 `.debug_frame`,随符号文件走。
  - macOS 与 Windows 不变(Windows x64 的 SEH 必须有 unwind 数据)。

### 3g. 大值类型的初始化与 `defer`(Zig 0.16 代码生成)
- **现象**(2026-10-29 Linux x86_64 ReleaseSmall 实测):编译期整体已知的聚合值——字段默认值 `= .{}`、具名常量、带类型字面量 `T{ … }`、以及大载荷错误联合/optional/union 的 `return error.X` / `return null` / `return .tag`——被降级成"从只读常量 memcpy",其中 `undefined` 字节按 0 写进 `.rodata`。这类常量当时约 600 KB,最大一处是控制面事件环 138 KiB。
- **写法**:含 KB 级数组/缓冲区的值,在构造点用结果位置写法并点名 `undefined` 字段:`var x: T = .{ .buf = undefined }`、`return .{ …, .journal = .{ .entries = undefined } }`;不用 `T{ … }`、`.{}` 或具名常量。必要时去掉大数组字段的默认值,让 `.{}` 编译不过。
- **`defer` 体复制到作用域的每个出口**:出口多(几十上百个 `try`/`return`/`break`)的函数里,非平凡的 `defer` 块放进 `noinline` 函数,defer 只调用它。`runCounted` 的九个运行结束记录曾因此占 270 KB。改完以 `scripts/perf_baseline.sh` 实测为准:DWARF 行归因会把一个出口的整条清理链记在一行 `defer` 上。
- **返回 KB 级结果的函数里不写字面量错误**:`ToolResultBody`、`RequestResult`、配置 `Document` 这类结果,每个 `return error.X`(以及 `orelse`/`catch` 里的)按错误名各落一份常量,当时合计约 320 KB。写法有三种:
  - 主体写成 `fn fooInto(out: *T, …) !void`,成功时写 `out.*`;原函数留作 `var r: T = undefined; try fooInto(&r, …); return r;` 的包装。
  - 前置检查放进不带载荷的 helper,用 `try`。
  - 已在变量里的错误直接 `return err`,它不产生常量。

  载荷较小(1–2 KiB)的这类常量仍有一些;新代码按上面写。

## §4 验证机制

- **基线脚本**(scripts/perf_baseline.sh):量二进制体积 + 启动时间 + --help RSS,输出对比上次。每阶段/release 跑。
- **热路径零分配验证**:关键路径(流式/spinner)用 testing.allocator 或 failing_allocator 在单测里确认无意外分配(Zig 可注入 allocator 计分配次数)。
- **回退红线**:二进制 >1.5MB / 启动 >20ms / 空闲 RSS >3MB → 查因,不放行。

## §5 与 UI 解耦架构的交点(硬约束)

UI 双向协议(CoreEvent/UiEvent)+ vtable UiBackend 必须遵守:
- text_chunk/tool_progress 热路径 emit 零堆分配(borrow 同步消费)。
- 进程内默认零序列化(vtable 直传)。
- TuiBackend.emit 复用现有 scratch/line_buf/定长卡,不新增 per-event 分配。
- 这条是 UI 解耦能做的前提——若 vtable emit 引入热路径分配,宁可不解耦。
