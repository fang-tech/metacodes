#!/usr/bin/env python3
"""Zero-network L2: a lesson written in attempt 1 of a chain reaches attempt 2.

`run_chained` (scripts/eval/chained_runner.py) drives the real native E2E
harness (`tests/e2e/run_e2e.sh` + `lib.sh`) on check-gate v3's `d1_cg3_cron`
task, whose scenario initializes a git repository in every attempt's fresh
workspace. Both arms are `#!/bin/sh` wrappers around the binary under test
with the learning-turn configuration of `evals/experiments/learning-turn-v1.md`
(`--host-check <cmd> --check-gate-observe`, then `--learning-turn-observe` or
`--learning-turn`), pointed at a scripted loopback provider instead of a
model. Real TinyKG daemon, real store export and import between attempts,
the real durable budget journal; no request leaves the machine.

The scripted model writes a file and ends its turn; the pinned check fails;
when the host's learning turn asks, the model files one lesson with the
header the host bound to that verdict. The smoke then checks what the
provider received:

* treatment: attempt 1's lesson is accepted, attempt 2 imports exactly the
  store attempt 1 exported, and attempt 2's first request carries the lesson
  (the same-task lessons note); its distill message lists it as stored;
* baseline (observe): no lesson is written, so none is carried;
* control: the same chains with the runner's domain removed - what
  `run-chained` did before `METACODES_KG_DOMAIN`. Each attempt's git root
  is a new run directory, so the binary derives a new domain, and attempt 2
  recalls nothing although the same store was carried. The control proves
  the first check can fail.

The run directories the harness creates under `tests/e2e/runs/` and the
temporary trees are removed unless `--keep` is given.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
from scripts.eval import chained_runner  # noqa: E402
from scripts.eval.model import ValidationError, load_json, load_rollouts, validate_suite  # noqa: E402
from scripts.eval.workbuddy.mock_provider import (  # noqa: E402
    _LoopbackServer,
    _final_sse,
    _tool_sse,
)

TASK = "d1_cg3_cron"
SUITE = REPO_ROOT / "evals/suites/check-gate-v3.json"
MODEL_PROVIDER = "anthropic"
MODEL_ID = "claude-sonnet-4-20250514"
CREDENTIAL = "metacodes-chained-memory-smoke-only"
LEARNING_MARKER = "[learning turn]"
LESSON_BODY = (
    "chained-memory-smoke-lesson: parse the day-of-month and day-of-week fields "
    "as a union when both are restricted"
)
WRITE_ID = "chain-smoke-write"
LESSON_ID = "chain-smoke-lesson"
HEADER = re.compile(r"lesson-v1 verdict=[a-z]+ task=\S+ run=\S+")
MAX_REQUEST_BYTES = 16 * 1024 * 1024
ARMS = ("baseline", "candidate")


def _blocks(message: Mapping[str, Any]) -> List[Mapping[str, Any]]:
    content = message.get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [block for block in content if isinstance(block, Mapping)]
    return []


def _text(message: Mapping[str, Any]) -> str:
    return "\n".join(
        str(block.get("text", "")) for block in _blocks(message) if block.get("type") == "text"
    )


def _tool_results(message: Mapping[str, Any]) -> Dict[str, bool]:
    """tool_use_id -> whether the host reported the call as an error."""
    return {
        str(block.get("tool_use_id")): block.get("is_error") is True
        for block in _blocks(message)
        if block.get("type") == "tool_result"
    }


class ScriptedProvider:
    """A loopback Anthropic-SSE provider. Each arm's wrapper uses its own
    base-URL path, so every request is attributed to an arm without any
    label reaching the session."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: List[Dict[str, Any]] = []
        self.failures: List[str] = []

    def respond(self, arm: str, request: Mapping[str, Any], body: bytes) -> bytes:
        messages = request.get("messages")
        if not isinstance(messages, list) or not messages:
            raise ValueError("request has no messages")
        last = messages[-1]
        text = _text(last)
        results = _tool_results(last)
        number = len(self.requests) + 1
        row: Dict[str, Any] = {
            "arm": arm,
            "carries_lesson": LESSON_BODY.encode("utf-8") in body,
        }
        if LEARNING_MARKER + " reconcile" in text:
            row["kind"] = "reconcile"
            payload = _final_sse(number, "nothing to reconcile")
        elif LEARNING_MARKER + " distill" in text:
            row["kind"] = "distill"
            header = HEADER.search(text)
            if header is None:
                raise ValueError("distill message names no lesson header")
            lesson = (
                f"{header.group(0)}\n"
                "holds_when: the cron specification restricts both day fields\n"
                "uncertain: whether the hidden cases cover other field combinations\n"
                f"lesson: {LESSON_BODY}"
            )
            payload = _tool_sse(number, LESSON_ID, "KgRemember", {"kind": "lesson", "text": lesson})
        elif LESSON_ID in results:
            row["kind"] = "after_lesson"
            # KgRemember refuses a lesson whose header the host did not bind.
            row["lesson_accepted"] = not results[LESSON_ID]
            payload = _final_sse(number, "recorded one lesson")
        elif WRITE_ID in results:
            row["kind"] = "after_write"
            payload = _final_sse(number, "done")
        elif results:
            row["kind"] = "other_result"
            payload = _final_sse(number, "ok")
        elif not request.get("tools"):
            row["kind"] = "no_tools"
            payload = _final_sse(number, "ok")
        else:
            row["kind"] = "first"
            payload = _tool_sse(
                number,
                WRITE_ID,
                "Write",
                {"file_path": "notes.txt", "content": "first draft\n"},
            )
        self.requests.append(row)
        return payload


