"""/login (issue #33), aligned with Claude Code 2.1.278's Login dialog.

`/login` opens a bottom pane listing the providers this installation can sign
in to; Esc leaves `⎿  Login interrupted` under the echo. A provider name starts
its sign-in directly; a typo'd flag fails closed before anything starts. The
flow itself needs an authorization server: the kernel flows are covered against
mock servers by tests/component/provider_oauth_login_test.zig, and the dialog's
states by the unit tests in src/repl/dialogs.zig.
"""
from tty_driver import run, submit, READY, wait_for
from asserts import TTYAssert


def test_login_opens_the_provider_list_and_esc_interrupts(bin_path):
    raw = run(bin_path, [READY, "type:/login", "key:enter", wait_for("Select a provider", 10),
                         "key:esc", wait_for("Login interrupted", 10)])
    a = TTYAssert(raw)
    listed = a.screens_with("1. Metask")
    if not listed:
        a._fail("the Login pane should list Metask")
    echo = a.final.find_row("❯ /login")
    if echo is None:
        a._fail("the /login echo is missing")
    a.assert_line_contains(echo + 1, "⎿  Login interrupted")
    if a.final.find_row("Select a provider") is not None:
        a._fail("the Login pane should be erased after Esc")
    a.assert_box_present()
    a.assert_box_at_bottom()


def test_login_unknown_flag_fails_closed(bin_path):
    # 与 CLI 一致:`--device-cod` 这类 typo 不能静默丢掉后启动一个用户没要的流程。
    raw = run(bin_path, submit("/login relay --device-cod", "Usage: /login"))
    a = TTYAssert(raw)
    a.assert_prose_contains("Unknown /login argument '--device-cod'")
    a.assert_prose_contains("Usage: /login")
    assert b"Select a provider" not in raw, "a refused /login must not open the dialog"


def test_login_unknown_provider(bin_path):
    raw = run(bin_path, submit("/login nosuch", "Unknown provider"))
    a = TTYAssert(raw)
    a.assert_prose_contains("Unknown provider 'nosuch'")
    assert b"Select a provider" not in raw
