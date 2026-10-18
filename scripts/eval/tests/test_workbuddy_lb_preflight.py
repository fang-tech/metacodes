import contextlib
import copy
import hashlib
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

try:
    import yaml
except ImportError as error:  # pragma: no cover - environment, not logic
    raise ImportError(
        "PyYAML is required here: python3 -m pip install -r requirements-dev.txt"
    ) from error

from scripts.eval.workbuddy import leaderboard_jobs
from scripts.eval.workbuddy import run_lb_preflight as preflight
from scripts.eval.workbuddy.mock_provider import (
    LEADERBOARD_RESULT,
    LEADERBOARD_STDIN_MARKER,
    ScenarioError,
    _leaderboard_sse,
)
from scripts.eval.workbuddy.run_w05 import _wire_json_sha256
from scripts.eval.tests.posix_only import POSIX
from scripts.eval.tests.test_workbuddy_adapter import _replay_adapter

OVERLAY = Path(__file__).parents[1] / "workbuddy/overlay"
TASK = OVERLAY / "datasets/metacodes-lb-synthetic/tasks/metacodes-lb-protocol"


def _body(**changes):
    body = {
        "model": "glm-5.2",
        "stream": True,
        "max_tokens": 32768,
        "thinking": {"type": "adaptive"},
        "output_config": {"effort": "high"},
        "messages": [{"role": "user", "content": "x"}],
        "tools": [{"name": n} for n in ("Bash", "Read", "Write", "WebFetch")],
    }
    body.update(changes)
    return body


def _proxy_rows(bodies, seqs=None):
    rows, mock_rows = [], []
    for index, body in enumerate(bodies, 1):
        rows.append({
            "seq": (seqs or {}).get(index, index),
            "route": "wb-preflight-run--metacodes-lb-mock",
            "trial_id": "metacodes-lb-protocol__abc",
            "request": {"upstream_body": body, "upstream_url": "http://127.0.0.1:9/v1/messages"},
        })
        mock_rows.append({"body_sha256": _wire_json_sha256(body)})
    return rows, mock_rows


class LeaderboardPreflightAuditTest(unittest.TestCase):
    def test_upstream_body_audit_accepts_the_protocol_and_refuses_each_deviation(self):
        preflight.upstream_body_assertions(_body())
        for label, change in {
            "temperature": {"temperature": 0.0},
            "top_p": {"top_p": 0.9},
            "top_k": {"top_k": 20},
            "thinking": {"thinking": {"type": "disabled"}},
            "effort": {"output_config": {"effort": "max"}},
            "max_tokens": {"max_tokens": 1024},
            "websearch": {"tools": [{"name": "WebFetch"}, {"name": "WebSearch"}]},
            "ask": {"tools": [{"name": "WebFetch"}, {"name": "AskUserQuestion"}]},
            "no webfetch": {"tools": [{"name": "Bash"}]},
        }.items():
            with self.subTest(label), self.assertRaises(preflight.PreflightError):
                preflight.upstream_body_assertions(_body(**change))

    def test_proxy_audit_requires_a_gapless_wave_bound_to_the_provider_bodies(self):
        rows, mock_rows = _proxy_rows([_body(), _body()])
        self.assertEqual(len(preflight.proxy_audit(rows, mock_rows)), 2)
        # The September failure: the judge route consumed sequence numbers.
        rows, mock_rows = _proxy_rows([_body(), _body()], seqs={2: 3})
        with self.assertRaisesRegex(preflight.PreflightError, "gapless"):
            preflight.proxy_audit(rows, mock_rows)
        rows, mock_rows = _proxy_rows([_body(), _body()])
        mock_rows[1] = {"body_sha256": "0" * 64}
        with self.assertRaises(preflight.PreflightError):
            preflight.proxy_audit(rows, mock_rows)
        rows, mock_rows = _proxy_rows([_body(), _body(temperature=0.0)])
        with self.assertRaisesRegex(preflight.PreflightError, "sampling"):
            preflight.proxy_audit(rows, mock_rows)

    def test_runtime_contract_must_bind_the_recorded_instruction(self):
        payload = b"the task\n"
        digest = hashlib.sha256(payload).hexdigest()
        copies = {f"metacodes-instruction-{digest[:16]}.md": payload}
        contract = {
            "instruction_delivery": "stdin-uploaded-file",
            "instruction_sha256": digest,
            "reasoning_effort": "high",
            "declared_context_window": 200000,
            "transport_model_is_route": True,
            "quality_evidence": False,
            "fresh_home": True,
            "project_control": {"mode": "absent"},
        }
        preflight.runtime_contract_assertions(contract, copies)
        for key, value in (
            ("instruction_delivery", "argv"),
            ("instruction_sha256", "0" * 64),
            ("reasoning_effort", None),
            ("declared_context_window", None),
            ("quality_evidence", True),
        ):
            drifted = copy.deepcopy(contract)
            drifted[key] = value
            with self.subTest(key), self.assertRaises(preflight.PreflightError):
                preflight.runtime_contract_assertions(drifted, copies)
        with self.assertRaises(preflight.PreflightError):
            preflight.runtime_contract_assertions(contract, {})

    def test_output_audit_requires_the_window_derived_thresholds(self):
        result = {"type": "result", "stop_reason": "end_turn"}
        warning = {"type": "context_warning", "current_tokens": 150_100,
                   "auto_compact_threshold": 154_232}
        self.assertEqual(preflight.output_assertions([warning, result]), warning)
        for events in (
            [result],
            [dict(warning, auto_compact_threshold=904_504), result],
            [dict(warning, current_tokens=154_232), result],
            [warning, dict(result, stop_reason="max_turns")],
        ):
            with self.subTest(events=events), self.assertRaises(preflight.PreflightError):
                preflight.output_assertions(events)


