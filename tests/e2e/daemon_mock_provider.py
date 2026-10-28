#!/usr/bin/env python3
"""Loopback stand-in for the Anthropic Messages API, for the daemon e2e scripts.

Every POST is answered with one `end_turn` stream whose text is DAEMON_OK. A
request body containing SLOWGEN is held for 2 s first, so a script can
interrupt a run while it is generating. Requests are served concurrently (one
daemon may drive several sessions at once). Listens on 127.0.0.1 only, on a
port the kernel picks, and writes the base URL to <url-file> once listening.

Two markers make the model call a tool, so a script can drive UI requests
(tests/e2e/frontend_capabilities_e2e.py): when the newest message is the
user's text and contains CAPS_ASK, the answer is one AskUserQuestion call;
CAPS_WRITE:<path> is one Write of <path>. The tool's result, the next
request, is answered with DAEMON_OK as usual.
"""

from __future__ import annotations

import http.server
import json
import re
import sys
import time
from pathlib import Path

SSE = (
    b'data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x",'
    b'"usage":{"input_tokens":1,"output_tokens":0}}}\n\n'
    b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
    b'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"DAEMON_OK"}}\n\n'
    b'data: {"type":"content_block_stop","index":0}\n\n'
    b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}\n\n'
    b'data: {"type":"message_stop"}\n\n'
)

ASK_INPUT = {
    "questions": [
        {
            "question": "Favorite color?",
            "header": "Color",
            "options": [
                {"label": "Red", "description": "r"},
                {"label": "Blue", "description": "b"},
            ],
            "multiSelect": False,
        }
    ]
}

WRITE_MARKER = re.compile(r"CAPS_WRITE:(\S+)")


def tool_use_sse(name: str, tool_input: dict) -> bytes:
    """One assistant turn that calls `name` with `tool_input`."""
    partial = json.dumps(tool_input, separators=(",", ":"))
    events = [
        {"type": "message_start", "message": {"id": "m_tool", "role": "assistant", "model": "x",
                                               "usage": {"input_tokens": 1, "output_tokens": 0}}},
        {"type": "content_block_start", "index": 0,
         "content_block": {"type": "tool_use", "id": "tu_" + name.lower(), "name": name, "input": {}}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": partial}},
        {"type": "content_block_stop", "index": 0},
        {"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 3}},
        {"type": "message_stop"},
    ]
    return b"".join(b"data: " + json.dumps(event, separators=(",", ":")).encode() + b"\n\n" for event in events)


def newest_user_text(body: bytes) -> str:
    """The newest message's text when it is the user's own words, else ""."""
    try:
        messages = json.loads(body).get("messages") or []
    except ValueError:
        return ""
    if not messages or messages[-1].get("role") != "user":
        return ""
    content = messages[-1].get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list) or any(block.get("type") == "tool_result" for block in content):
        return ""
    return " ".join(block.get("text", "") for block in content if block.get("type") == "text")


def answer(body: bytes) -> bytes:
    text = newest_user_text(body)
    if "CAPS_ASK" in text:
        return tool_use_sse("AskUserQuestion", ASK_INPUT)
    write = WRITE_MARKER.search(text)
    if write:
        return tool_use_sse("Write", {"file_path": write.group(1), "content": "capabilities e2e\n"})
    return SSE


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if b"SLOWGEN" in body:
            time.sleep(2.0)
        stream = answer(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(stream)))
        self.end_headers()
        self.wfile.write(stream)

    def log_message(self, _format: str, *args: object) -> None:
        del args


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: daemon_mock_provider.py <url-file>")
    url_file = Path(sys.argv[1])
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    pending = url_file.with_name(url_file.name + ".tmp")
    pending.write_text(f"http://127.0.0.1:{server.server_port}/v1/messages\n", encoding="utf-8")
    pending.replace(url_file)  # readers never see a partial line
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
