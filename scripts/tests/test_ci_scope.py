"""scripts/ci_scope.py and how ci.yml uses it (doc/CI_DESIGN.md §2-§3).

The classification is a pure function of the changed paths. The workflow
tests pin the wiring: which `gates` steps still run on a documentation-only
change, that every other step of a required job reads its scope, that the
scope fails open, and that the decision steps pick the right base for a pull
request, a merge queue group and a push."""
from __future__ import annotations

import io
import os
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_scope  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
AGENTCORE_WORKFLOW = ROOT / ".github" / "workflows" / "agentcore-windows.yml"
# The runner's own bash invocation for `run:` steps.
BASH = ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c"]
CHECKOUT = "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
# The `gates` steps that also run on a documentation-only change. A new step
# must either read SUITES or be added here on purpose.
DOC_STEPS = {
    "Release fast path",
    "Change scope",
    CHECKOUT,
    "Install Python development dependencies",
    "Version state gate and release rehearsal",
    "Documentation link check",
    "Documentation fact check",
    "Documentation fact-check unit tests",
    "Gate manifest unit tests",
    "Diff whitespace check",
}
ECHO_STEPS = {"Release fast path", "Change scope"}


class ClassifyTest(unittest.TestCase):
    def test_documentation_alone_is_the_docs_scope(self) -> None:
        for paths in (["doc/API.md"], ["ROADMAP.md", "doc/README.md"], ["AGENTS.md"], ["doc/history/X.md"]):
            with self.subTest(paths=paths):
                self.assertEqual(ci_scope.classify(paths)[0], "docs")

    def test_markdown_the_release_layout_installs_is_not_documentation(self) -> None:
        # build.zig installs these into share/doc and share/licenses, and
        # gen_third_party_notices.py --check regenerates the notices.
        for path in ("README.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md"):
            with self.subTest(path=path):
                self.assertEqual(ci_scope.classify([path])[0], "full")
                self.assertEqual(ci_scope.classify(["doc/API.md", path])[0], "full")

    def test_every_top_level_file_build_zig_installs_is_excluded(self) -> None:
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        installed = set(re.findall(r'\.source = "([^"/]+\.md)"', build))
        self.assertIn("THIRD_PARTY_NOTICES.md", installed)  # the pattern still finds them
        self.assertEqual(installed - set(ci_scope.RELEASE_DOCS), set())

    def test_a_removed_documentation_file_is_the_full_scope(self) -> None:
        # evals/plugin-v1/protocol.json pins doc paths that zig build test resolves.
        scope, reason = ci_scope.classify(["doc/CORE_REFERENCE.md", "doc/history/CORE_REFERENCE.md"],
                                          deleted=["doc/CORE_REFERENCE.md"])
        self.assertEqual(scope, "full")
        self.assertIn("doc/CORE_REFERENCE.md removed", reason)
        # Removing harness files keeps the eval scope; only doc removals widen it.
        self.assertEqual(ci_scope.classify(["scripts/eval/old.py"], deleted=["scripts/eval/old.py"])[0], "eval")

    def test_markdown_outside_doc_and_the_top_level_is_an_input(self) -> None:
        # Prompt templates are @embedFile'd; agent and Skill fixtures are read by tests.
        for path in ("src/core/templates/compact/prompt.md", "tests/e2e/fixtures/agents/release-mcp.md", "sdk/README.md"):
            with self.subTest(path=path):
                self.assertEqual(ci_scope.classify([path])[0], "full")

    def test_the_evaluation_harness_is_the_eval_scope(self) -> None:
        for paths in (["scripts/eval/chained_runner.py"], ["evals/experiments/learning-turn-v1.md"],
                      ["evals/validators/d1_check_gate_v3_cron.py", "doc/README.md"]):
            with self.subTest(paths=paths):
                self.assertEqual(ci_scope.classify(paths)[0], "eval")

    def test_anything_else_is_the_full_scope_and_is_named(self) -> None:
        scope, reason = ci_scope.classify(["scripts/eval/cli.py", "src/main.zig"])
        self.assertEqual(scope, "full")
        self.assertIn("src/main.zig", reason)
        self.assertNotIn("scripts/eval/cli.py", reason)
        for path in ("build.zig", "scripts/release_cut.py", ".github/workflows/ci.yml", "tests/tty/tty_driver.py", "scripts/evaluate.py"):
            with self.subTest(path=path):
                self.assertEqual(ci_scope.classify([path])[0], "full")

    def test_no_paths_is_the_full_scope(self) -> None:
        self.assertEqual(ci_scope.classify([])[0], "full")

    def test_outputs_fail_open(self) -> None:
        self.assertEqual(ci_scope.outputs("docs"), (False, False))
        self.assertEqual(ci_scope.outputs("eval"), (True, False))
        self.assertEqual(ci_scope.outputs("full"), (True, True))


