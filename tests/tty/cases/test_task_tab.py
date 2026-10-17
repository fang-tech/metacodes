"""T25-T27:Task 清单 —— 输入框上方显示任务(B3 多行面板:◼/◻/✓ + TTL)。

离线驱动:用测试专用本地命令 /task-test[:label] 造一个 in_progress 任务
(loop.zig),无需打模型即可让清单渲染。验证 ◼ <label> 行出现在输入框上方,
框仍钉底、布局不乱。
"""
from tty_driver import run
from asserts import TTYAssert

# 等屏幕条件,不用固定睡眠。原先是 sleep:0.8 → 打字 → enter → sleep:0.4:hosted Windows runner 上
# ConPTY 回显慢,提交后约 1.2s 的静默窗口里画面还没到,T29 抓到的是还没提交的输入框
# (TTY (Windows) job 117303780270,重跑即过)。现在:
#   ① 等输入框画出来才打字——readLineRaw 先进 raw mode 再画框,框已上屏则键不会被进 raw mode
#     时的 TCSAFLUSH 吞掉;
#   ② 提交后等命令的产物上屏。pattern 不能用标签本身:输入行 `❯ /task-test:building widget`
#     里就有标签,会立即命中。任务行只等图标:断言本来就分别查图标和标签、不要求两者相邻,
#     ConPTY 重合成后它们是否相邻没验证过。
# 等不到不抛错(wait: 语义),交给下面的断言给出屏幕 diff;成功路径命中即返回,上限不增加耗时。
WAIT_S = 20


def _submit(command, rendered):
    return [f"wait:bypass permissions on:{WAIT_S}", f"type:{command}", "key:enter",
            f"wait:{rendered}:{WAIT_S}"]


def test_T25_tasktab_appears_above_box(bin_path):
    # 造任务 → 输入框上方应出现 `◼ building widget` 行(in_progress 图标,对齐 cc TaskListV2)。
    raw = run(bin_path, _submit("/task-test:building widget", "◼"))
    a = TTYAssert(raw)
    a.assert_box_present()
    top = a.box_top_row()
    if top is None or top == 0:
        a._fail(f"box_top_row 异常(top={top}),无法验证上方任务清单")
    # 清单在上边框正上方一行。
    tab_line = a.final.line_text(top - 1)
    if "◼" not in tab_line or "building widget" not in tab_line:
        a._fail(f"任务清单行(row {top-1})未含 ◼ + label:'{tab_line}'")


def test_T26_tasktab_keeps_box_at_bottom(bin_path):
    # 有清单时框仍钉底(下边框紧邻 footer,新增的上方行不破坏底部锚定)。
    raw = run(bin_path, _submit("/task-test:x", "◼"))
    a = TTYAssert(raw)
    a.assert_box_present()
    a.assert_box_at_bottom()


def test_T27_no_tasktab_when_no_task(bin_path):
    # 无任务时不画清单(区不含 ◼/◻/✓),回归确认默认行为不变。
    raw = run(bin_path, ["sleep:0.8"])
    a = TTYAssert(raw)
    a.assert_box_present()
    full = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
    for icon in ("◼", "◻", "✓"):
        if icon in full:
            a._fail(f"无任务时不应出现任务清单图标 {icon}")


def test_T28_completed_task_shows_checkmark(bin_path):
    # 回归(用户实测 bug):completed 任务图标应是**勾 ✓**,不是实心圆 ●。
    # /task-test-done 离线造一个 completed 任务,断言清单行含 ✓ 且**不含** ●。
    raw = run(bin_path, _submit("/task-test-done:answered q1", "✓"))
    a = TTYAssert(raw)
    a.assert_box_present()
    full = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
    if "answered q1" not in full:
        a._fail(f"completed 任务未渲染(缺 label):\n{full}")
    if "✓" not in full:
        a._fail(f"completed 任务图标应为勾 ✓,实际清单:\n{full}")
    if "●" in full:
        a._fail(f"completed 任务不应再用实心圆 ●(应改勾 ✓):\n{full}")


def test_T28_agent_tree_appears_above_box(bin_path):
    # /agent-test 注册假 running subagent → 输入框上方出现 agent 进度树
    # (⏺ Running 1 Explore agent… + 行 N tool use · tokens + 动作行冒号式),框仍钉底。
    # 对齐 cc v2.1.168 实拍金标准(napicc 录制)。
    raw = run(bin_path, _submit("/agent-test:inspect repo", "Running 1 Explore agent"))
    a = TTYAssert(raw)
    a.assert_box_present()
    a.assert_box_at_bottom()
    full = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
    # 标题按 type 分组(Explore)。
    if "Running 1 Explore agent" not in full:
        a._fail(f"未出现按 type 分组的标题 'Running 1 Explore agent':\n{full}")
    if "inspect repo" not in full:
        a._fail("agent 树未显示 subagent desc")
    # 行格式:N tool use(s)(对齐 cc,非旧 `N tools · turn M`)。
    if "tool use" not in full:
        a._fail(f"agent 树行未显示 'tool use(s)':\n{full}")
    # 动作行冒号式 Tool: arg(对齐 cc `⎿ Read: /path`,非旧 `Read(/path)`)。
    if "Read:" not in full:
        a._fail(f"agent 树动作行未显示冒号式 'Read:':\n{full}")


def test_T29_agent_tree_multi_grouped_title(bin_path):
    # /agent-test-multi 造 3 个 Explore agent(2 running + 1 done)→ 标题 "Running 2 Explore agents…"
    # + 三态动作行(Read: / Initializing… / Done)。
    raw = run(bin_path, _submit("/agent-test-multi", "Running 2 Explore agents"))
    a = TTYAssert(raw)
    a.assert_box_present()
    full = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
    if "Running 2 Explore agents" not in full:
        a._fail(f"未出现复数分组标题 'Running 2 Explore agents':\n{full}")
    # 三态动作行全在。
    for needle in ("Read:", "Initializing…", "Done"):
        if needle not in full:
            a._fail(f"agent 树缺三态动作行 '{needle}':\n{full}")
    # 0 tool uses 的 agent 不显 tokens(mod1)。
    if "0 tool uses" not in full:
        a._fail(f"未出现 '0 tool uses':\n{full}")
