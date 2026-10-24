"""启动动画(src/repl/tui/splash.zig + splash_player.zig)在真二进制上的 L2 证据。

动画默认开;tty_driver 为其它用例默认关(METACODES_NO_STARTUP_ANIMATION=1),本文件经
env 传 None 打开。断言的都是用户看得见的结果:原地重绘了几十帧、定格的 "Metask Lab"
字标(只用 M e t a s k L b 这几个字母)留在 banner 框正上方、任意键跳到定格帧且这个键
被吃掉、env 与 config.json 两个开关各自关得掉、窄终端不播。

ConPTY 会把输出流整屏重合成,原始字节(帧前缀、cursor-up 计数)在 Windows 上不可断言:
那两条用例在 Windows 上 SkipTest,其余只看屏幕终态,两平台都跑。
"""
import glob
import http.server
import json
import os
import threading
import time

from tty_driver import IDLE, IS_WINDOWS, READY, arrival_time, case_tmpdir, run, wait_for
from asserts import TTYAssert
from slow_mock_server import SlowMockServer, simple_text

try:
    from e2e_helpers import SkipTest
except ImportError:  # pragma: no cover - runner 同款兜底
    class SkipTest(Exception):
        pass

SIZE = (30, 100)  # splash.layoutFor(100, 30):8 行区域
REGION_ROWS = 8
FIRST_FRAME = b"\x1b[?25l\x1b[?2026h\r"
REDRAW = b"\x1b[?2026h\x1b[8A"
ON = {"METACODES_NO_STARTUP_ANIMATION": None}
PALETTE = set("MetaskLb")


def _banner_top(a):
    sc = a.final
    for r in range(sc.rows):
        line = sc.line_text(r)
        if "╭" in line and "metacodes" in line:
            return r
    raise AssertionError("no banner box on screen:\n" + "\n".join(sc.lines()))


def _rows_above_banner(a):
    sc = a.final
    return [sc.line_text(r) for r in range(_banner_top(a))]


def _assert_settled_wordmark(a):
    above = _rows_above_banner(a)
    assert len(above) >= REGION_ROWS, f"banner at row {len(above)}: no 8-row splash above it\n" + "\n".join(above)
    rows = above[-REGION_ROWS:]
    text = "\n".join(rows)
    letters = "".join(rows).replace(" ", "")
    assert set(letters) <= PALETTE, f"letters outside Metask Lab: {sorted(set(letters) - PALETTE)}\n{text}"
    assert len(letters) > 250, f"only {len(letters)} lit cells; the wordmark did not settle\n{text}"
    # FORCE_COLOR=1 → basic_16:有颜色时笔画核心按序拼写品牌名。
    assert any(w in text for w in ("Meta", "task", "kLab")), f"core does not spell the name\n{text}"
    return rows


def _assert_no_splash(a, raw):
    assert FIRST_FRAME not in raw, "splash frame bytes present"
    above = [r for r in _rows_above_banner(a) if r.strip()]
    assert not above, "rows above the banner:\n" + "\n".join(above)
    a.assert_box_present()


def test_splash_plays_and_settles_above_banner(bin_path):
    raw = run(bin_path, [IDLE], term_size=SIZE, env=ON)
    a = TTYAssert(raw, *SIZE)
    rows = _assert_settled_wordmark(a)
    a.assert_box_present()
    a.assert_box_at_bottom()
    a.assert_cursor_on_content("")
    if not IS_WINDOWS:
        assert raw.count(FIRST_FRAME) == 1
        redraws = raw.count(REDRAW)
        assert redraws >= 15, f"only {redraws} in-place redraws in ~1.5s"
        # 定格帧(最后一次重绘)把光标显示回来。
        assert b"\x1b[?25h" in raw[raw.rfind(REDRAW):]
    return rows