class DecideTest(unittest.TestCase):
    def test_push_and_manual_runs_are_full_without_a_diff(self) -> None:
        def no_diff(base: str, candidate: str):
            raise AssertionError("a push run must not diff")

        for event in ("push", "workflow_dispatch", ""):
            with self.subTest(event=event):
                self.assertEqual(ci_scope.decide(event, "abc", "HEAD", no_diff)[0], "full")

    def test_pull_requests_and_merge_groups_diff_against_their_base(self) -> None:
        seen = []

        def diff(base: str, candidate: str):
            seen.append((base, candidate))
            return [("M", "doc/API.md")]

        self.assertEqual(ci_scope.decide("pull_request", "HEAD^1", "HEAD", diff)[0], "docs")
        self.assertEqual(ci_scope.decide("merge_group", "a" * 40, "HEAD", diff)[0], "docs")
        self.assertEqual(seen, [("HEAD^1", "HEAD"), ("a" * 40, "HEAD")])

    def test_a_missing_base_or_a_failing_diff_is_the_full_scope(self) -> None:
        def broken(base: str, candidate: str):
            raise RuntimeError("bad object")

        self.assertEqual(ci_scope.decide("merge_group", "", "HEAD", broken)[0], "full")
        scope, reason = ci_scope.decide("merge_group", "a" * 40, "HEAD", broken)
        self.assertEqual(scope, "full")
        self.assertIn("bad object", reason)