class LeaderboardPreflightEnvironmentTest(unittest.TestCase):
    def test_runner_environment_drops_the_judge_key(self):
        from scripts.eval.workbuddy import WORKBUDDY_JUDGE_KEY_ENV

        environment = preflight._clean_environment(
            {"PATH": "/fixture", WORKBUDDY_JUDGE_KEY_ENV: "judge-secret"}
        )
        self.assertEqual({"PATH": "/fixture"}, environment)


class LeaderboardPreflightOverlayTest(unittest.TestCase):
    def test_preflight_job_is_the_protocol_on_the_synthetic_task(self):
        committed = (OVERLAY / "configs/jobs/metacodes-lb-protocol-preflight.yaml").read_text(
            encoding="utf-8"
        )
        self.assertEqual(committed, leaderboard_jobs.dump(leaderboard_jobs.preflight_job_document()))
        job = yaml.safe_load(committed)
        paid = leaderboard_jobs.job_document(
            json.loads(leaderboard_jobs.COHORT_MANIFEST.read_text(encoding="utf-8")),
            "code", "dev", 1,
        )
        for key in ("harness_params_override", "context_window", "context_compact_pct",
                    "n_attempts", "record_full_io", "orchestrator_override", "harness",
                    "model_connection"):
            self.assertEqual(job[key], paid[key], key)

    def test_mock_model_injects_exactly_what_the_paid_model_injects(self):
        def load(name):
            return yaml.safe_load((OVERLAY / f"configs/models/{name}.yaml").read_text(encoding="utf-8"))["model"]
        mock_model, paid = load("metacodes-lb-mock"), load("metacodes-glm52-leaderboard")
        for key in ("name", "protocols", "backend_key_env", "context_window", "params"):
            self.assertEqual(mock_model[key], paid[key], key)
        self.assertEqual(mock_model["backend_url_env"], "METACODES_LB_MOCK_BASE_URL")

    def test_synthetic_task_carries_the_scenario_marker_and_expected_artifact(self):
        instruction = (TASK / "instruction.md").read_text(encoding="utf-8")
        self.assertIn(LEADERBOARD_STDIN_MARKER, instruction)
        self.assertIn(LEADERBOARD_RESULT.strip(), instruction)
        self.assertIn(LEADERBOARD_RESULT.strip(), (TASK / "tests/test.sh").read_text(encoding="utf-8"))


@contextlib.contextmanager
def _scenario_server():
    seen, errors = [], []
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler contract
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            with lock:
                seen.append(body)
                try:
                    payload = _leaderboard_sse(len(seen), body)
                except ScenarioError as exc:
                    errors.append(str(exc))
                    self.send_error(409, str(exc))
                    return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_args):
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
    thread.daemon = True
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}", seen, errors
    finally:
        server.shutdown()
        server.server_close()


class LeaderboardPreflightBinaryTest(unittest.TestCase):
    @unittest.skipUnless(
        POSIX and os.environ.get("METACODES_NATIVE_E2E_BIN"),
        "set METACODES_NATIVE_E2E_BIN to run the preflight scenario against the binary",
    )
    def test_the_installed_binary_satisfies_the_preflight_scenario(self):
        """The same protocol job, the same scripted scenario and the same
        output audit the containerized preflight applies, minus Harbor and
        the proxy: a scenario/binary mismatch shows up here first."""
        job = leaderboard_jobs.preflight_job_document()
        overrides = job["harness_params_override"]
        instruction = (TASK / "instruction.md").read_text(encoding="utf-8")
        with _scenario_server() as (url, seen, errors):
            done, events = _replay_adapter(
                os.environ["METACODES_NATIVE_E2E_BIN"],
                instruction,
                model_name="wb-lb-preflight-l2--metacodes-lb-mock",
                _proxy_url=url,
                _disabled_tools=overrides["METACODES_DISALLOWED_TOOLS"],
                _reasoning_effort=overrides["METACODES_REASONING_EFFORT"],
                _context_window=job["context_window"],
                _context_compact_pct=job["context_compact_pct"],
                _max_output_tokens=32768,
            )
        self.assertEqual(errors, [])
        self.assertEqual(done.returncode, 0, done.stderr.decode("utf-8", "replace")[-2000:])
        self.assertEqual(len(seen), preflight.EXPECTED_PROVIDER_REQUESTS)
        for body in seen:
            preflight.upstream_body_assertions(body)
        preflight.output_assertions(events)
        self.assertEqual(done.workspace_files.get("result.txt"), LEADERBOARD_RESULT.encode("utf-8"))


if __name__ == "__main__":
    unittest.main()
