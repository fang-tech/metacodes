"""MCP servers connect in the background of the interactive REPL.

  - The prompt is up while a slow server is still starting; the footer says
    so (`connecting to MCP servers (0/1)`).
  - A message sent before the server has answered waits for it (the spinner
    reads `Connecting to MCP servers`), and the request it sends lists the
    server's tools: what a provider sees never depends on the timing.
  - `/mcp` reports a server that is still connecting.
  - Ctrl+C twice at the prompt leaves at once, without waiting the server out.

The server is the test mock behind a shell that sleeps first, the shape of a
slow `npx` start.
"""
import json
import os
import time

from tty_driver import run, READY, IDLE, wait_for, case_tmpdir
from asserts import TTYAssert
from slow_mock_server import SlowMockServer, simple_text
from e2e_helpers import SkipTest

ZIG_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
MOCK_MCP = os.path.join(ZIG_ROOT, "zig-out", "bin", "mock_mcp_server")


def _home_with_slow_server(seconds):
    if not os.access(MOCK_MCP, os.X_OK):
        raise SkipTest("no mock_mcp_server (zig build test:harness first)")
    home = case_tmpdir("cc-tty-mcp-home-")
    os.makedirs(os.path.join(home, ".metacodes"), exist_ok=True)
    script = f"sleep {seconds}; exec '{MOCK_MCP}'"
    with open(os.path.join(home, ".metacodes", "config.json"), "w") as f:
        json.dump({"mcpServers": {"slow": {"command": "/bin/sh", "args": ["-c", script]}}}, f)
    return {"HOME": home}


CONNECTING = "connecting to MCP servers (0/1)"


def test_prompt_is_up_while_a_server_connects_and_the_first_request_waits_for_it(bin_path):
    env = _home_with_slow_server(6)
    with SlowMockServer([simple_text("MCP_JOINED_REPLY")]) as srv:
        raw = run(bin_path, [READY, wait_for(CONNECTING, 3), "type:hello", "key:enter",
                             wait_for("Connecting to MCP servers", 5),
                             wait_for("MCP_JOINED_REPLY", 20), IDLE],
                  env=env, base_url=srv.url, term_size=(24, 100))
    a = TTYAssert(raw, rows=24, cols=100)
    if not a.screens_with(CONNECTING):
        a._fail("the footer should say the server is connecting while the prompt is up")
    if b"Connecting to MCP servers" not in raw:
        a._fail("a message sent before the server answered should wait for it on the spinner")
    assert len(srv.requests) == 1, f"expected one request, got {len(srv.requests)}"
    assert b"mcp__slow__echo" in srv.requests[0], "the first request should list the MCP server's tools"
    # Once connected, the footer has nothing left to say about MCP.
    footer = a.final.line_text(a.footer_row())
    if "MCP" in footer:
        a._fail(f"the footer should drop the MCP notice once the server is connected: {footer!r}")


def test_esc_while_waiting_for_a_server_does_not_start_the_turn(bin_path):
    env = _home_with_slow_server(30)
    with SlowMockServer([simple_text("SHOULD_NOT_REACH")]) as srv:
        raw = run(bin_path, [READY, wait_for(CONNECTING, 3), "type:hello", "key:enter",
                             wait_for("Connecting to MCP servers", 5), "key:esc",
                             wait_for("Interrupted", 5), READY],
                  env=env, base_url=srv.url, term_size=(24, 100))
    a = TTYAssert(raw, rows=24, cols=100)
    if a.final.find_last_row("Interrupted · What should metacodes do instead?") is None:
        a._fail("Esc while the turn waits for MCP servers should interrupt it")
    assert not srv.requests, "an interrupted wait must not send a request"
    # The server is still starting, and the footer still says so.
    if a.final.find_last_row(CONNECTING) is None:
        a._fail("the servers keep connecting after the wait is interrupted")


def test_mcp_reports_a_server_that_is_still_connecting(bin_path):
    env = _home_with_slow_server(8)
    raw = run(bin_path, [READY, wait_for(CONNECTING, 3), "type:/mcp", "key:enter", wait_for("connecting…", 5)],
              env=env, term_size=(24, 100))
    a = TTYAssert(raw, rows=24, cols=100)
    if a.final.find_last_row("MCP servers (1), connecting:") is None:
        a._fail("/mcp should list the servers while they connect")
    if a.final.find_last_row("slow  connecting…") is None:
        a._fail("/mcp should show the slow server as connecting")


def test_ctrl_c_twice_leaves_while_a_server_connects(bin_path):
    env = _home_with_slow_server(60)
    started = time.monotonic()
    raw = run(bin_path, [READY, wait_for(CONNECTING, 3), "key:ctrl_c", "key:ctrl_c"], env=env, term_size=(24, 100))
    elapsed = time.monotonic() - started
    a = TTYAssert(raw, rows=24, cols=100)
    a.assert_clean_exit()
    # The server would take a minute; leaving must not wait for it.
    if elapsed > 12:
        a._fail(f"leaving took {elapsed:.1f}s while the MCP server was still starting")
