"""#330: the turn phase owns every widget it opens.

A reply and the read after it share one fixed region. Before #298 an agent list
left open by a reply swallowed the next prompt's typing; #298 reset a list of
fields at every boundary, and #330 moved that state into the phase's payload,
which a phase change replaces wholesale. These cases drive the real binary
through the reply -> read boundary with widgets open and assert the next prompt
starts clean. Offline: the reply comes from the local slow mock server.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import READY, WAIT_S, run, submit, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402

# The idle footer once fake agents exist (drawFooter appends the switcher entry).
IDLE_WITH_AGENTS = f"waitline:⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents:{WAIT_S}"
IDLE = f"waitline:⏵⏵ bypass permissions on (shift+tab to cycle):{WAIT_S}"


def _screen_text(raw, rows, cols):
    a = TTYAssert(raw, rows=rows, cols=cols)
    return a, "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def _frame_text(sc):
    return "\n".join(sc.line_text(r) for r in range(sc.rows))


def test_agent_list_opened_in_a_reply_does_not_swallow_the_next_prompt(bin_path):
    from slow_mock_server import SlowMockServer, slow_text_then_end

    rows, cols = 34, 100
    with SlowMockServer([slow_text_then_end(n_chunks=10, delay=0.3)]) as srv:
        raw = run(
            bin_path,
            submit("/agent-test-multi", "Running 2 Explore agents")
            + [READY, "type:go", "key:enter", wait_for("esc to interrupt"),
               # `↓ to manage`: the reply's own switcher, opened mid-stream.
               "key:down", wait_for("↑/↓ to select"),
               # The reply ends with the list still open; the idle footer is the
               # sign the next read has its own region.
               "sleep:10", IDLE_WITH_AGENTS,
               "type:hello", wait_for("❯ hello")],
            term_size=(rows, cols),
            base_url=srv.url,
            startup_drain=0.8,
            per_key_drain=0.08,
        )
    a, text = _screen_text(raw, rows, cols)
    opened = [sc for sc in a.frame_screens
              if "↑/↓ to select" in _frame_text(sc) and "esc to interrupt" in _frame_text(sc)]
    assert opened, "the reply never showed its agent list; the case did not reach the boundary:\n" + text
    assert "❯ hello" in text, "the next prompt's typing was swallowed (#298):\n" + text
    assert "↑/↓ to select" not in text, "the reply's agent list reached the next prompt:\n" + text


def test_help_opened_in_a_reply_is_closed_at_the_next_prompt(bin_path):
    from slow_mock_server import SlowMockServer, slow_text_then_end

    rows, cols = 24, 80
    with SlowMockServer([slow_text_then_end(n_chunks=10, delay=0.3)]) as srv:
        raw = run(
            bin_path,
            [READY, "type:go", "key:enter", wait_for("esc to interrupt"),
             "type:?", wait_for("ctrl + o to choose a model"),
             # A help panel left open would replace this footer line, so the
             # wait itself fails if the reply's help reached the prompt.
             "sleep:10", IDLE],
            term_size=(rows, cols),
            base_url=srv.url,
            startup_drain=0.8,
            per_key_drain=0.08,
        )
    a, text = _screen_text(raw, rows, cols)
    # The help panel takes the footer line (where `esc to interrupt` lives), so
    # a frame showing it is the reply's: `?` is typed only after the reply began.
    shown = [sc for sc in a.frame_screens if "ctrl + o to choose a model" in _frame_text(sc)]
    assert shown, "help never opened during the reply; the case did not reach the boundary:\n" + text
    assert "tok9" in text, "the reply has not finished; wrong moment:\n" + text
    assert "ctrl + o to choose a model" not in text, "the reply's help reached the next prompt:\n" + text