def test_splash_any_key_skips_to_the_same_settled_wordmark(bin_path):
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; the frame prefix to key off is not observable")
    full = TTYAssert(run(bin_path, [IDLE], term_size=SIZE, env=ON), *SIZE)
    # startup_drain=0:默认的 0.8s 启动 drain 会在按键前吃掉大半段动画。
    raw = run(bin_path, ["waitbytes:\\x1b[?25l\\x1b[?2026h\\r:30", "raw:x", IDLE],
              term_size=SIZE, env=ON, startup_drain=0)
    a = TTYAssert(raw, *SIZE)
    redraws = raw.count(REDRAW)
    assert 1 <= redraws < 10, f"{redraws} redraws: the key did not cut the animation short"
    # 定格帧与跳过时刻无关。
    assert _assert_settled_wordmark(a) == _assert_settled_wordmark(full)
    # 跳过键被动画吃掉,没有漏进输入框。
    a.assert_cursor_on_content("")
    a.assert_box_at_bottom()


def test_splash_env_switch_keeps_it_off(bin_path):
    raw = run(bin_path, [IDLE], term_size=SIZE, env={"METACODES_NO_STARTUP_ANIMATION": "1"})
    _assert_no_splash(TTYAssert(raw, *SIZE), raw)


def test_splash_config_switch_keeps_it_off(bin_path):
    home = case_tmpdir("cc-tty-splash-")
    state = os.path.join(home, "state")
    os.makedirs(state)
    with open(os.path.join(state, "config.json"), "w") as f:
        json.dump({"startupAnimation": False}, f)
    env = dict(ON, HOME=home, METACODES_HOME=state)
    raw = run(bin_path, [IDLE], term_size=SIZE, env=env)
    _assert_no_splash(TTYAssert(raw, *SIZE), raw)


def test_splash_skips_a_terminal_too_narrow_for_the_wordmark(bin_path):
    raw = run(bin_path, [IDLE], term_size=(30, 60), env=ON)
    _assert_no_splash(TTYAssert(raw, 30, 60), raw)


class _SlowModels(http.server.BaseHTTPRequestHandler):
    """`/v1/models` that answers after DELAY_S. With the probe on and no cached
    copy, App.init waits for it: a startup that is visibly slow."""

    DELAY_S = 2.5
    answered = []

    @classmethod
    def serve(cls, delay_s):
        cls.DELAY_S = delay_s
        cls.answered = []
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), cls)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server, f"http://127.0.0.1:{server.server_port}/v1/messages"

    def log_message(self, *args):  # noqa: D401
        return

    def do_GET(self):  # noqa: N802
        if self.path != "/v1/models":
            self.send_error(404)
            return
        time.sleep(self.DELAY_S)
        body = b'{"data":[{"id":"claude-sonnet-4-5","max_tokens":8192,"max_input_tokens":200000}]}'
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)
        _SlowModels.answered.append(time.monotonic())


def test_splash_plays_while_startup_waits(bin_path):
    """The splash starts before App.init and plays during it: it has settled
    while init is still waiting for `/v1/models`, and the banner follows the
    answer. (It used to start only after init returned: blank terminal for
    the whole wait, then 1.5 s more of animation.)"""
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; byte arrival times are not observable")
    server, base_url = _SlowModels.serve(2.5)
    timeline = []
    try:
        raw = run(bin_path, [IDLE], term_size=SIZE, env=dict(ON, METACODES_NO_PROBE=None),
                  base_url=base_url, timeline=timeline)
    finally:
        server.shutdown()
    a = TTYAssert(raw, *SIZE)
    _assert_settled_wordmark(a)
    a.assert_box_present()
    assert len(_SlowModels.answered) == 1, f"/v1/models answered {len(_SlowModels.answered)} times"
    answered = _SlowModels.answered[0]
    settled = arrival_time(timeline, raw, REDRAW, last=True)
    banner = arrival_time(timeline, raw, b"metacodes v")
    assert settled is not None and banner is not None
    assert settled < answered, f"the splash settled {settled - answered:.2f}s after init's wait ended"
    assert banner >= answered, "banner drawn before App.init finished"