def _serve(provider: ScriptedProvider) -> _LoopbackServer:
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
            match = re.fullmatch(r"/(baseline|candidate)/v1/messages", self.path)
            if match is None:
                self.send_error(404)
                return
            if self.headers.get("Authorization") != f"Bearer {CREDENTIAL}":
                self.send_error(401)
                return
            length = int(self.headers.get("Content-Length", "0") or "0")
            if length <= 0 or length > MAX_REQUEST_BYTES:
                self.send_error(413)
                return
            body = self.rfile.read(length)
            try:
                request = json.loads(body)
                with provider.lock:
                    payload = provider.respond(match.group(1), request, body)
            except (ValueError, UnicodeError) as exc:
                with provider.lock:
                    provider.failures.append(str(exc))
                self.send_error(409, str(exc))
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, _format: str, *_args: object) -> None:
            return

    server = _LoopbackServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
    return server


def _wrapper(
    path: Path, binary: Path, tinykg: Path, tinykgd: Path, url: str, learning_flag: str
) -> None:
    # The binary under test is a build artifact, not an installed layout, so
    # the TinyKG pair it would find next to itself is named explicitly.
    path.write_text(
        "#!/bin/sh\n"
        f"METACODES_KG_BIN={shlex.quote(str(tinykg))} "
        f"METACODES_KGD_BIN={shlex.quote(str(tinykgd))} METACODES_NO_PROBE=1 \\\n"
        f"  exec {shlex.quote(str(binary))} --base-url {shlex.quote(url)} \\\n"
        f"  --host-check 'exit 1' --check-gate-observe {learning_flag} \"$@\"\n",
        encoding="utf-8",
    )
    path.chmod(0o700)


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"chained memory smoke failed: {message}")


