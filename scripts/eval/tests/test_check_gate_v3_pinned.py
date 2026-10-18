"""The pinned full-validator dispatcher of learning-turn-v1 configuration D
(evals/validators/check_gate_v3_pinned.py): the task hint picks the suite's
own validator, a real failing workspace yields a parseable FAILED verdict, a
validator that crashes is no verdict, and every path without a verdict exits
127 so the check gate records `unavailable`."""

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.tests.posix_only import requires_symlinks

REPO_ROOT = Path(__file__).resolve().parents[3]
DISPATCHER = REPO_ROOT / "evals/validators/check_gate_v3_pinned.py"
SUITE = REPO_ROOT / "evals/suites/check-gate-v3.json"
D1_VALIDATOR = REPO_ROOT / "evals/validators/d1_check_gate_v3_cron.py"
STUB = "def next_fire(expression, after):\n    raise NotImplementedError\n"

_spec = importlib.util.spec_from_file_location("check_gate_v3_pinned", DISPATCHER)
pinned = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pinned)


def _dispatch(workspace):
    return subprocess.run(
        [sys.executable, "-I", str(DISPATCHER)],
        cwd=workspace,
        env={"METACODES_TASK_HINT": "d1_cg3_cron", "PATH": ""},
        capture_output=True,
        text=True,
        timeout=200,
        check=False,
    )


class PinnedValidatorTest(unittest.TestCase):
    def test_mapping_is_the_suites_own_validators(self):
        suite = json.loads(SUITE.read_text(encoding="utf-8"))
        expected = {}
        for task in suite["tasks"]:
            validators = [c["validator"] for c in task["success"]["checks"] if c["type"] == "validator"]
            self.assertEqual(len(validators), 1, task["id"])
            expected[task["id"]] = Path(validators[0]).name
        self.assertEqual(pinned.VALIDATORS, expected)
        for task_id in expected:
            self.assertEqual(pinned.resolve(task_id), REPO_ROOT / "evals/validators" / expected[task_id])

    def test_the_verdict_lines_are_the_ones_every_validator_prints(self):
        # The dispatcher trusts exactly these lines; each validator's own
        # source must still print them, or the mapping goes stale silently.
        for name in pinned.VALIDATORS.values():
            source = (REPO_ROOT / "evals/validators" / name).read_text(encoding="utf-8")
            self.assertIn('print("%d failed, %d passed"', source, name)
            self.assertIn('print("%s")' % pinned.TIMEOUT_LINE, source, name)

    def test_no_or_unknown_hint_is_unavailable_without_running_anything(self):
        with mock.patch.object(pinned.subprocess, "run") as run:
            self.assertEqual(pinned.main(["x"], {}), pinned.EXIT_UNAVAILABLE)
            self.assertEqual(pinned.main(["x"], {"METACODES_TASK_HINT": "other"}), pinned.EXIT_UNAVAILABLE)
            run.assert_not_called()

    def test_a_verdict_needs_its_verdict_line_and_an_exit_status_that_agrees(self):
        failed = pinned.EXIT_FAILED
        cases = (
            (0, "ok\n0 failed, 12 passed\n\n", pinned.EXIT_PASSED),
            (1, "FAILED tests/test_a.py::A::b - boom\n1 failed, 11 passed\n", failed),
            (1, "tests timed out\n", failed),
            # A status the line contradicts, or no tests at all: no verdict.
            (1, "0 failed, 12 passed\n", None),
            (0, "3 failed, 9 passed\n", None),
            (0, "0 failed, 0 passed\n", None),
            (0, "tests timed out\n", None),
            # The tests' stderr follows the count line: the last verdict
            # line decides, not the last line.
            (1, "2 failed, 1 passed\nTraceback (most recent call last):\n", failed),
            (0, "0 failed, 12 passed\ndebug: parsed 5 fields\n", pinned.EXIT_PASSED),
            # A count line forged after the real one can only disagree with
            # the status, which is no verdict, never a pass.
            (1, "3 failed, 9 passed\n0 failed, 12 passed\n", None),
            # No verdict line at all.
            (1, "Traceback (most recent call last):\nOSError: boom\n", None),
            (1, "", None),
            (2, "1 failed, 0 passed\n", None),
        )
        for code, stdout, expected in cases:
            with self.subTest(code=code, stdout=stdout):
                self.assertEqual(pinned.verdict(code, stdout), expected)

    def test_a_missing_validator_is_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(
                pinned.main(["x"], {"METACODES_TASK_HINT": "d1_cg3_cron"}, Path(directory)),
                pinned.EXIT_UNAVAILABLE,
            )

    @requires_symlinks
    def test_a_validator_that_crashes_is_unavailable_not_failed(self):
        """A dangling symlink in a workspace subdirectory makes the real d1
        validator's workspace copy raise: it exits 1 with a traceback, the
        status a failing test run has. The dispatcher must not pass that on
        as a failed verdict a learning turn would learn from."""
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            (workspace / "cronexpr.py").write_text(STUB, encoding="utf-8")
            (workspace / "notes").mkdir()
            os.symlink(workspace / "missing-target", workspace / "notes" / "dangling")
            crashed = subprocess.run(
                [sys.executable, "-I", str(D1_VALIDATOR), str(workspace)],
                capture_output=True,
                text=True,
                timeout=200,
                check=False,
            )
            self.assertEqual(crashed.returncode, 1)
            self.assertIn("Traceback (most recent call last)", crashed.stderr)
            self.assertNotRegex(crashed.stdout, r"\d+ failed, \d+ passed")
            completed = _dispatch(workspace)
        self.assertEqual(completed.returncode, pinned.EXIT_UNAVAILABLE, completed.stderr)
        self.assertIn("no verdict", completed.stderr)

    def test_a_failing_workspace_gets_the_full_validators_failed_verdict(self):
        """End to end through the real d1 validator: a stub that raises fails
        visible and hidden tests alike, and the output carries the FAILED
        lines and the count line the verdict codecs parse."""
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            (workspace / "cronexpr.py").write_text(STUB, encoding="utf-8")
            completed = _dispatch(workspace)
        self.assertEqual(completed.returncode, 1, completed.stderr)
        lines = completed.stdout.strip().splitlines()
        self.assertRegex(lines[-1], r"^\d+ failed, 0 passed$")
        self.assertTrue(any(re.match(r"FAILED tests/test_hidden_cron\.py::", line) for line in lines))

    def test_the_candidates_stderr_does_not_cost_the_verdict(self):
        """The real d1 validator prints the test run's stderr after its count
        line, so a candidate that logs to stderr ends the output on its own
        lines. The verdict is still the count line's."""
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            noisy = "import sys\nprint('debug: cronexpr loaded', file=sys.stderr)\n" + STUB
            (workspace / "cronexpr.py").write_text(noisy, encoding="utf-8")
            completed = _dispatch(workspace)
        self.assertEqual(completed.returncode, pinned.EXIT_FAILED, completed.stderr)
        lines = [line for line in completed.stdout.strip().splitlines() if line.strip()]
        self.assertEqual(lines[-1].strip(), "debug: cronexpr loaded")
        self.assertTrue(any(re.fullmatch(r"\d+ failed, 0 passed", line.strip()) for line in lines))


if __name__ == "__main__":
    unittest.main()
