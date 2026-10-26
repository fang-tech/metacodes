"""T45-T47:resize 打在一个按键序列的字节之间(#340),以及同一处改动修好的单按 Esc。

REPL 的 SIGWINCH 处理器没有 SA_RESTART:resize 把阻塞中的读变成 EINTR。反向搜索和
transcript viewer 以前逐字节读转义序列,ESC 之后那次读被 EINTR 打断就当成读完了——
搜索被取消、viewer 被关掉,序列剩下的 `[A` 落进输入框成了两个字。现在两处都经
input.readKey 用 KeyParser 拼键:被打断只是重画再读,序列留在 parser 里接着拼。

ESC、resize、`[A` 在一个 ESC 等待(200ms)之内先后到达:终端把一个键的字节一起发出,
resize 只是恰好落在中间。间隔再长就是先按了 Esc 再打 `[A`,本来就该分开处理。
"""
from tty_driver import IS_WINDOWS, READY, run, wait_for
from asserts import TTYAssert

try:
    from e2e_helpers import SkipTest
except ImportError:  # pragma: no cover - 与 run_tty_tests 的兜底一致
    class SkipTest(Exception):
        pass

SPLIT_BY_RESIZE = ["raw:\\x1b", "resize-now:24x70", "raw:[A"]


def _skip_without_sigwinch():
    if IS_WINDOWS:
        raise SkipTest("ConPTY 把 resize 当控制台事件送达,没有 SIGWINCH 打断读")


def test_T45_a_resize_inside_an_arrow_key_does_not_end_reverse_search(bin_path):
    _skip_without_sigwinch()
    raw = run(
        bin_path,
        [READY, "key:ctrl_r", wait_for("(reverse-search)"), "type:zz"]
        + SPLIT_BY_RESIZE
        + ["sleep:0.8"],
        term_size=(24, 80),
        per_key_drain=0.02,
    )
    a = TTYAssert(raw, rows=24, cols=70)
    a.assert_box_present()
    # ↑ 结束搜索、保留原输入(空)。旧版在 ESC 处就取消了搜索,`[A` 被当成输入打进框里。
    a.assert_input_echo("")


def test_T46_a_resize_inside_an_arrow_key_keeps_the_transcript_viewer_open(bin_path):
    _skip_without_sigwinch()
    raw = run(
        bin_path,
        [READY, "key:ctrl_x", "key:ctrl_o", wait_for("Showing detailed transcript")]
        + SPLIT_BY_RESIZE
        + ["sleep:0.6", "type:q", "sleep:0.6"],
        term_size=(24, 80),
        per_key_drain=0.02,
    )
    a = TTYAssert(raw, rows=24, cols=70)
    a.assert_box_present()
    # ↑ 在 viewer 里滚动,q 关掉它,输入框是空的。旧版 viewer 在 ESC 处就关了,
    # 剩下的 `[A` 和后来的 q 都打进了输入框。
    a.assert_input_echo("")
    assert raw.count(b"\x1b[?1049l") == 1, "viewer 应只关一次(q 关的)"


def test_T47_a_lone_esc_closes_the_transcript_viewer_without_another_key(bin_path):
    # 同一个改动的另一面:旧 viewer 收到 ESC 后阻塞读下一字节,单按 Esc 要等下一个键
    # 到了才退出。readKey 等满一个 ESC 等待就把它当 Esc 键。
    raw = run(
        bin_path,
        [READY, "key:ctrl_x", "key:ctrl_o", wait_for("Showing detailed transcript"),
         "raw:\\x1b", "sleep:0.8"],
        per_key_drain=0.02,
    )
    assert raw.count(b"\x1b[?1049l") == 1, "单按 Esc 后 viewer 应已关闭"
    a = TTYAssert(raw)
    a.assert_box_present()
    a.assert_input_echo("")