def _assert_splash_ended_before(raw, error_text):
    """A startup error printed while the splash played: the splash's last write
    (its settled frame, cursor shown) comes before the error; or, stopped
    before its first frame, it drew nothing."""
    err = raw.find(error_text)
    assert err >= 0, "startup error not printed:\n" + raw.decode("utf-8", "replace")[-400:]
    if FIRST_FRAME not in raw:
        assert REDRAW not in raw
        return False
    last = max(raw.rfind(REDRAW), raw.find(FIRST_FRAME))
    assert last < err, "a splash frame was drawn after the error"
    assert b"\x1b[?25h" in raw[last:err], "cursor left hidden"
    return True


def test_splash_settles_before_an_init_error(bin_path):
    """App.init itself fails while the splash plays (a missing --plugin-dir)."""
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; the frame prefix to key off is not observable")
    missing = os.path.join(case_tmpdir("cc-tty-splash-"), "no-such-plugin")
    raw = run(bin_path, ["sleep:3"], term_size=SIZE, env=ON, extra_args=["--plugin-dir", missing])
    _assert_splash_ended_before(raw, b"InvalidPackageRoot")


def test_splash_is_cut_short_by_a_startup_error_after_init(bin_path):
    """`--resume` of a session whose transcript cannot be loaded fails after
    App.init, which a slow `/v1/models` keeps busy for 0.6 s: the splash has
    drawn frames by then, is settled at once, and the error follows it."""
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; the frame prefix to key off is not observable")
    home = case_tmpdir("cc-tty-splash-resume-")
    cwd = case_tmpdir("cc-tty-splash-resume-cwd-")
    env = {"HOME": home, "METACODES_HOME": os.path.join(home, ".metacodes")}
    with SlowMockServer([simple_text("SEEDED")]) as srv:
        run(bin_path, [READY, "type:hello", "key:enter", wait_for("SEEDED"), IDLE],
            env=env, cwd=cwd, base_url=srv.url)
    (transcript,) = glob.glob(os.path.join(env["METACODES_HOME"], "projects", "*", "*", "transcript.jsonl"))
    sid = os.path.basename(os.path.dirname(transcript))
    # A first-class PDF block, withdrawn: this build refuses to resume it.
    with open(transcript, "a", encoding="utf-8") as f:
        f.write(json.dumps({"role": "user", "blocks": [{"type": "document", "media_type": "application/pdf",
                                                         "title": "r.pdf", "pages": 1, "data": "JVBERi0xLjcK"}]}) + "\n")

    server, base_url = _SlowModels.serve(0.6)
    try:
        raw = run(bin_path, ["sleep:4"], term_size=SIZE, cwd=cwd,
                  env=dict(env, METACODES_NO_STARTUP_ANIMATION=None, METACODES_NO_PROBE=None),
                  base_url=base_url, extra_args=["--resume", sid])
    finally:
        server.shutdown()
    assert _assert_splash_ended_before(raw, b"cannot resume session"), "the splash drew nothing in 0.6 s"
    redraws = raw.count(REDRAW)
    # Settled early: far fewer than the ~45 frames a full 1.5 s play draws.
    assert redraws < 35, f"{redraws} redraws: not cut short"



def test_splash_is_cut_short_by_a_repl_setup_error(bin_path):
    """The REPL refuses to start (a malformed METACODES_EVAL_METADATA) before
    its banner, while the splash still plays (App.init kept busy 0.6 s): the
    splash is settled first and the error follows it."""
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; the frame prefix to key off is not observable")
    server, base_url = _SlowModels.serve(0.6)
    try:
        raw = run(bin_path, ["sleep:4"], term_size=SIZE, base_url=base_url,
                  env=dict(ON, METACODES_NO_PROBE=None, METACODES_EVAL_METADATA="{not json"))
    finally:
        server.shutdown()
    assert _assert_splash_ended_before(raw, b"InsecureEvaluationMetadataChannel"), "the splash drew nothing in 0.6 s"
