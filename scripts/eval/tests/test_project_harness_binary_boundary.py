from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from scripts.eval.project_harness_binary_boundary import BoundaryError, _journal_events


def _row(sequence: int, event: dict) -> str:
    return json.dumps({
        "schema_version": "metacodes-tool-observation-journal-v2",
        "sequence": sequence,
        "monotonic_elapsed_ns": sequence,
        "session_id": "1" * 24,
        "run_id": "2" * 24,
        "event": event,
    }) + "\n"


class JournalEventsTest(unittest.TestCase):
    def test_a_run_its_process_abandoned_is_refused_not_summarized(self) -> None:
        events = [
            {"run_started": {}},
            {"tool_observation": {"dispatch_started": {"dispatched_name": "Bash"}}},
            {"run_abandoned": {
                "evidence": "lease_unlocked",
                "recovered_wall_ns": 1,
                "recovered_by_run_id": "3" * 24,
                "open_dispatches": 1,
                "open_provider_attempts": 0,
            }},
            {"run_started": {}},
            {"run_finished": {"stop_reason": "end_turn"}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            journal = Path(directory) / "tool-observations.jsonl"
            journal.write_text("".join(_row(i, e) for i, e in enumerate(events)), encoding="utf-8")
            with self.assertRaisesRegex(BoundaryError, "abandoned"):
                _journal_events(journal)
            # Without the abandoned Run the same journal reads.
            kept = [events[0], events[1], {"tool_observation": {}}, events[4]]
            journal.write_text("".join(_row(i, e) for i, e in enumerate(kept)), encoding="utf-8")
            self.assertEqual(len(_journal_events(journal)), 4)


if __name__ == "__main__":
    unittest.main()