def _run(
    binary: Path, tinykg: Path, tinykgd: Path, root: Path, *, fixed_domain: bool
) -> Dict[str, Any]:
    provider = ScriptedProvider()
    server = _serve(provider)
    error: Optional[str] = None
    try:
        port = server.server_port
        wrappers = {}
        for arm, flag in zip(ARMS, ("--learning-turn-observe", "--learning-turn")):
            wrappers[arm] = root / f"{arm}-wrapper"
            _wrapper(
                wrappers[arm], binary, tinykg, tinykgd, f"http://127.0.0.1:{port}/{arm}", flag
            )
        journal_dir = root / "journal"
        journal_dir.mkdir(mode=0o700)
        suite = load_json(SUITE)
        errors = validate_suite(suite, REPO_ROOT)
        _require(not errors, f"suite does not validate: {errors}")
        # The control is the runner as it was before the fixed domain.
        control = (
            mock.patch.object(chained_runner, "chain_kg_domain", lambda _task: None)
            if not fixed_domain
            else None
        )
        if control is not None:
            control.start()
        try:
            chained_runner.run_chained(
                suite,
                REPO_ROOT,
                wrappers["baseline"],
                wrappers["candidate"],
                replicates=1,
                attempts=2,
                scenario_glob=TASK,
                model_provider=MODEL_PROVIDER,
                model_id=MODEL_ID,
                baseline_output=root / "out" / "baseline.jsonl",
                candidate_output=root / "out" / "candidate.jsonl",
                baseline_revision="chained-memory-smoke",
                candidate_revision="chained-memory-smoke",
                chain_dir=root / "chains",
                budget_journal_path=journal_dir / "budget-journal.json",
                max_cumulative_cost_usd=10.0,
                max_cumulative_tokens=4_000_000,
                max_rollout_cost_usd=1.0,
                max_rollout_metered_tokens=1_000_000,
                suite_path=SUITE,
            )
        except ValidationError as exc:
            error = str(exc)
        finally:
            if control is not None:
                control.stop()
    finally:
        server.shutdown()
        server.server_close()
    ledgers = {
        arm: chained_runner.load_ledger(root / "chains" / arm / "ledger.jsonl", arm)
        for arm in ARMS
    }
    outputs = root / "out" / "candidate.jsonl"
    return {
        "error": error,
        "requests": list(provider.requests),
        "failures": list(provider.failures),
        "ledgers": ledgers,
        "candidate_rollouts": load_rollouts(outputs) if outputs.exists() else [],
    }


def _rows(result: Mapping[str, Any], arm: str, kind: str) -> List[Dict[str, Any]]:
    return [row for row in result["requests"] if row["arm"] == arm and row["kind"] == kind]


def _verify_chain(result: Mapping[str, Any], label: str) -> List[Optional[bool]]:
    """What both runs share: two completed attempts per arm, attempt 2 on
    attempt 1's exported store, an accepted lesson in the treatment's
    attempt 1, no learning pass in the observe arm, every attempt committed
    in the journal. Returns whether each treatment lesson was accepted."""
    _require(result["error"] is None, f"{label}: the chained run failed: {result['error']}")
    _require(not result["failures"], f"{label}: the provider refused requests: {result['failures']}")
    for arm in ARMS:
        rows = result["ledgers"][arm]
        _require(
            all(isinstance(row, chained_runner.LedgerRow) for row in rows)
            and [row.attempt for row in rows] == [1, 2],
            f"{label}: {arm} ledger does not hold two completed attempts: {rows}",
        )
        _require(
            rows[1].store_import_sha256 == rows[0].store_export_sha256,
            f"{label}: {arm} attempt 2 did not import attempt 1's store",
        )
        _require(len(_rows(result, arm, "first")) == 2, f"{label}: {arm} did not run two attempts")
    _require(
        result["ledgers"]["candidate"][0].store_entries != (),
        f"{label}: the treatment's attempt 1 left no store to carry",
    )
    accepted = [row.get("lesson_accepted") for row in _rows(result, "candidate", "after_lesson")]
    _require(
        len(accepted) == 2 and accepted[0] is True,
        f"{label}: the treatment's attempt 1 lesson was not accepted: {accepted}",
    )
    _require(
        not _rows(result, "baseline", "distill"),
        f"{label}: the observe arm ran a learning pass",
    )
    _require(
        not any(row["carries_lesson"] for row in _rows(result, "baseline", "first")),
        f"{label}: the observe arm received a lesson",
    )
    _require(
        not _rows(result, "candidate", "first")[0]["carries_lesson"],
        f"{label}: attempt 1 saw a lesson before any was written",
    )
    rollouts = result["candidate_rollouts"]
    _require(
        len(rollouts) == 2
        and all(row.get("budget_transaction", {}).get("state") == "committed" for row in rollouts),
        f"{label}: the treatment rollouts are not committed in the budget journal",
    )
    return accepted


