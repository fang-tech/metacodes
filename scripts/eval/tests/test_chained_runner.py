"""Chained-attempt runner: one TinyKG store carried across the attempts of a
chain, never across chains, replicates or arms; one TinyKG domain for every
attempt at a task; a hash-chained ledger that fails closed on any break; the
session's task hint; every attempt reserved, authorized and committed in the
durable budget journal; resume without repeating a paid attempt."""

import hashlib
import json
import math
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval import cli
from scripts.eval.chained_runner import (
    LEDGER_SCHEMA,
    FailedAttempt,
    LedgerRow,
    chain_kg_domain,
    chain_position,
    chain_trial,
    chained_schedule,
    export_store,
    load_ledger,
    run_chained,
)
from scripts.eval.e2e_adapter import comparison_fingerprints
from scripts.eval.memory_budget_journal import BudgetJournal
from scripts.eval.model import ValidationError
from scripts.eval.paired_runner import _run_once
from scripts.eval.tests.posix_only import (
    POSIX,
    requires_posix_budget_journal,
    requires_symlinks,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
TASKS = ("a_task", "b_task")
ROLLOUT_COST_USD = 2.0
ROLLOUT_TOKENS = 10_000


def _task(task_id):
    return {
        "id": task_id,
        "scenario": f"{task_id}.txt",
        "layers": ["E", "T", "L", "O", "V"],
        "environment": {"reset": "fresh"},
        "tools": {"profile": "test-tools", "required": []},
        "constraints": {"timeout_seconds": 10, "permission_mode": "default"},
        "success": {"checks": [{"type": "file_exists", "path": "answer.txt"}]},
        "trajectory_constraints": {"max_turns": 2},
        "trajectory_rationale": {"max_turns": "bounded test"},
        "grader": {"kind": "deterministic_workspace", "version": "v1"},
    }


class FakeHarness:
    """Stands in for run_e2e.sh + lib.sh + import_run.

    Each invocation creates a run directory with the scenario's fake HOME,
    imports the offered store the way `import_kg_store` does (sha check,
    extraction, witness), and then 'runs the session', which appends one
    marker naming (arm, task, trial) to the store. `import_run` plays a
    grader that writes into the store too, so a store sealed after the grade
    would show it.
    """

    def __init__(self, root, suite):
        self.root = root
        self.suite = suite
        self.tasks = {task["id"]: task for task in suite["tasks"]}
        self.invocations = []
        self.domains = []
        self.state = {}
        self.events = []
        self.skip_witness = False
        self.cost_usd = 0.25
        # (variant, task_id, trial) -> "witness" | "symlink" | "vanish"
        self.faults = {}

    def run_once(
        self,
        _repo_root,
        binary,
        variant,
        trial,
        selector,
        model_provider,
        model_id,
        _suite_path,
        revision,
        *,
        timeout_seconds=None,
        task_hint=None,
        kg_domain=None,
        store_import=None,
        max_cost_usd=None,
        max_metered_tokens=None,
    ):
        task_id = selector
        assert task_hint == task_id, (task_hint, task_id)
        assert max_cost_usd is not None and max_metered_tokens is not None
        run_dir = self.root / "runs" / f"run-{len(self.invocations)}"
        kg = run_dir / task_id / ".home" / ".metacodes" / "kg"
        kg.mkdir(parents=True)
        fault = self.faults.get((variant, task_id, trial))
        if store_import is not None:
            archive, sha = store_import
            assert hashlib.sha256(Path(archive).read_bytes()).hexdigest() == sha
            with tarfile.open(archive) as handle:
                # The runner wrote this archive; `data` is the strict filter where it exists.
                handle.extractall(kg, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
            if not self.skip_witness:
                witness = "0" * 64 if fault == "witness" else sha
                (run_dir / f"{task_id}.kg-import.sha256").write_text(witness + "\n", encoding="utf-8")
        store = kg / "store.kg.v2"
        if fault != "untouched":
            store.mkdir(exist_ok=True)
            with open(store / "markers.txt", "a", encoding="utf-8") as handle:
                handle.write(f"{variant}:{task_id}:{trial}\n")
        if fault == "symlink":
            os.symlink("/etc/passwd", store / "leak")
        if fault == "vanish":
            shutil.rmtree(store)
        self.invocations.append((variant, trial, task_id, store_import is not None))
        self.domains.append((variant, task_id, trial, kg_domain))
        self.events.append(("run", variant, task_id, trial))
        self.state[run_dir] = (
            binary, variant, trial, task_id, model_provider, model_id, revision,
            max_cost_usd, max_metered_tokens,
        )
        return run_dir

    def export(self, real_export):
        def export(kg_dir, destination):
            # kg_dir is <run_dir>/<task>/.home/.metacodes/kg
            run_dir = kg_dir.parents[3]
            _b, variant, trial, task_id = self.state[run_dir][:4]
            self.events.append(("export", variant, task_id, trial))
            return real_export(kg_dir, destination)

        return export

    def import_run(self, _suite, _repo_root, run_dir):
        (
            binary, variant, trial, task_id, provider, model_id, revision,
            max_cost_usd, max_metered_tokens,
        ) = self.state[run_dir]
        self.events.append(("import", variant, task_id, trial))
        # The grade could write into the store; the sealed archive must not see it.
        markers = run_dir / task_id / ".home" / ".metacodes" / "kg" / "store.kg.v2" / "markers.txt"
        if markers.parent.is_dir():
            with open(markers, "a", encoding="utf-8") as handle:
                handle.write(f"graded:{variant}:{task_id}:{trial}\n")
        task = self.tasks[task_id]
        identity = comparison_fingerprints(
            task,
            self.root,
            model_provider=provider,
            model_id=model_id,
            harness_config_id=variant,
            harness_revision=revision,
            permission_mode=task["constraints"]["permission_mode"],
            binary_path=binary,
        )
        return [
            {
                "schema_version": 1,
                "run_id": f"{variant}:{task_id}:{trial}",
                "suite_id": self.suite["suite_id"],
                "task_id": task_id,
                "task_fingerprint": identity["task_fingerprint"],
                "task_fingerprint_provenance": "recorded_at_execution",
                "trial": trial,
                "layers": task["layers"],
                "model": {"provider": provider, "id": model_id, "fingerprint": identity["model_fingerprint"]},
                "harness": {
                    "config_id": variant,
                    "revision": revision,
                    "fingerprint": identity["harness_fingerprint"],
                    "permission_mode": identity["permission_mode"],
                    "environment_fingerprint": identity["environment_fingerprint"],
                    "runtime_budget": {
                        "max_metered_tokens": max_metered_tokens,
                        "max_cost_usd": float(max_cost_usd),
                    },
                },
                "readiness": {"status": "pass", "checks": []},
                "execution": {"status": "completed", "exit_code": 0, "invalid_reasons": []},
                "outcome": {"status": "pass", "checks": []},
                "trajectory": {"status": "pass", "checks": [], "tool_failures": []},
                "evaluator": {"status": "ready", "kind": "deterministic_workspace", "version": "v1", "fingerprint": identity["grader_fingerprint"], "errors": []},
                "judgement": {"valid_for_scoring": True, "trustworthy_success": True},
                "metrics": {
                    "cost_usd": self.cost_usd,
                    "input_tokens": 100,
                    "output_tokens": 20,
                    "cache_read_tokens": 0,
                    "cache_write_tokens": 0,
                    "wall_time_ms": 1,
                    "policy_violations": 0,
                },
                "attribution": [],
                "artifacts": {},
            }
        ]


@requires_posix_budget_journal
class ChainedRunnerTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        # The journal lives outside the run tree, as run-chained requires.
        self._journal_tmp = tempfile.TemporaryDirectory()
        self.journal = Path(self._journal_tmp.name) / "budget-journal.json"
        for task_id in TASKS:
            (self.root / f"{task_id}.txt").write_text(f"run {task_id}\n", encoding="utf-8")
        self.suite = {"schema_version": 1, "suite_id": "chain-suite", "tasks": [_task(t) for t in TASKS]}
        self.suite_path = self.root / "suite.json"
        self.suite_path.write_text("{}\n", encoding="utf-8")
        self.binaries = {}
        for variant in ("baseline", "candidate"):
            binary = self.root / variant
            binary.write_bytes(f"{variant}-v1".encode())
            binary.chmod(0o755)
            self.binaries[variant] = binary
        self.chain_dir = self.root / "chains"
        self.outputs = self.root / "out"
        self.harness = FakeHarness(self.root, self.suite)

    def tearDown(self):
        self._tmp.cleanup()
        self._journal_tmp.cleanup()

    def run_chains(self, replicates=2, attempts=3, **overrides):
        real_export = export_store
        options = {
            "replicates": replicates,
            "attempts": attempts,
            "scenario_glob": "*",
            "model_provider": "test",
            "model_id": "model-a",
            "baseline_output": self.outputs / "baseline.jsonl",
            "candidate_output": self.outputs / "candidate.jsonl",
            "baseline_revision": "rev-b",
            "candidate_revision": "rev-c",
            "chain_dir": self.chain_dir,
            "budget_journal_path": self.journal,
            "max_cumulative_cost_usd": 100.0,
            "max_cumulative_tokens": 10_000_000,
            "max_rollout_cost_usd": ROLLOUT_COST_USD,
            "max_rollout_metered_tokens": ROLLOUT_TOKENS,
            "suite_path": self.suite_path,
        }
        options.update(overrides)
        with mock.patch(
            "scripts.eval.paired_runner._run_once", side_effect=self.harness.run_once
        ), mock.patch(
            "scripts.eval.chained_runner.import_run", side_effect=self.harness.import_run
        ), mock.patch(
            "scripts.eval.chained_runner.export_store", side_effect=self.harness.export(real_export)
        ):
            return run_chained(
                self.suite,
                self.root,
                self.binaries["baseline"],
                self.binaries["candidate"],
                **options,
            )

    def markers(self, variant, task_id, replicate, attempt):
        archive = self.chain_dir / variant / task_id / f"r{replicate}" / f"attempt-{attempt}.tar"
        with tarfile.open(archive) as handle:
            member = handle.extractfile("store.kg.v2/markers.txt")
            return member.read().decode("utf-8").splitlines()

    def journal_snapshot(self):
        """Replay the durable journal without its authority (read-only)."""
        from scripts.eval.memory_budget_journal import validate_checkpoint_payload

        state = validate_checkpoint_payload(self.journal.read_bytes())
        states = {}
        for transaction in state["transactions"].values():
            states[transaction["state"]] = states.get(transaction["state"], 0) + 1
        return state, states

    def test_trial_mapping_round_trips(self):
        for replicate in range(3):
            for attempt in range(1, 4):
                trial = chain_trial(replicate, attempt, 3)
                self.assertEqual(chain_position(trial, 3), (replicate, attempt))
        self.assertEqual(chain_trial(1, 1, 3), 3)
        with self.assertRaises(ValidationError):
            chain_trial(0, 4, 3)

    def test_schedule_advances_attempt_levels_together_and_balances_arm_order(self):
        schedule = chained_schedule(["b", "a"], replicates=2, attempts=2)
        self.assertEqual(len(schedule), 2 * 2 * 2 * 2)
        # Every chain's attempt 1 precedes any attempt 2 of the same replicate.
        for replicate in range(2):
            levels = [attempt for r, attempt, _t, _v in schedule if r == replicate]
            self.assertEqual(levels, sorted(levels))
        firsts = {}
        for replicate, attempt, task, variant in schedule:
            firsts.setdefault((replicate, attempt, task), variant)
        self.assertEqual(firsts[(0, 1, "a")], "baseline")
        self.assertEqual(firsts[(0, 1, "b")], "candidate")
        self.assertEqual(firsts[(1, 1, "a")], "candidate")
        self.assertEqual(firsts[(1, 1, "b")], "baseline")
        with self.assertRaises(ValidationError):
            chained_schedule(["a"], replicates=0, attempts=2)

    def test_store_carries_within_a_chain_and_never_across_chains_or_arms(self):
        baseline, candidate = self.run_chains(replicates=2, attempts=3)
        self.assertEqual(len(baseline), 2 * 2 * 3)
        self.assertEqual(len(candidate), 2 * 2 * 3)
        for variant in ("baseline", "candidate"):
            for task_id in TASKS:
                for replicate in range(2):
                    trials = [chain_trial(replicate, k, 3) for k in range(1, 4)]
                    expected = [f"{variant}:{task_id}:{t}" for t in trials]
                    # Attempt k's store holds exactly this chain's attempts 1..k.
                    for attempt in range(1, 4):
                        self.assertEqual(
                            self.markers(variant, task_id, replicate, attempt),
                            expected[:attempt],
                        )
        # Attempt 1 of every chain imported nothing; every later attempt did.
        for variant, trial, _task_id, imported in self.harness.invocations:
            self.assertEqual(imported, chain_position(trial, 3)[1] > 1)

    def test_every_attempt_at_a_task_runs_in_one_kg_domain(self):
        """The default domain follows the workspace's git root, a new run
        directory every attempt; lessons are project-scoped, so without one
        fixed domain attempt k+1 recalls nothing attempt k wrote."""
        self.run_chains(replicates=2, attempts=3)
        by_task = {}
        for variant, task_id, _trial, domain in self.harness.domains:
            by_task.setdefault(task_id, set()).add(domain)
        # One domain per task: every attempt, replicate and arm of it.
        self.assertEqual(by_task, {task_id: {chain_kg_domain(task_id)} for task_id in TASKS})
        self.assertEqual(
            sum(1 for _v, task_id, _t, _d in self.harness.domains if task_id == "a_task"),
            2 * 2 * 3,
        )
        # Different tasks never share one, and no domain names an arm.
        self.assertNotEqual(chain_kg_domain("a_task"), chain_kg_domain("b_task"))
        for domain in (chain_kg_domain(task_id) for task_id in TASKS):
            self.assertNotIn("baseline", domain)
            self.assertNotIn("candidate", domain)
            self.assertRegex(domain, r"^[a-z_]+-[0-9a-f]{8}$")
        rows = load_ledger(self.chain_dir / "baseline" / "ledger.jsonl", "baseline")
        self.assertEqual({row.kg_domain for row in rows if row.task_id == "b_task"}, {chain_kg_domain("b_task")})
        with self.assertRaisesRegex(ValidationError, "cannot name a TinyKG domain"):
            chain_kg_domain("two words")

    def test_ledger_links_every_attempt_to_the_export_before_it(self):
        self.run_chains(replicates=1, attempts=3)
        rows = load_ledger(self.chain_dir / "candidate" / "ledger.jsonl", "candidate")
        self.assertEqual(len(rows), len(TASKS) * 3)
        self.assertTrue(all(isinstance(row, LedgerRow) for row in rows))
        by_key = {(row.task_id, row.attempt): row for row in rows}
        for task_id in TASKS:
            self.assertIsNone(by_key[(task_id, 1)].store_import_sha256)
            for attempt in (2, 3):
                self.assertEqual(
                    by_key[(task_id, attempt)].store_import_sha256,
                    by_key[(task_id, attempt - 1)].store_export_sha256,
                )
            self.assertEqual(by_key[(task_id, 3)].store_entries, ("store.kg.v2",))
        raw = json.loads((self.chain_dir / "candidate" / "ledger.jsonl").read_text().splitlines()[0])
        self.assertEqual(raw["schema_version"], LEDGER_SCHEMA)
        self.assertEqual(raw["status"], "exported")

    def test_store_is_exported_before_the_offline_grade_runs(self):
        self.run_chains(replicates=1, attempts=2)
        rows = load_ledger(self.chain_dir / "baseline" / "ledger.jsonl", "baseline")
        self.assertEqual(len(rows), len(TASKS) * 2)
        # run -> export -> import for every attempt, in that order.
        self.assertEqual(
            [event[0] for event in self.harness.events],
            ["run", "export", "import"] * (len(TASKS) * 2 * 2),
        )
        for first, second, third in zip(*[iter(self.harness.events)] * 3):
            self.assertEqual(first[1:], second[1:])
            self.assertEqual(second[1:], third[1:])
        # The grade's write to the store reached no archive, not even the
        # attempt after it (which imports the sealed store, not the graded one).
        for variant in ("baseline", "candidate"):
            for task_id in TASKS:
                for attempt in (1, 2):
                    markers = self.markers(variant, task_id, 0, attempt)
                    self.assertFalse([m for m in markers if m.startswith("graded:")], markers)

    def test_every_attempt_is_reserved_and_committed_in_the_budget_journal(self):
        baseline, candidate = self.run_chains(replicates=1, attempts=2)
        state, states = self.journal_snapshot()
        self.assertEqual(states, {"committed": len(TASKS) * 2 * 2})
        committed = sum(t["actual_cost_microusd"] for t in state["transactions"].values())
        self.assertEqual(committed, len(TASKS) * 2 * 2 * 250_000)
        for t in state["transactions"].values():
            self.assertEqual(t["identity"]["max_cost_microusd"], 2_000_000)
            self.assertEqual(t["identity"]["max_metered_tokens"], ROLLOUT_TOKENS)
        rows = {
            (row.task_id, row.trial): row
            for variant in ("baseline", "candidate")
            for row in load_ledger(self.chain_dir / variant / "ledger.jsonl", variant)
            if row.variant == "baseline"
        }
        for rollout in baseline:
            receipt = rollout["budget_transaction"]
            self.assertEqual(receipt["state"], "committed")
            self.assertEqual(
                receipt["transaction_id"],
                rows[(rollout["task_id"], rollout["trial"])].budget_transaction_id,
            )
        # A resume of the finished run reopens every receipt and runs nothing.
        before = len(self.harness.invocations)
        self.run_chains(replicates=1, attempts=2)
        self.assertEqual(len(self.harness.invocations), before)

    def test_resume_continues_the_chain_without_repeating_a_paid_attempt(self):
        # An interruption between attempts: the sixth reservation never lands.
        real_reserve = BudgetJournal.reserve
        calls = []

        def interrupted(journal, transaction):
            calls.append(transaction.run_id)
            if len(calls) == 6:
                raise KeyboardInterrupt("simulated interruption")
            return real_reserve(journal, transaction)

        with mock.patch.object(BudgetJournal, "reserve", autospec=True, side_effect=interrupted):
            with self.assertRaises(KeyboardInterrupt):
                self.run_chains(replicates=1, attempts=3)
        done = list(self.harness.invocations)
        self.assertEqual(len(done), 5)
        self.run_chains(replicates=1, attempts=3)
        resumed = self.harness.invocations[len(done):]
        self.assertEqual(len(done) + len(resumed), len(TASKS) * 2 * 3)
        self.assertFalse(set(done) & set(resumed))
        for variant in ("baseline", "candidate"):
            for task_id in TASKS:
                self.assertEqual(
                    self.markers(variant, task_id, 0, 3),
                    [f"{variant}:{task_id}:{t}" for t in range(3)],
                )

    def _assert_failed_attempt_is_never_rerun(self, fault, error):
        key = ("baseline", 1, "a_task")
        self.harness.faults[("baseline", "a_task", 1)] = fault
        with self.assertRaisesRegex(ValidationError, error):
            self.run_chains(replicates=1, attempts=2)
        rows = load_ledger(self.chain_dir / "baseline" / "ledger.jsonl", "baseline")
        failed = [row for row in rows if isinstance(row, FailedAttempt)]
        self.assertEqual([(row.task_id, row.trial) for row in failed], [("a_task", 1)])
        # The paid attempt stays charged at its whole allowance.
        state, states = self.journal_snapshot()
        self.assertEqual(states.get("request_authorized"), 1)
        authorized = [
            t for t in state["transactions"].values() if t["state"] == "request_authorized"
        ]
        self.assertEqual(authorized[0]["transaction_id"], failed[0].budget_transaction_id)
        self.assertEqual(authorized[0]["identity"]["max_cost_microusd"], 2_000_000)
        # Resume refuses the chain: the attempt ran once and only once.
        with self.assertRaisesRegex(ValidationError, "never repeated automatically"):
            self.run_chains(replicates=1, attempts=2)
        runs = [(v, t, k) for v, t, k, _i in self.harness.invocations]
        self.assertEqual(runs.count(key), 1)

    def test_an_import_witness_mismatch_is_never_rerun(self):
        self._assert_failed_attempt_is_never_rerun("witness", "does not match the chain")

    @requires_symlinks
    def test_a_store_the_export_refuses_is_never_rerun(self):
        self._assert_failed_attempt_is_never_rerun("symlink", "not a regular file")

    def test_a_vanished_store_is_never_rerun(self):
        self._assert_failed_attempt_is_never_rerun("vanish", "imported store vanished")

    def test_attempts_that_never_open_tinykg_still_advance_the_chain(self):
        # A session that writes no memory leaves no store: attempt 1 exports
        # an empty archive and attempt 2 imports it, which is not a vanished store.
        for trial in (0, 1, 2):
            self.harness.faults[("baseline", "a_task", trial)] = "untouched"
        baseline, _candidate = self.run_chains(replicates=1, attempts=3)
        self.assertEqual(len(baseline), len(TASKS) * 3)
        rows = [
            row
            for row in load_ledger(self.chain_dir / "baseline" / "ledger.jsonl", "baseline")
            if row.task_id == "a_task"
        ]
        self.assertEqual([row.store_entries for row in rows], [(), (), ()])
        self.assertEqual(rows[1].store_import_sha256, rows[0].store_export_sha256)

    def test_a_killed_runner_leaves_a_charged_transaction_that_resume_refuses(self):
        self.harness.faults[("baseline", "a_task", 1)] = "witness"
        with self.assertRaises(ValidationError):
            self.run_chains(replicates=1, attempts=2)
        # A runner killed before it could record the failure leaves no row.
        ledger = self.chain_dir / "baseline" / "ledger.jsonl"
        lines = ledger.read_text(encoding="utf-8").splitlines(keepends=True)
        self.assertEqual(json.loads(lines[-1])["status"], "failed")
        ledger.write_text("".join(lines[:-1]), encoding="utf-8")
        with self.assertRaisesRegex(ValidationError, "replay is forbidden"):
            self.run_chains(replicates=1, attempts=2)
        runs = [(v, t, k) for v, t, k, _i in self.harness.invocations]
        self.assertEqual(runs.count(("baseline", 1, "a_task")), 1)

    def test_the_cumulative_cap_stops_the_run_before_the_next_reservation(self):
        # $1 per attempt, a $2 allowance and a $5 cap: the fifth reservation
        # would expose $4 + $2 > $5.
        self.harness.cost_usd = 1.0
        with self.assertRaisesRegex(ValidationError, "would exceed the cumulative cost cap"):
            self.run_chains(replicates=1, attempts=3, max_cumulative_cost_usd=5.0)
        self.assertEqual(len(self.harness.invocations), 4)
        _state, states = self.journal_snapshot()
        self.assertEqual(states, {"committed": 4})
        with self.assertRaisesRegex(ValidationError, "would exceed the cumulative cost cap"):
            self.run_chains(replicates=1, attempts=3, max_cumulative_cost_usd=5.0)
        self.assertEqual(len(self.harness.invocations), 4)

    def test_caps_are_required_and_validated_like_run_paired(self):
        bad = {
            "max_cumulative_cost_usd": (None, math.nan, math.inf, 0.0, -1.0, 1.0),
            "max_cumulative_tokens": (None, 0, -1, ROLLOUT_TOKENS - 1),
            "max_rollout_cost_usd": (None, math.nan, math.inf, 0.0, -2.0, 101.0),
            "max_rollout_metered_tokens": (None, 0, -1, 10_000_001),
            "budget_used_cost_usd": (math.nan, -1.0),
            "budget_used_tokens": (-1,),
        }
        for name, values in bad.items():
            for value in values:
                with self.subTest(name=name, value=value):
                    with self.assertRaises(ValidationError):
                        self.run_chains(replicates=1, attempts=1, **{name: value})
        # Offsets that already spend the whole cap leave no authority.
        with self.assertRaisesRegex(ValidationError, "exhaust"):
            self.run_chains(replicates=1, attempts=1, budget_used_cost_usd=100.0)
        self.assertEqual(self.harness.invocations, [])
        self.assertFalse(self.journal.exists())

    def test_the_budget_journal_is_required_and_outside_the_run_tree(self):
        with self.assertRaisesRegex(ValidationError, "budget journal"):
            self.run_chains(replicates=1, attempts=1, budget_journal_path=None)
        for inside in (self.chain_dir / "journal.json", self.outputs / "journal.json"):
            with self.subTest(journal=inside):
                with self.assertRaisesRegex(ValidationError, "outside the chain directory"):
                    self.run_chains(replicates=1, attempts=1, budget_journal_path=inside)
        self.assertEqual(self.harness.invocations, [])

    def test_a_changed_archive_fails_closed_on_resume(self):
        self.run_chains(replicates=1, attempts=2)
        archive = self.chain_dir / "baseline" / "a_task" / "r0" / "attempt-1.tar"
        archive.write_bytes(archive.read_bytes() + b"\0")
        with self.assertRaisesRegex(ValidationError, "missing or changed"):
            self.run_chains(replicates=1, attempts=2)

    def test_a_ledger_row_without_its_rollout_fails_closed(self):
        self.run_chains(replicates=1, attempts=2)
        output = self.outputs / "baseline.jsonl"
        lines = output.read_text(encoding="utf-8").splitlines(keepends=True)
        output.write_text("".join(lines[:-1]), encoding="utf-8")
        with self.assertRaisesRegex(ValidationError, "ledger and rollout checkpoint disagree"):
            self.run_chains(replicates=1, attempts=2)

    def test_a_missing_import_witness_stops_before_the_next_attempt(self):
        self.harness.skip_witness = True
        with self.assertRaisesRegex(ValidationError, "no store import witness"):
            self.run_chains(replicates=1, attempts=2)
        # Attempt 1 of each chain ran; the first attempt 2 was not completed.
        self.assertEqual(sum(1 for _v, t, _k, _i in self.harness.invocations if t == 1), 1)

    def test_export_is_deterministic_and_empty_without_a_store(self):
        kg = self.root / "kg"
        (kg / "store.kg.v2" / "sub").mkdir(parents=True)
        (kg / "store.kg.v2" / "sub" / "data").write_bytes(b"x" * 10)
        (kg / "daemon.json").write_text("{}", encoding="utf-8")
        first = export_store(kg, self.root / "one.tar")
        second = export_store(kg, self.root / "two.tar")
        self.assertEqual(first[0], second[0])
        self.assertEqual(first[1], ["store.kg.v2"])
        with tarfile.open(self.root / "one.tar") as handle:
            self.assertEqual(handle.getnames(), ["store.kg.v2", "store.kg.v2/sub", "store.kg.v2/sub/data"])
        empty = export_store(self.root / "nothing", self.root / "empty.tar")
        self.assertEqual(empty[1], [])

    @requires_symlinks
    def test_export_refuses_a_symlink_planted_in_the_store(self):
        kg = self.root / "kg"
        (kg / "store.kg").mkdir(parents=True)
        os.symlink("/etc/passwd", kg / "store.kg" / "leak")
        with self.assertRaisesRegex(ValidationError, "not a regular file"):
            export_store(kg, self.root / "out.tar")


class RunOnceChainEnvironmentTest(unittest.TestCase):
    """`_run_once` hands the chain's task hint, domain and store import to the
    harness, and no host value of either variable gets through."""

    def test_run_once_passes_task_hint_domain_and_store_import_to_the_harness(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runs = root / "tests" / "e2e" / "runs"
            runs.mkdir(parents=True)
            runner = root / "tests" / "e2e" / "run_e2e.sh"
            runner.write_text("#!/bin/sh\n", encoding="utf-8")
            runner.chmod(0o755)
            binary = root / "binary"
            binary.write_bytes(b"bin")
            binary.chmod(0o755)
            suite_path = root / "suite.json"
            suite_path.write_text("{}\n", encoding="utf-8")
            archive = root / "store.tar"
            archive.write_bytes(b"tar")
            sha = hashlib.sha256(b"tar").hexdigest()
            created = []

            def fake_run(*_args, **_kwargs):
                run_dir = runs / f"run-{len(created)}"
                run_dir.mkdir()
                created.append(run_dir)
                return mock.Mock(returncode=0)

            host = {"METACODES_TASK_HINT": "host-leak", "METACODES_KG_DOMAIN": "host-leak"}
            with mock.patch.dict(os.environ, host), mock.patch(
                "scripts.eval.paired_runner.subprocess.run", side_effect=fake_run
            ) as patched:
                _run_once(
                    root, binary, "baseline", 1, "a_task", "anthropic", "m", suite_path, "rev",
                    task_hint="a_task",
                    kg_domain=chain_kg_domain("a_task"),
                    store_import=(archive, sha),
                )
                env = patched.call_args.kwargs["env"]
                self.assertEqual(env["METACODES_TASK_HINT"], "a_task")
                self.assertEqual(env["METACODES_KG_DOMAIN"], chain_kg_domain("a_task"))
                self.assertEqual(env["E2E_KG_STORE_IMPORT"], str(archive.resolve()))
                self.assertEqual(env["E2E_KG_STORE_IMPORT_SHA256"], sha)
                # Without the keywords the host's values are dropped, not passed.
                _run_once(root, binary, "baseline", 2, "a_task", "anthropic", "m", suite_path, "rev")
                env = patched.call_args.kwargs["env"]
                self.assertNotIn("METACODES_TASK_HINT", env)
                self.assertNotIn("METACODES_KG_DOMAIN", env)
                for name, value in (("task_hint", "two words"), ("kg_domain", "two words"), ("kg_domain", "")):
                    with self.subTest(name=name, value=value):
                        with self.assertRaises(ValidationError):
                            _run_once(
                                root, binary, "baseline", 3, "a_task", "anthropic", "m",
                                suite_path, "rev", **{name: value},
                            )


class RunChainedCliTest(unittest.TestCase):
    """The CLI cannot start a chained run without the journal and all caps."""

    REQUIRED = {
        "--suite": "evals/suites/check-gate-v3.json",
        "--baseline-binary": "b",
        "--candidate-binary": "c",
        "--baseline-revision": "rb",
        "--candidate-revision": "rc",
        "--replicates": "1",
        "--attempts": "2",
        "--chain-dir": "evals/runs/chains",
        "--baseline-output": "evals/runs/baseline.jsonl",
        "--candidate-output": "evals/runs/candidate.jsonl",
        "--budget-journal": "/private/journal.json",
        "--max-cumulative-cost-usd": "10",
        "--max-cumulative-tokens": "1000000",
        "--max-rollout-cost-usd": "2",
        "--max-rollout-metered-tokens": "100000",
    }

    def argv(self, without=None):
        argv = ["run-chained"]
        for flag, value in self.REQUIRED.items():
            if flag != without:
                argv += [flag, value]
        return argv

    def test_every_budget_flag_is_required(self):
        args = cli.parser().parse_args(self.argv())
        self.assertEqual(args.budget_journal, "/private/journal.json")
        for flag in (
            "--budget-journal",
            "--max-cumulative-cost-usd",
            "--max-cumulative-tokens",
            "--max-rollout-cost-usd",
            "--max-rollout-metered-tokens",
        ):
            with self.subTest(flag=flag), mock.patch("sys.stderr"):
                with self.assertRaises(SystemExit):
                    cli.parser().parse_args(self.argv(without=flag))


@unittest.skipUnless(POSIX, "tests/e2e/lib.sh is a bash harness")
class LibImportKgStoreTest(unittest.TestCase):
    """`import_kg_store` in tests/e2e/lib.sh, sourced and called directly."""

    def call(self, home, witness, archive=None, sha=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("E2E_")}
        if archive is not None:
            env["E2E_KG_STORE_IMPORT"] = str(archive)
            env["E2E_KG_STORE_IMPORT_SHA256"] = sha
        script = (
            'source "$1"; import_kg_store "$2" "$3"; rc=$?; '
            'printf "rc=%s left=%s%s\\n" "$rc" "${E2E_KG_STORE_IMPORT:-}" "${E2E_KG_STORE_IMPORT_SHA256:-}"'
        )
        return subprocess.run(
            ["bash", "-c", script, "bash", str(REPO_ROOT / "tests/e2e/lib.sh"), str(home), str(witness)],
            env=env,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

    def test_import_extracts_the_store_and_writes_the_witness(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "kg"
            (source / "store.kg.v2").mkdir(parents=True)
            (source / "store.kg.v2" / "data").write_text("lesson", encoding="utf-8")
            sha, _entries, _size = export_store(source, root / "store.tar")
            home = root / "home"
            witness = root / "task.kg-import.sha256"
            self.assertEqual(self.call(home, witness, root / "store.tar", sha), "rc=0 left=")
            self.assertEqual(
                (home / ".metacodes" / "kg" / "store.kg.v2" / "data").read_text(encoding="utf-8"),
                "lesson",
            )
            self.assertEqual(witness.read_text(encoding="utf-8").strip(), sha)

    def test_a_wrong_hash_imports_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "kg" / "store.kg").mkdir(parents=True)
            export_store(root / "kg", root / "store.tar")
            home = root / "home"
            witness = root / "w"
            out = self.call(home, witness, root / "store.tar", "0" * 64)
            self.assertTrue(out.startswith("rc=1"), out)
            self.assertTrue(out.endswith("left="), out)
            self.assertFalse((home / ".metacodes" / "kg").exists())
            self.assertFalse(witness.exists())

    def test_without_an_import_it_does_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(self.call(root / "home", root / "w"), "rc=0 left=")
            self.assertFalse((root / "home").exists())
            self.assertFalse((root / "w").exists())


if __name__ == "__main__":
    unittest.main()
