"""The pinned full-validator dispatcher of learning-turn-v1 configuration D
(evals/validators/check_gate_v3_pinned.py): the task hint picks the suite's
own validator, a real failing workspace yields a parseable FAILED verdict, and
every path without a verdict exits 127 so the check gate records
`unavailable`."""

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[3]
DISPATCHER = REPO_ROOT / "evals/validators/check_gate_v3_pinned.py"
SUITE = REPO_ROOT / "evals/suites/check-gate-v3.json"

_spec = importlib.util.spec_from_file_location("check_gate_v3_pinned", DISPATCHER)
pinned = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pinned)


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

    def test_no_or_unknown_hint_is_unavailable_without_running_anything(self):
        with mock.patch.object(pinned.subprocess, "run") as run:
            self.assertEqual(pinned.main(["x"], {}), pinned.EXIT_UNAVAILABLE)
            self.assertEqual(pinned.main(["x"], {"METACODES_TASK_HINT": "other"}), pinned.EXIT_UNAVAILABLE)
            run.assert_not_called()

    def _fake_validators(self, root, code):
        (root / pinned.VALIDATORS["d1_cg3_cron"]).write_text(
            "import sys\nprint('ran on', sys.argv[1])\nsys.exit(%d)\n" % code, encoding="utf-8"
        )
        return root

    def test_validator_status_maps_to_the_check_gates_verdict_classes(self):
        for code, expected in ((0, 0), (1, 1), (2, pinned.EXIT_UNAVAILABLE), (139, pinned.EXIT_UNAVAILABLE)):
            with tempfile.TemporaryDirectory() as directory:
                root = self._fake_validators(Path(directory), code)
                observed = pinned.main(["x", directory], {"METACODES_TASK_HINT": "d1_cg3_cron"}, root)
                self.assertEqual(observed, expected, code)

    def test_a_missing_validator_is_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(
                pinned.main(["x"], {"METACODES_TASK_HINT": "d1_cg3_cron"}, Path(directory)),
                pinned.EXIT_UNAVAILABLE,
            )

    def test_a_failing_workspace_gets_the_full_validators_failed_verdict(self):
        """End to end through the real d1 validator: a stub that raises fails
        visible and hidden tests alike, and the output carries the FAILED
        lines and the count line the verdict codecs parse."""
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            (workspace / "cronexpr.py").write_text(
                "def next_fire(expression, after):\n    raise NotImplementedError\n", encoding="utf-8"
            )
            completed = subprocess.run(
                [sys.executable, "-I", str(DISPATCHER)],
                cwd=workspace,
                env={"METACODES_TASK_HINT": "d1_cg3_cron", "PATH": ""},
                capture_output=True,
                text=True,
                timeout=200,
                check=False,
            )
        self.assertEqual(completed.returncode, 1, completed.stderr)
        lines = completed.stdout.strip().splitlines()
        self.assertRegex(lines[-1], r"^\d+ failed, 0 passed$")
        self.assertTrue(any(re.match(r"FAILED tests/test_hidden_cron\.py::", line) for line in lines))


if __name__ == "__main__":
    unittest.main()
