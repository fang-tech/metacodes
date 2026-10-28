"""Screen.resize 单测(离线,不起二进制,bin_path 未用)。

resize 回放(TTYAssert(resizes=))的断言全靠这个模型:它得像终端一样对待已显示的行,
否则"修好了"和"没修好"在回放里长得一样。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from screen import Screen  # noqa: E402


def _screen(rows, cols, data, autowrap=False):
    sc = Screen(rows, cols, autowrap=autowrap)
    sc.feed(data)
    return sc


def _lines(sc):
    return [sc.line_text(r) for r in range(sc.rows)]


def test_narrowing_rewraps_a_line_and_widening_joins_it_back(bin_path):
    sc = _screen(4, 12, b"0123456789\r\nab")
    sc.resize(4, 6)
    assert _lines(sc) == ["012345", "6789", "ab", ""]
    assert sc.wrapped[:3] == [False, True, False]
    assert sc.cursor() == (2, 2), "光标跟着它那一格走"
    sc.resize(4, 12)
    assert _lines(sc) == ["0123456789", "ab", "", ""]
    assert sc.cursor() == (1, 2)


def test_an_erased_row_is_a_line_of_its_own(bin_path):
    # 重排出来的续行被 EL 2 擦掉重写后,不再属于上一行:变宽时不合回去(xterm.js 同此)。
    sc = _screen(4, 12, b"0123456789\r\n")
    sc.resize(4, 6)
    sc.feed(b"\x1b[2A\r\x1b[1B\x1b[2Kxy")
    sc.resize(4, 12)
    assert _lines(sc)[:2] == ["012345", "xy"]


def test_a_full_screen_stays_anchored_at_the_bottom(bin_path):
    # 满屏时变窄:多出的行把顶上的推进 scrollback;变宽再从 scrollback 拉回来。
    sc = _screen(3, 8, b"top\r\nmiddle\r\n01234567")
    sc.resize(3, 4)
    assert _lines(sc) == ["le", "0123", "4567"]
    assert sc.cursor() == (2, 3), "写满一行的光标停在行尾等折行"
    assert [cells for cells, _ in sc.history][0][0].ch == "t"
    sc.resize(3, 8)
    assert _lines(sc) == ["top", "middle", "01234567"]
    assert sc.history == []


def test_a_clipping_terminal_truncates_and_keeps_the_rows(bin_path):
    sc = _screen(3, 12, b"0123456789\r\nab\x1b[8C")
    sc.resize(3, 6, reflow=False)
    assert _lines(sc) == ["012345", "ab", ""]
    assert sc.cursor() == (1, 5), "光标列夹到行内"
    sc.resize(3, 12, reflow=False)
    assert _lines(sc) == ["012345", "ab", ""], "裁掉的字不会回来"


def test_autowrap_marks_the_continuation_row_wrapped(bin_path):
    # 比终端宽的行在画的那一刻就折行;resize 时它和上一行是同一条逻辑行。
    sc = _screen(3, 6, b"0123456789", autowrap=True)
    assert _lines(sc)[:2] == ["012345", "6789"]
    assert sc.wrapped[:2] == [False, True]
    sc.resize(3, 12)
    assert _lines(sc)[:2] == ["0123456789", ""]
