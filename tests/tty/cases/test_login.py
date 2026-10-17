"""/login(issue #33):无参打印用法;错拼的 flag fail-closed(不启动流程)。
流程本身不在 TTY 里跑——它需要一个授权服务器;内核流程由
tests/component/provider_oauth_login_test.zig 对 mock 服务器覆盖。"""
from tty_driver import run, submit
from asserts import TTYAssert


def test_login_usage(bin_path):
    raw = run(bin_path, submit("/login", "usage: /login"))
    a = TTYAssert(raw)
    a.assert_prose_contains("usage: /login")
    a.assert_box_present()
    a.assert_box_at_bottom()


def test_login_unknown_flag_fails_closed(bin_path):
    # 与 CLI 一致:`--device-cod` 这类 typo 不能静默丢掉后启动一个用户没要的流程。
    # 先打错误行、再打用法(handleLogin),等最后打的那行。
    raw = run(bin_path, submit("/login relay --device-cod", "usage: /login"))
    a = TTYAssert(raw)
    a.assert_prose_contains("unknown /login argument")
    a.assert_prose_contains("usage: /login")
