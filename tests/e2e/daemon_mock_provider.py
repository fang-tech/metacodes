#!/usr/bin/env python3
"""Loopback stand-in for the Anthropic Messages API, for the daemon e2e scripts.

Every POST is answered with one `end_turn` stream whose text is DAEMON_OK. A
request body containing SLOWGEN is held for 2 s first, so a script can
interrupt a run while it is generating. Requests are served concurrently (one
daemon may drive several sessions at once). Listens on 127.0.0.1 only, on a
port the kernel picks, and writes the base URL to <url-file> once listening.
"""

from __future__ import annotations

import http.server
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


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if b"SLOWGEN" in body:
            time.sleep(2.0)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(SSE)))
        self.end_headers()
        self.wfile.write(SSE)

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
