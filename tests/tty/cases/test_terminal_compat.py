"""终端兼容性:Kitty 协议按 TERM_PROGRAM 分流 + Apple Terminal backslash 换行。

背景:cc-zig 曾无条件发 Kitty 协议(\x1b[>1u),Apple Terminal 不支持 → honor 后发回
乱码/键失常。改成按终端 gate(对齐真 cc terminal.ts:167):认得出的直接发,deny-list
(Apple Terminal 等)不发,认不出的启动时探测(test_keyboard_probe.py)。这些 case 验
cc-zig **发什么字节**(pty 能测);真终端如何响应需用户真机抓。
"""
import sys

from tty_driver import run
from asserts import TTYAssert
from screen import Screen

try:
    from e2e_helpers import SkipTest
except Exception:  # noqa: BLE001
    class SkipTest(Exception):
        pass


def _skip_if_conpty():
    """Windows/ConPTY 重合成输出流:应用发出的私有模式(?2004h、kitty >1u/=4;2m)被
    conhost 消费不透传,此层观测不到"发了什么字节"——这些断言是 POSIX-pty 专属。
    (Windows 上 paste/键协议功能本身由 console 模式 + VT input 提供,另有用例覆盖。)"""
    if sys.platform == "win32":
        raise SkipTest("ConPTY 不透传应用私有模式序列,字节级断言仅 POSIX-pty 可测")


def test_apple_terminal_no_kitty(bin_path):
    _skip_if_conpty()
    # Apple Terminal:不发 Kitty 协议(\x1b[>1u / >4;2m),但 bracketed paste 仍发。
    raw = run(bin_path, ["sleep:0.8"], env={"TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"})
    assert b"\x1b[>1u" not in raw, "Apple Terminal 不应发 Kitty enable \\x1b[>1u"
    assert b"\x1b[>4;2m" not in raw, "Apple Terminal 不应发 modifyOtherKeys level 2"
    assert b"\x1b[?2004h" in raw, "bracketed paste 应始终发(兼容性好)"


def test_warp_sends_kitty(bin_path):
    _skip_if_conpty()
    # Warp(白名单):发 Kitty enable —— 实测其默认未开,需 cc-zig 主动发才能 Shift+Enter 换行。
    raw = run(bin_path, ["sleep:0.8"], env={"TERM_PROGRAM": "WarpTerminal", "TERM": "xterm-256color"})
    assert b"\x1b[>1u" in raw, "Warp 应发 Kitty enable \\x1b[>1u"


def test_iterm_sends_kitty(bin_path):
    _skip_if_conpty()
    raw = run(bin_path, ["sleep:0.8"], env={"TERM_PROGRAM": "iTerm.app", "TERM": "xterm-256color"})
    assert b"\x1b[>1u" in raw, "iTerm 应发 Kitty enable"


def test_sigstop_sigcont_reapplies_terminal_modes(bin_path):
    _skip_if_conpty()
    # A stopped foreground process can come back with shell-modified termios
    # and private-mode flags.  The SIGCONT path must re-emit the full intended
    # state, including Kitty/modifyOtherKeys and bracketed paste.
    raw = run(
        bin_path,
        ["sleep:0.8", "signal:stopcont", "sleep:0.8"],
        env={"TERM_PROGRAM": "WarpTerminal", "TERM": "xterm-256color"},
    )
    assert raw.count(b"\x1b[>1u") >= 2, "SIGCONT should re-enable Kitty keyboard"
    assert raw.count(b"\x1b[>4;2m") >= 2, "SIGCONT should re-enable modifyOtherKeys"
    assert raw.count(b"\x1b[?2004h") >= 2, "SIGCONT should re-enable bracketed paste"


def test_sigcont_restores_raw_input_after_shell_cooked_the_tty(bin_path):
    _skip_if_conpty()
    # While stopped, the tty goes back to canonical mode (no echo). Without the
    # SIGCONT reconciliation the typed bytes wait in the line discipline for a
    # newline and the input box stays empty.
    raw = run(
        bin_path,
        ["sleep:0.8", "signal:stopcont:cooked", "sleep:0.5", "type:ab", "sleep:0.6"],
    )
    a = TTYAssert(raw)
    a.assert_input_echo("ab")
    a.assert_box_at_bottom()


def test_apple_terminal_backslash_newline_no_exit(bin_path):
    # Apple Terminal 无 Kitty 协议,Shift+Enter 发裸 \r 无法区分 → 换行靠 backslash+return:
    # 行尾 \ + 回车 → 删 \ 插 \n,留在输入框(不提交、不退出)。用 raw:\x0d 发裸回车。
    raw = run(
        bin_path,
        ["sleep:0.8", "type:abc\\", "raw:\\x0d", "sleep:0.3"],
        env={"TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"},
    )
    assert b"Goodbye" not in raw, "backslash 续行不应退出程序"
    a = TTYAssert(raw)
    a.assert_box_height(2)  # 换行后输入框两行(abc + 空续行)
    sc = Screen(24, 80)
    sc.feed(raw)
    top = a.box_top_row()
    a.assert_line_contains(top + 1, "abc")  # 第一行是 abc(\ 已删)


def _multiline_footer(bin_path, term_program):
    # 组多行(backslash 续行)后抓 footer 文案。Apple 用裸回车续行,Kitty 终端用 shift_enter。
    if term_program == "Apple_Terminal":
        events = ["sleep:0.8", "type:a\\", "raw:\\x0d", "type:b", "sleep:0.3"]
    else:
        events = ["sleep:0.8", "type:a", "key:shift_enter", "type:b", "sleep:0.3"]
    raw = run(bin_path, events, env={"TERM_PROGRAM": term_program, "TERM": "xterm-256color"})
    sc = Screen(24, 80)
    sc.feed(raw)
    return "\n".join(sc.line_text(r) for r in range(sc.rows))


def test_newline_hint_per_terminal(bin_path):
    # 多行编辑时 footer 显当前终端的换行方式(对齐真 cc getNewlineInstructions,按 cc-zig 能力)。
    apple = _multiline_footer(bin_path, "Apple_Terminal")
    assert "\\ + " in apple and "for newline" in apple, \
        f"Apple Terminal 应显 backslash 换行提示,实际 footer 区:{apple!r}"
    assert "shift + " not in apple, "Apple Terminal 不应显 shift+⏎(它区分不了,会误导)"

    warp = _multiline_footer(bin_path, "WarpTerminal")
    assert "shift + " in warp and "for newline" in warp, \
        f"Warp(白名单)应显 shift+⏎ 换行提示,实际:{warp!r}"



def test_colorless_conpty_keeps_unicode_frame(bin_path):
    """PowerShell often has no TERM; color fallback must keep the Unicode TUI glyphs."""
    raw = run(
        bin_path,
        ["sleep:0.8"],
        env={"FORCE_COLOR": None, "TERM": None, "COLORTERM": None, "NO_COLOR": None},
    )
    assert "╭".encode("utf-8") in raw, "no-color TTY must keep the banner's rounded top corner"
    assert "╰".encode("utf-8") in raw, "no-color TTY must keep the banner's rounded bottom corner"
    a = TTYAssert(raw)
    if a.box_top_row() is None or a.box_bottom_row() is None:
        a._fail("no-color TTY must draw the input box with full-width ─ rules")
    assert b"+-" not in raw, "ASCII box is reserved for explicit /theme mono"
