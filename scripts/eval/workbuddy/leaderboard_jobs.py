"""Write the WorkBuddy-Bench leaderboard-protocol jobs for one run.

The leaderboard (v1.2, technical report §4) averages three independent runs of
every task, in think mode, with reasoning effort fixed to high, a 200k context
window with one compaction threshold, WebSearch and AskUserQuestion disabled,
and otherwise provider-default inference parameters.  Web and Office are
judged by Kimi K2.7 Code (upstream issue #3).

A paid launch binds one frozen cohort, one attempt and one concurrent trial
(``launch_gate.create``), so one run is sixteen jobs: four subsets times the
four frozen cohorts, which together cover all 260 tasks once.  Run ``r`` of the
protocol is these sixteen files with suffix ``-r<r>``; three runs are three
independent sets of transactions.  The files differ from each other only in
subset, cohort, run index, task selection and result root.

    python3 -m scripts.eval.workbuddy.leaderboard_jobs \\
        --run 1 --output /path/to/workbuddy-bench/configs/jobs
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict, List, Mapping

try:
    import yaml
except ImportError as error:  # pragma: no cover - environment, not logic
    raise ImportError(
        "PyYAML is required here: python3 -m pip install -r requirements-dev.txt"
    ) from error

COHORT_MANIFEST = Path(__file__).with_name("manifests") / "workbuddy-v1-cohorts.json"

MODEL = "metacodes-glm52-leaderboard"
JUDGE_MODEL = "judge-kimi-k27"
# The frozen single-agent policy of every earlier WorkBuddy run plus the two
# tools the protocol disables.  Agent/Task stay off: delegation is a separate
# treatment for this harness, and the adapter audits exactly one transcript.
DISALLOWED_TOOLS = (
    "Agent,Task,TaskBatch,TeamCreate,TeamDelete,SendMessage,"
    "EnterPlanMode,ExitPlanMode,WebSearch,AskUserQuestion"
)
REASONING_EFFORT = "high"
CONTEXT_WINDOW = 200_000
CONTEXT_COMPACT_PCT = 92
RUNS = (1, 2, 3)
SUBSETS = ("code", "office", "security", "web")
JUDGED_SUBSETS = ("office", "web")
COHORTS = {
    "dev": "dev",
    "promotion_a": "proma",
    "promotion_b": "promb",
    "sealed": "sealed",
}
# The zero-provider preflight runs the same protocol through the official
# runner against a scripted loopback provider (run_lb_preflight.py).
PREFLIGHT_SLUG = "metacodes-lb-protocol-preflight"
PREFLIGHT_MODEL = "metacodes-lb-mock"
PREFLIGHT_DATASET = "datasets/metacodes-lb-synthetic/tasks"
PREFLIGHT_TASK = "metacodes-lb-protocol"
# Every treatment key explicit (launch_gate refuses a job that omits one).
TREATMENTS_OFF: Dict[str, Any] = {
    "METACODES_VERIFICATION_CHECKPOINT": False,
    "METACODES_VERIFICATION_FINAL_GATE": False,
    "METACODES_VERIFICATION_FINAL_OBSERVE": False,
    "METACODES_REQUIREMENT_LEDGER": False,
    "METACODES_REQUIREMENT_LEDGER_OBSERVE": False,
    "METACODES_MEMORY_ACCUMULATION": False,
    "METACODES_SELF_EVOLUTION": False,
    "METACODES_OUTCOME_FEEDBACK": False,
    "METACODES_CONTINUITY_SEED_SHA256": None,
}


class LeaderboardJobError(ValueError):
    pass


def job_slug(subset: str, cohort: str, run: int) -> str:
    return f"metacodes-glm52-lb-{subset}-{COHORTS[cohort]}-r{run}"


def _protocol_document(
    *, slug: str, model: str, dataset: str, names: List[str], judged: bool
) -> Dict[str, Any]:
    document: Dict[str, Any] = {
        "model": model,
        "harness": "metacodes/0.1.0",
        "dataset": dataset,
        "harness_backend": "local",
        "model_connection": "local_proxy",
        "jobs_dir": f"results/{slug}",
        "n_attempts": 1,
        "record_full_io": True,
        "extra_allowed_hosts": ["host.docker.internal"],
        "harness_params_override": {
            **TREATMENTS_OFF,
            "METACODES_DISALLOWED_TOOLS": DISALLOWED_TOOLS,
            "METACODES_REASONING_EFFORT": REASONING_EFFORT,
        },
        "task_selection": {"mode": "name", "names": list(names)},
        "orchestrator_override": {"n_concurrent_trials": 1},
        "context_window": CONTEXT_WINDOW,
        "context_compact_pct": CONTEXT_COMPACT_PCT,
    }
    if judged:
        document["llm_judge_override"] = {
            "enabled": True,
            "mode": "in_container",
            "model": JUDGE_MODEL,
        }
    return document


def job_document(
    manifest: Mapping[str, Any], subset: str, cohort: str, run: int
) -> Dict[str, Any]:
    if run not in RUNS:
        raise LeaderboardJobError(f"run must be one of {RUNS}")
    if subset not in SUBSETS or cohort not in COHORTS:
        raise LeaderboardJobError(f"unknown subset/cohort {subset}/{cohort}")
    row = manifest["subsets"][subset]
    selection = row["cohorts"][cohort]["task_selection"]
    if selection.get("mode") != "name" or not selection.get("names"):
        raise LeaderboardJobError(f"{subset}/{cohort} has no named task selection")
    return _protocol_document(
        slug=job_slug(subset, cohort, run),
        model=MODEL,
        dataset=row["dataset"],
        names=list(selection["names"]),
        judged=subset in JUDGED_SUBSETS,
    )


def preflight_job_document() -> Dict[str, Any]:
    """The leaderboard protocol on the synthetic preflight task (no judge)."""
    return _protocol_document(
        slug=PREFLIGHT_SLUG,
        model=PREFLIGHT_MODEL,
        dataset=PREFLIGHT_DATASET,
        names=[PREFLIGHT_TASK],
        judged=False,
    )


def dump(document: Mapping[str, Any]) -> str:
    return yaml.safe_dump(dict(document), sort_keys=False, allow_unicode=True)


def run_jobs(manifest: Mapping[str, Any], run: int) -> Dict[str, Dict[str, Any]]:
    return {
        job_slug(subset, cohort, run): job_document(manifest, subset, cohort, run)
        for subset in SUBSETS
        for cohort in COHORTS
    }


def write_run(manifest_path: Path, run: int, output: Path) -> List[Path]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    output.mkdir(parents=True, exist_ok=True)
    written = []
    for slug, document in run_jobs(manifest, run).items():
        path = output / f"{slug}.yaml"
        text = dump(document)
        if path.exists() and path.read_text(encoding="utf-8") != text:
            raise LeaderboardJobError(f"refusing to rewrite a different job: {path}")
        path.write_text(text, encoding="utf-8")
        written.append(path)
    return written


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=int, required=True, choices=RUNS)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cohort-manifest", type=Path, default=COHORT_MANIFEST)
    args = parser.parse_args(argv)
    for path in write_run(args.cohort_manifest, args.run, args.output):
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