def _remove_runs(result: Mapping[str, Any]) -> None:
    runs = (REPO_ROOT / "tests/e2e/runs").resolve()
    for rows in result["ledgers"].values():
        for row in rows:
            if row.run_dir is None:
                continue
            run_dir = Path(row.run_dir).resolve()
            if run_dir.parent == runs and run_dir.is_dir():
                shutil.rmtree(run_dir)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--tinykg-binary", type=Path, required=True)
    parser.add_argument("--tinykgd-binary", type=Path, required=True)
    parser.add_argument("--keep", action="store_true", help="keep the temporary trees and run directories")
    args = parser.parse_args()
    binary = args.binary.resolve()
    tinykg = args.tinykg_binary.resolve()
    tinykgd = args.tinykgd_binary.resolve()
    for label, path in (("binary", binary), ("TinyKG binary", tinykg), ("TinyKG daemon", tinykgd)):
        _require(os.access(path, os.X_OK), f"{label} is not executable: {path}")
    host_home = Path(tempfile.mkdtemp(prefix="metacodes-chain-smoke-home-"))
    # lib.sh reads the provider credential from the host HOME; this one holds
    # only the loopback provider's token, never the operator's.
    (host_home / ".metacodes").mkdir(mode=0o700)
    (host_home / ".metacodes" / "auth.json").write_text(
        json.dumps({"api_key": CREDENTIAL}) + "\n", encoding="utf-8"
    )
    os.environ["HOME"] = str(host_home)
    results: Dict[str, Any] = {}
    try:
        for name, fixed in (("fixed", True), ("control", False)):
            root = Path(tempfile.mkdtemp(prefix=f"metacodes-chain-smoke-{name}-"))
            results[name] = (root, _run(binary, tinykg, tinykgd, root, fixed_domain=fixed))
        _fixed_root, fixed = results["fixed"]
        _control_root, control = results["control"]
        _require(
            _verify_chain(fixed, "fixed domain") == [True, True],
            "the treatment's attempt 2 lesson was not accepted",
        )
        # In the control attempt 2 writes into a second project of the same
        # store; whether that write lands does not bear on the recall check.
        _verify_chain(control, "control")
        _require(
            {row.kg_domain for rows in fixed["ledgers"].values() for row in rows}
            == {chained_runner.chain_kg_domain(TASK)},
            "the attempts did not all run in the task's chain domain",
        )
        treatment = _rows(fixed, "candidate", "first")
        _require(treatment[1]["carries_lesson"], "attempt 2 did not receive attempt 1's lesson")
        _require(
            _rows(fixed, "candidate", "distill")[1]["carries_lesson"],
            "attempt 2's learning turn did not see attempt 1's lesson as stored",
        )
        control_treatment = _rows(control, "candidate", "first")
        _require(
            not control_treatment[1]["carries_lesson"],
            "without the chain domain attempt 2 still recalled the lesson: the check cannot fail",
        )
        print(
            "chained memory smoke: attempt 2 received the lesson attempt 1 wrote; "
            "without the chain domain it did not"
        )
        return 0
    finally:
        if not args.keep:
            for root, result in results.values():
                _remove_runs(result)
                shutil.rmtree(root, ignore_errors=True)
            shutil.rmtree(host_home, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
