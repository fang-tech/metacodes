"""The 42_agentdef_isolation validator grades the kept worktree, not prose.

Each case builds a workspace the way the E2E runner leaves it (fake HOME
under ``.home``, the session transcript copied to ``transcript.jsonl``) and
runs the validator exactly as the grader does: ``python -I <validator>
<workspace>``, exit 0 meaning pass. The passing cases pin the regression the
validator replaced (a proof file saying ``worktree_kept: true``); the failing
cases are the retention failures the check exists to catch.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.eval.tests.posix_only import requires_symlinks

ROOT = Path(__file__).resolve().parents[3]
VALIDATOR = ROOT / "evals/validators/42_agentdef_isolation.py"
MARKER = "ISOLATED_WORKTREE_ONLY"


class AgentDefIsolationValidatorTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name) / "workspace"
        self.worktree = self.workspace / ".home/.metacodes/worktrees/agent-0001"
        self.worktree.mkdir(parents=True)
        (self.worktree / "isolation-child.txt").write_text(MARKER + "\n", encoding="utf-8")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write_transcript(self, result: dict, tool: str = "Task") -> None:
        lines = [
            {"role": "user", "blocks": [{"type": "text", "text": "isolate"}]},
            {
                "role": "assistant",
                "blocks": [{"type": "tool_use", "id": "tu_1", "name": tool, "input": "{}"}],
            },
            {
                "role": "user",
                "blocks": [
                    {"type": "tool_result", "tool_use_id": "tu_1", "content": json.dumps(result)}
                ],
            },
        ]
        with open(self.workspace / "transcript.jsonl", "w", encoding="utf-8") as handle:
            for line in lines:
                handle.write(json.dumps(line) + "\n")

    def kept(self, path: Path | None = None, kept: object = True) -> dict:
        return {
            "final_text": "done",
            "worktree_path": str(path if path is not None else self.worktree),
            "worktree_kept": kept,
            "worktree_cleanup_complete": True,
        }

    def run_validator(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-I", str(VALIDATOR), str(self.workspace)],
            capture_output=True,
            text=True,
            timeout=30,
        )

    def assert_passes(self) -> None:
        completed = self.run_validator()
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def assert_fails(self, reason: str) -> None:
        completed = self.run_validator()
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        self.assertIn(reason, completed.stdout)

    def test_kept_worktree_with_child_change_passes_whatever_the_proof_says(self):
        self.write_transcript(self.kept())
        # The proof format that failed 7 of 12 paired-eval rollouts.
        (self.workspace / "isolation-proof.txt").write_text(
            f"worktree_path: {self.worktree}\nworktree_kept: true\n", encoding="utf-8"
        )
        self.assert_passes()

    def test_reported_but_not_kept_fails(self):
        self.write_transcript(self.kept(kept=False))
        self.assert_fails("worktree_kept=False")

    def test_kept_flag_must_be_boolean_true(self):
        self.write_transcript(self.kept(kept="true"))
        self.assert_fails("worktree_kept='true'")

    def test_reported_kept_but_removed_from_disk_fails(self):
        self.write_transcript(self.kept())
        (self.worktree / "isolation-child.txt").unlink()
        self.worktree.rmdir()
        self.assert_fails("does not exist")

    def test_kept_worktree_without_child_file_fails(self):
        self.write_transcript(self.kept())
        (self.worktree / "isolation-child.txt").unlink()
        self.assert_fails("has no isolation-child.txt")

    def test_child_file_without_marker_fails(self):
        self.write_transcript(self.kept())
        (self.worktree / "isolation-child.txt").write_text("something else\n", encoding="utf-8")
        self.assert_fails("lacks ISOLATED_WORKTREE_ONLY")

    def test_worktree_outside_the_rollout_home_fails(self):
        outside = Path(self._tmp.name) / "elsewhere"
        outside.mkdir()
        (outside / "isolation-child.txt").write_text(MARKER, encoding="utf-8")
        self.write_transcript(self.kept(outside))
        self.assert_fails("outside this rollout's HOME")

    @requires_symlinks
    def test_symlink_inside_home_pointing_outside_fails(self):
        outside = Path(self._tmp.name) / "elsewhere"
        outside.mkdir()
        (outside / "isolation-child.txt").write_text(MARKER, encoding="utf-8")
        link = self.workspace / ".home/.metacodes/worktrees/agent-link"
        os.symlink(outside, link, target_is_directory=True)
        self.write_transcript(self.kept(link))
        self.assert_fails("outside this rollout's HOME")

    def test_result_of_another_tool_does_not_count(self):
        # A model writing the same JSON through Write must not stand in for
        # the Task tool's own result.
        self.write_transcript(self.kept(), tool="Write")
        self.assert_fails("no structured Task/Agent result")

    def test_missing_transcript_fails(self):
        self.assert_fails("transcript.jsonl is missing")


if __name__ == "__main__":
    unittest.main()
