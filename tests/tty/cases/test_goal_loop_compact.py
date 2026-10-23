"""TTY coverage for local goal/loop/compact slash commands.

These cases are intentionally offline: they exercise the user-visible command
surface and final input-box recovery. A case that needs a model turn talks to
the local mock below, never to a real provider.
"""

import http.server
import threading

from tty_driver import IDLE, run, submit
from asserts import TTYAssert


class _AnthropicMock(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # noqa: D401
        return

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        if b'"stream":false' in body:
            payload = b'{"content":[{"type":"text","text":"COMPACT_SUMMARY"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}'
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        sse = (
            b'data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
            b'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"done"}}\n\n'
            b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'
        )
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(sse)))
        self.end_headers()
        self.wfile.write(sse)


def _start_mock():
    server = http.server.HTTPServer(("127.0.0.1", 0), _AnthropicMock)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{server.server_port}/v1/messages"


def test_tty_goal_command_lifecycle(bin_path):
    # 每条先等上一条处理完(submit 开头的 READY)再打:提交后紧跟着打字在 POSIX 上会被
    # TCSAFLUSH 丢掉(见 tty_driver 模块文档),原先的 sleep:0.2 只是赌命令已经处理完。
    # 中间各条的标志屏上可能早有(/goal budget 也会打 `Goal [active]`),截屏时刻由最后的
    # Goodbye 决定。
    raw = run(bin_path, submit("/goal set ship tty goal", "Goal set.")
              + submit("/goal budget 42", "budget:  42 tokens")
              + submit("/goal pause", "Goal [paused]")
              + submit("/goal resume", "Goal [active]")
              + submit("/exit", "Goodbye"))
    a = TTYAssert(raw)
    a.assert_prose_contains("Goal set.")
    a.assert_prose_contains("target:  ship tty goal")
    a.assert_prose_contains("budget:  42 tokens")
    a.assert_prose_contains("Goal [paused]")
    a.assert_prose_contains("Goal [active]")
    a.assert_clean_exit()


def test_tty_loop_requires_goal_then_enables_and_stops(bin_path):
    # With an active goal and nothing queued, `/loop on` starts a continuation at
    # the next REPL turn. This case used to start in plan mode, whose loop gate
    # kept the continuation from running; with plan mode gone the continuation
    # talks to the local mock and the case also checks it stops at its limit.
    server, base_url = _start_mock()
    try:
        raw = run(bin_path, submit("/loop on 2", "Set a goal first")
                  + submit("/goal set continue tty work", "Goal set.")
                  # 两轮续跑都打 mock;`limit reached` 是续跑停下的那行。续跑是模型 turn,
                  # 其后发键先等空闲输入框(IDLE),不是 READY。
                  + submit("/loop on 2", "limit reached", 30) + [IDLE]
                  + submit("/loop off", "Loop continuation stopped.")
                  + submit("/exit", "Goodbye"), base_url=base_url)
    finally:
        server.shutdown()
    a = TTYAssert(raw)
    a.assert_prose_contains("Set a goal first")
    a.assert_prose_contains("Loop continuation: on (2 remaining)")
    a.assert_prose_contains("Goal status: active")
    a.assert_prose_contains("[loop continuation: 1 remaining]")
    a.assert_prose_contains("[loop continuation stopped: limit reached]")
    a.assert_prose_contains("Loop continuation stopped.")
    a.assert_clean_exit()


def test_tty_compact_command_recovers_input_box(bin_path):
    raw = run(bin_path, submit("/compact", "Nothing to compact"))
    a = TTYAssert(raw)
    a.assert_prose_contains("Nothing to compact")
    a.assert_box_present()
    a.assert_box_at_bottom()


def test_tty_auto_compact_event_is_visible(bin_path):
    server, base_url = _start_mock()
    try:
        raw = run(bin_path, submit("/compact-stress-test", "[compact-stress-test] injected")
                  + submit("trigger auto compact", "[auto-compacted"), base_url=base_url, env={
            "METACODES_TEST_HOOKS": "1",
            # 钉死 auto-compact 阈值(该旋钮即为测试而设):真实阈值随模型上下文表浮动
            # (隔离 HOME 初始化的 bundled 表首项是 200k 窗口,12×12KB 注入 ≈36K tokens
            # 远够不到),不钉则用例在任何平台都依赖本机模型表——假环境耦合。
            "METACODES_FORCE_COMPACT_AT": "8000",
        })
    finally:
        server.shutdown()
    a = TTYAssert(raw)
    a.assert_prose_contains("[compact-stress-test] injected large history")
    a.assert_prose_contains("[auto-compacted")
