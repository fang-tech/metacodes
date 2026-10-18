#!/usr/bin/env python3
"""Decide which of CI's suites a change can affect.

Design: doc/CI_DESIGN.md §2, "Change scope". The required jobs of ci.yml
always run and report under their own names; their expensive steps read the
scope decided here, so a change that cannot affect a suite does not pay for
it. Skipping whole jobs instead would leave a matrix job's required check
unnamed and pending (the `on.pull_request.paths` filter of #134 blocked PRs
the same way).

Scopes, narrowest first:

- `docs`: every changed path is documentation that no build, test or release
  layout reads: `doc/**`, and the top-level Markdown files other than
  README.md and CHANGELOG.md (build.zig installs those two into the release
  layout). Only the documentation, version-state and gate-manifest checks
  run; `suites=false` and `tty=false`.
- `eval`: every changed path is documentation or the Python evaluation
  harness (`scripts/eval/**`, `evals/**`). The gates run in full, since
  `zig build test` runs the harness's suites and smokes against the built
  binary; the TTY suites, which drive the interactive binary and read
  neither, report success without running: `suites=true`, `tty=false`.
- `full`: anything else, every push and manual run, an empty diff, and any
  error: `suites=true`, `tty=true`.

ci.yml: `ci_scope.py --event "$GITHUB_EVENT_NAME" --base <rev> --candidate
HEAD --github-output "$GITHUB_OUTPUT"`, with the base `HEAD^1` on a pull
request (the merge commit's base) and the group's `base_sha` in a merge
queue. It writes `scope=`, `suites=`, `tty=` and `reason=`, and always exits
0: a doubt is the full scope, never a red job. Python 3.9, stdlib only; tests
in scripts/tests/test_ci_scope.py.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path
from typing import Callable, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[1]
# The events whose diff against a base decides the scope; every other event
# (push to main, workflow_dispatch) runs in full.
DIFF_EVENTS = ("pull_request", "merge_group")
# Top-level Markdown that the release layout installs (build.zig, share/doc).
RELEASE_DOCS = ("README.md", "CHANGELOG.md")
EVAL_PREFIXES = ("scripts/eval/", "evals/")
SHOWN = 5


def is_docs(path: str) -> bool:
    if path.startswith("doc/"):
        return True
    return "/" not in path and path.endswith(".md") and path not in RELEASE_DOCS


def is_eval(path: str) -> bool:
    return path.startswith(EVAL_PREFIXES)


def _shown(paths: Sequence[str]) -> str:
    listed = ", ".join(paths[:SHOWN])
    return listed + (f" and {len(paths) - SHOWN} more" if len(paths) > SHOWN else "")


def classify(paths: Sequence[str]) -> Tuple[str, str]:
    """(scope, reason) for the changed `paths`."""
    if not paths:
        return "full", "full scope: the change has no paths"
    if all(is_docs(path) for path in paths):
        return "docs", f"docs scope: only documentation changed ({_shown(paths)})"
    outside = [path for path in paths if not (is_docs(path) or is_eval(path))]
    if not outside:
        return "eval", "eval scope: only documentation and the evaluation harness changed; the TTY suites are skipped"
    return "full", f"full scope: {_shown(outside)} can affect every suite"


def changed_paths(root: Path, base: str, candidate: str) -> Tuple[str, ...]:
    proc = subprocess.run(
        ["git", "diff", "--name-only", "--no-renames", "-z", base, candidate],
        cwd=str(root),
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"git diff failed: {proc.stderr.decode('utf-8', 'replace').strip()}")
    return tuple(path for path in proc.stdout.decode("utf-8").split("\0") if path)


def decide(
    event: str,
    base: str,
    candidate: str,
    paths: Callable[[str, str], Sequence[str]],
) -> Tuple[str, str]:
    if event not in DIFF_EVENTS:
        return "full", f"full scope: {event or 'unknown'} run"
    if not base:
        return "full", f"full scope: no base for the {event} run"
    try:
        return classify(list(paths(base, candidate)))
    except Exception as exc:  # any doubt is the full scope, never a red job
        return "full", f"full scope: the scope check failed: {exc}"


def outputs(scope: str) -> Tuple[bool, bool]:
    """(suites, tty) for `scope`."""
    return scope != "docs", scope == "full"


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default="")
    parser.add_argument("--candidate", default="HEAD")
    parser.add_argument("--github-output")
    parser.add_argument("--repo-root", default=str(ROOT))
    args = parser.parse_args(argv)
    root = Path(args.repo_root)
    scope, reason = decide(args.event, args.base, args.candidate, lambda base, cand: changed_paths(root, base, cand))
    suites, tty = outputs(scope)
    reason = " ".join(reason.split())
    print(reason)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(
                f"scope={scope}\nsuites={'true' if suites else 'false'}\n"
                f"tty={'true' if tty else 'false'}\nreason={reason}\n"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
