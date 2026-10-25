#!/usr/bin/env python3
"""Capture one Anthropic-compatible request and answer it with one `end_turn` stream.

The answer is a complete stream, the one tests/e2e/daemon_mock_provider.py
sends. A bare `message_stop` carries no stop reason: the agent loop reads that
as an incomplete stream and resends the request (`isSilentRetryFailure`), and
this server answers only once, so the resend ran into connect retries against
a closed port. process_dag_resume_smoke.sh took 2 minutes on the Linux runner
and 6 on macOS with that answer.
"""

from __future__ import annotations

import http.server
import sys
from pathlib import Path


SSE = (
    b'data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x",'
    b'"usage":{"input_tokens":1,"output_tokens":0}}}\n\n'
    b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
    b'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"CAPTURED"}}\n\n'
    b'data: {"type":"content_block_stop","index":0}\n\n'
    b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'
    b'data: {"type":"message_stop"}\n\n'
)


class Handler(http.server.BaseHTTPRequestHandler):
    request_path: Path

    def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
        length = int(self.headers.get("Content-Length", "0"))
        self.request_path.write_bytes(self.rfile.read(length))
        body = SSE
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *args: object) -> None:
        del args


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: capture_sse_once.py <request.json> <url-file>")
    Handler.request_path = Path(sys.argv[1])
    url_file = Path(sys.argv[2])
    with http.server.HTTPServer(("127.0.0.1", 0), Handler) as server:
        url_file.write_text(
            f"http://127.0.0.1:{server.server_port}/v1/messages\n", encoding="utf-8"
        )
        server.handle_request()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