class MainTest(unittest.TestCase):
    """The real `git diff` of a fixture repository, through main()."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "ci")
        (self.repo / "doc").mkdir()
        (self.repo / "doc" / "A.md").write_text("a\n", encoding="utf-8")
        (self.repo / "main.zig").write_text("x\n", encoding="utf-8")
        self.commit("base")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def git(self, *argv: str) -> str:
        return subprocess.run(["git", *argv], cwd=str(self.repo), check=True, capture_output=True, text=True).stdout

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def run_main(self, event: str, base: str) -> dict:
        out = self.repo / "github-output"
        out.write_text("", encoding="utf-8")
        with redirect_stdout(io.StringIO()):
            code = ci_scope.main(["--event", event, "--base", base, "--candidate", "HEAD",
                                  "--github-output", str(out), "--repo-root", str(self.repo)])
        self.assertEqual(code, 0)
        return dict(line.split("=", 1) for line in out.read_text(encoding="utf-8").splitlines())

    def test_a_documentation_change_skips_the_suites(self) -> None:
        (self.repo / "doc" / "A.md").write_text("b\n", encoding="utf-8")
        self.commit("docs")
        got = self.run_main("pull_request", "HEAD^1")
        self.assertEqual((got["scope"], got["suites"], got["tty"]), ("docs", "false", "false"))

    def test_a_rename_out_of_doc_is_the_full_scope(self) -> None:
        self.git("mv", "doc/A.md", "notes.zig")
        self.commit("rename")
        got = self.run_main("merge_group", self.git("rev-parse", "HEAD^1").strip())
        self.assertEqual((got["scope"], got["suites"], got["tty"]), ("full", "true", "true"))

    def test_a_move_within_doc_is_the_full_scope(self) -> None:
        (self.repo / "doc" / "history").mkdir()
        self.git("mv", "doc/A.md", "doc/history/A.md")
        self.commit("retire")
        got = self.run_main("pull_request", "HEAD^1")
        self.assertEqual((got["scope"], got["suites"], got["tty"]), ("full", "true", "true"))
        self.assertIn("doc/A.md removed", got["reason"])

    def test_an_added_documentation_file_keeps_the_docs_scope(self) -> None:
        (self.repo / "doc" / "B.md").write_text("b\n", encoding="utf-8")
        self.commit("add")
        self.assertEqual(self.run_main("pull_request", "HEAD^1")["scope"], "docs")

    def test_an_unknown_base_is_the_full_scope_and_exits_zero(self) -> None:
        got = self.run_main("merge_group", "0" * 40)
        self.assertEqual((got["scope"], got["suites"], got["tty"]), ("full", "true", "true"))
        self.assertIn("scope check failed", got["reason"])


def load_workflow():
    try:
        import yaml
    except ImportError:  # requirements-dev.txt
        raise unittest.SkipTest("PyYAML is not installed")
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def step_label(step: dict) -> str:
    return step.get("name") or step.get("uses", "")


class WorkflowTest(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = load_workflow()
        self.jobs = self.workflow["jobs"]

    def test_the_merge_queue_runs_the_workflow(self) -> None:
        triggers = self.workflow.get("on", self.workflow.get(True))  # YAML 1.1 reads `on` as true
        self.assertIn("merge_group", triggers)

    def test_every_required_job_reads_its_scope(self) -> None:
        for job, var in (("gates", "SUITES"), ("windows-gates", "SUITES"), ("tty", "TTY")):
            with self.subTest(job=job):
                spec = self.jobs[job]
                self.assertEqual(sorted(spec["needs"]), ["release-fast-path", "scope"])
                self.assertEqual(spec["if"], "${{ !cancelled() }}")
                self.assertEqual(spec["env"][var], "${{ needs.scope.outputs.%s }}" % var.lower())

    def test_only_the_documentation_checks_run_on_a_docs_change(self) -> None:
        running = set()
        for step in self.jobs["gates"]["steps"]:
            condition = step.get("if", "")
            if "env.SUITES != 'false'" not in condition:
                running.add(step_label(step))
            else:
                self.assertIn("env.FAST_PATH != 'true'", condition, step_label(step))
        self.assertEqual(running, DOC_STEPS)

    def test_every_other_step_of_a_required_job_fails_open(self) -> None:
        for job, var in (("windows-gates", "SUITES"), ("tty", "TTY")):
            for step in self.jobs[job]["steps"]:
                label = step_label(step)
                if label in ECHO_STEPS:
                    continue
                with self.subTest(job=job, step=label):
                    # `!= 'false'`, never `== 'true'`: an empty output (the
                    # scope job failed) runs the step.
                    self.assertIn("env.%s != 'false'" % var, step.get("if", ""))
                    self.assertIn("env.FAST_PATH != 'true'", step.get("if", ""))

    def run_decide(self, job: str, event: str) -> tuple:
        step = next(s for s in self.jobs[job]["steps"] if s.get("name") == "Decide")
        with tempfile.TemporaryDirectory() as tmp:
            bindir = Path(tmp) / "bin"
            bindir.mkdir()
            log = Path(tmp) / "calls.log"
            for name in ("git", "python3"):
                fake = bindir / name
                fake.write_text('#!/bin/sh\necho "%s $*" >> "$FAKE_LOG"\n' % name, encoding="utf-8")
                fake.chmod(0o755)
            output = Path(tmp) / "github-output"
            output.write_text("", encoding="utf-8")
            env = dict(os.environ, PATH=f"{bindir}{os.pathsep}{os.environ['PATH']}", FAKE_LOG=str(log),
                       GITHUB_EVENT_NAME=event, GITHUB_OUTPUT=str(output), GITHUB_REPOSITORY="o/r",
                       MERGE_GROUP_BASE_SHA="b" * 40 if event == "merge_group" else "")
            proc = subprocess.run([*BASH, step["run"]], env=env, capture_output=True, text=True)
            calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
            return proc, calls, output.read_text(encoding="utf-8")

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_each_decision_takes_the_base_of_its_event(self) -> None:
        for job, script in (("release-fast-path", "scripts/release_fast_path.py"), ("scope", "scripts/ci_scope.py")):
            with self.subTest(job=job, event="pull_request"):
                proc, calls, _ = self.run_decide(job, "pull_request")
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(len(calls), 1, calls)
                self.assertTrue(calls[0].startswith(f"python3 {script} "), calls)
                self.assertIn("--base HEAD^1 --candidate HEAD", calls[0])
            with self.subTest(job=job, event="merge_group"):
                proc, calls, _ = self.run_decide(job, "merge_group")
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(calls[0], "git fetch -q --no-tags --depth=1 origin " + "b" * 40)
                self.assertIn("--base %s --candidate HEAD" % ("b" * 40), calls[1])

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_a_push_run_takes_the_full_path(self) -> None:
        proc, calls, output = self.run_decide("release-fast-path", "push")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls, [])
        self.assertIn("fast=false", output)
        proc, calls, _ = self.run_decide("scope", "push")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(calls), 1, calls)
        self.assertTrue(calls[0].startswith("python3 scripts/ci_scope.py --event push --base  --candidate HEAD "), calls)



class AgentCoreWorkflowTest(unittest.TestCase):
    """agentcore-windows.yml's scope step, with its `${{ }}` expressions
    rendered the way the runner renders them."""

    def setUp(self) -> None:
        try:
            import yaml
        except ImportError:  # requirements-dev.txt
            self.skipTest("PyYAML is not installed")
        workflow = yaml.safe_load(AGENTCORE_WORKFLOW.read_text(encoding="utf-8"))
        self.workflow = workflow
        self.step = next(s for s in workflow["jobs"]["native-windows-gate"]["steps"] if s.get("id") == "scope")

    def test_the_merge_queue_runs_the_workflow(self) -> None:
        self.assertIn("merge_group", self.workflow.get("on", self.workflow.get(True)))

    def render(self, event: str) -> str:
        values = {
            "github.event_name": event,
            "github.event.pull_request.base.sha": "p" * 40 if event == "pull_request" else "",
            "github.event.merge_group.base_sha": "m" * 40 if event == "merge_group" else "",
        }
        rendered = re.sub(r"\$\{\{\s*([^}]+?)\s*\}\}", lambda m: values[m.group(1)], self.step["run"])
        self.assertNotIn("${{", rendered)
        return rendered

    def run_step(self, event: str, changed: str) -> tuple:
        with tempfile.TemporaryDirectory() as tmp:
            bindir = Path(tmp) / "bin"
            bindir.mkdir()
            log = Path(tmp) / "calls.log"
            fake = bindir / "git"
            fake.write_text('#!/bin/sh\necho "git $*" >> "$FAKE_LOG"\n'
                            'case "$1" in diff) printf "%s\\n" "$FAKE_CHANGED" ;; esac\n', encoding="utf-8")
            fake.chmod(0o755)
            output = Path(tmp) / "github-output"
            output.write_text("", encoding="utf-8")
            env = dict(os.environ, PATH=f"{bindir}{os.pathsep}{os.environ['PATH']}", FAKE_LOG=str(log),
                       FAKE_CHANGED=changed, GITHUB_OUTPUT=str(output))
            proc = subprocess.run([*BASH, self.render(event)], env=env, capture_output=True, text=True)
            calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
            return proc, calls, output.read_text(encoding="utf-8")

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_a_merge_group_is_judged_by_its_diff_against_the_group_base(self) -> None:
        proc, calls, output = self.run_step("merge_group", "doc/API.md")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls, ["git fetch -q --depth=1 origin " + "m" * 40, "git diff --name-only %s HEAD" % ("m" * 40)])
        self.assertIn("relevant=false", output)
        proc, _, output = self.run_step("merge_group", "src/agentcore/abi_v1.zig")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("relevant=true", output)

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_a_pull_request_diffs_against_its_base_and_a_push_runs_everything(self) -> None:
        proc, calls, _ = self.run_step("pull_request", "doc/API.md")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls[0], "git fetch -q --depth=1 origin " + "p" * 40)
        proc, calls, output = self.run_step("push", "")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls, [])
        self.assertIn("relevant=true", output)


if __name__ == "__main__":
    unittest.main()
