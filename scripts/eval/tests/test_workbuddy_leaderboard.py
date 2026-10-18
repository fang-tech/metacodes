import json
import tempfile
import unittest
from pathlib import Path

try:
    import yaml
except ImportError as error:  # pragma: no cover - environment, not logic
    raise ImportError(
        "PyYAML is required here: python3 -m pip install -r requirements-dev.txt"
    ) from error

from scripts.eval.workbuddy import leaderboard_jobs
from scripts.eval.workbuddy.launch_gate import PROVIDER_KEY_ENV

OVERLAY = Path(__file__).parents[1] / "workbuddy/overlay"


def _manifest():
    return json.loads(leaderboard_jobs.COHORT_MANIFEST.read_text(encoding="utf-8"))


class LeaderboardJobsTest(unittest.TestCase):
    def test_one_run_covers_every_task_once_in_sixteen_frozen_cohort_jobs(self):
        manifest = _manifest()
        for run in leaderboard_jobs.RUNS:
            jobs = leaderboard_jobs.run_jobs(manifest, run)
            self.assertEqual(len(jobs), 16)
            by_subset = {}
            for slug, job in jobs.items():
                self.assertTrue(slug.endswith(f"-r{run}"), slug)
                self.assertEqual(job["jobs_dir"], f"results/{slug}")
                subset = slug.split("-")[3]
                by_subset.setdefault(subset, []).extend(job["task_selection"]["names"])
            for subset, names in by_subset.items():
                row = manifest["subsets"][subset]
                self.assertEqual(len(names), len(set(names)), subset)
                self.assertEqual(len(names), row["task_count"], subset)
                for cohort in leaderboard_jobs.COHORTS:
                    # Exactly the selection launch_gate.create compares against.
                    job = jobs[leaderboard_jobs.job_slug(subset, cohort, run)]
                    self.assertEqual(job["task_selection"], row["cohorts"][cohort]["task_selection"])
                    self.assertEqual(job["dataset"], row["dataset"])
            self.assertEqual(sum(len(n) for n in by_subset.values()), 260)

    def test_jobs_differ_only_in_identity_selection_and_judge(self):
        manifest = _manifest()
        reference = None
        for run in leaderboard_jobs.RUNS:
            for slug, job in leaderboard_jobs.run_jobs(manifest, run).items():
                subset = slug.split("-")[3]
                judge = job.pop("llm_judge_override", None)
                if subset in leaderboard_jobs.JUDGED_SUBSETS:
                    self.assertEqual(
                        judge,
                        {"enabled": True, "mode": "in_container", "model": "judge-kimi-k27"},
                    )
                else:
                    # Code and Security headline scores take no LLM judge.
                    self.assertIsNone(judge)
                for key in ("jobs_dir", "task_selection", "dataset"):
                    job.pop(key)
                if reference is None:
                    reference = job
                self.assertEqual(job, reference, slug)

    def test_protocol_is_the_leaderboard_one(self):
        job = leaderboard_jobs.job_document(_manifest(), "security", "sealed", 2)
        overrides = job["harness_params_override"]
        disabled = set(overrides["METACODES_DISALLOWED_TOOLS"].split(","))
        self.assertTrue({"WebSearch", "AskUserQuestion"}.issubset(disabled))
        # Web fetching stays available, as in both official harnesses.
        self.assertNotIn("WebFetch", disabled)
        self.assertEqual(overrides["METACODES_REASONING_EFFORT"], "high")
        self.assertEqual((job["context_window"], job["context_compact_pct"]), (200000, 92))
        self.assertEqual(job["model"], "metacodes-glm52-leaderboard")
        # What launch_gate.create requires of a paid job.
        self.assertEqual(job["harness"], "metacodes/0.1.0")
        self.assertEqual(job["model_connection"], "local_proxy")
        self.assertIs(job["record_full_io"], True)
        self.assertEqual(job["n_attempts"], 1)
        self.assertEqual(job["orchestrator_override"], {"n_concurrent_trials": 1})
        for key, value in leaderboard_jobs.TREATMENTS_OFF.items():
            self.assertIn(key, overrides)
            self.assertEqual(overrides[key], value)
        for bad in ((0, "code", "dev"), (4, "code", "dev"), (1, "mail", "dev"), (1, "code", "dev_etag")):
            with self.subTest(bad=bad), self.assertRaises(leaderboard_jobs.LeaderboardJobError):
                leaderboard_jobs.job_document(_manifest(), bad[1], bad[2], bad[0])

    def test_write_run_is_idempotent_and_never_rewrites_a_different_job(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "jobs"
            first = leaderboard_jobs.write_run(leaderboard_jobs.COHORT_MANIFEST, 1, output)
            self.assertEqual(len(first), 16)
            again = leaderboard_jobs.write_run(leaderboard_jobs.COHORT_MANIFEST, 1, output)
            self.assertEqual(first, again)
            loaded = yaml.safe_load(first[0].read_text(encoding="utf-8"))
            self.assertEqual(loaded, leaderboard_jobs.job_document(
                _manifest(), "code", "dev", 1))
            first[0].write_text(first[0].read_text(encoding="utf-8") + "n_attempts: 3\n", encoding="utf-8")
            with self.assertRaises(leaderboard_jobs.LeaderboardJobError):
                leaderboard_jobs.write_run(leaderboard_jobs.COHORT_MANIFEST, 1, output)

    def test_actor_model_injects_no_sampling_override(self):
        model = yaml.safe_load(
            (OVERLAY / "configs/models/metacodes-glm52-leaderboard.yaml").read_text(encoding="utf-8")
        )["model"]
        self.assertEqual(model["name"], "glm-5.2")
        self.assertEqual(model["backend_key_env"], PROVIDER_KEY_ENV)
        self.assertEqual(model["context_window"], 200000)
        # The proxy flattens params into the upstream body: only the output
        # budget, never temperature/top_p/thinking.
        self.assertEqual(model["params"], {"max_output_tokens": 32768})

    def test_judge_model_is_the_published_leaderboard_judge(self):
        judge = yaml.safe_load(
            (OVERLAY / "configs/models/judge-kimi-k27.yaml").read_text(encoding="utf-8")
        )["model"]
        self.assertEqual(judge["protocols"], ["openai"])
        self.assertEqual(
            judge["params"],
            {
                "max_output_tokens": 32768,
                "temperature": 1.0,
                "top_p": 0.95,
                "thinking_enabled": True,
                "extra_body": {
                    "reasoning_effort": "low",
                    "response_format": {"type": "json_object"},
                },
            },
        )
        # Never the actor credential: judge spend is metered on its own key.
        self.assertNotEqual(judge["backend_key_env"], PROVIDER_KEY_ENV)


if __name__ == "__main__":
    unittest.main()
