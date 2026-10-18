#!/usr/bin/env python3
"""Pinned full-validator check for learning-turn-v1 configuration D.

The check gate's command (`--host-check`) is fixed per arm wrapper, but each
check-gate v3 task has its own validator. This dispatcher is that one fixed
command: it reads the task from METACODES_TASK_HINT (which `cli.py
run-chained` sets on every attempt), runs that task's validator — pristine
visible tests plus hidden tests — against the workspace (the first argument,
else the working directory, which is where the check gate runs it), and exits
with the validator's verdict. Its output is the validator's: `FAILED <test> -
<reason>` lines and a final `<failed> failed, <passed> passed` line, which the
verdict codecs parse.

Exit codes are chosen for the check gate's verdict classes
(src/core/check_gate.zig `runCheck`): 0 passed, 1 failed, and 127 whenever
there is no verdict — no or an unknown task hint, a missing validator, or a
validator that died with any other status. 127 makes the gate record
`unavailable`, which a learning turn never learns from, instead of turning a
broken check into a lesson about the candidate.

Wrapper usage (both arms of configuration D):

    --host-check 'python3 -I <repo>/evals/validators/check_gate_v3_pinned.py' --check-gate-observe
"""

import os
import subprocess
import sys
from pathlib import Path

TASK_HINT_ENV = "METACODES_TASK_HINT"
EXIT_UNAVAILABLE = 127
# evals/suites/check-gate-v3.json: task id -> its success-check validator.
VALIDATORS = {
    "d1_cg3_cron": "d1_check_gate_v3_cron.py",
    "d2_cg3_sheet": "d2_check_gate_v3_sheet.py",
    "d3_cg3_calc": "d3_check_gate_v3_calc.py",
    "d4_cg3_ranges": "d4_check_gate_v3_ranges.py",
}
VALIDATOR_TIMEOUT_SECONDS = 150


def resolve(task_hint, validators_dir=None):
    """The validator for `task_hint`, or None when there is none to run."""
    name = VALIDATORS.get(task_hint)
    if name is None:
        return None
    path = (validators_dir or Path(__file__).resolve().parent) / name
    if path.is_symlink() or not path.is_file():
        return None
    return path


def main(argv=None, environ=None, validators_dir=None):
    argv = sys.argv if argv is None else argv
    environ = os.environ if environ is None else environ
    task_hint = environ.get(TASK_HINT_ENV, "")
    validator = resolve(task_hint, validators_dir)
    if validator is None:
        print("no pinned validator for task hint %r" % task_hint, file=sys.stderr)
        return EXIT_UNAVAILABLE
    workspace = Path(argv[1]) if len(argv) > 1 else Path.cwd()
    try:
        completed = subprocess.run(
            [sys.executable, "-I", str(validator), str(workspace.resolve())],
            timeout=VALIDATOR_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("pinned validator produced no verdict: %s" % exc, file=sys.stderr)
        return EXIT_UNAVAILABLE
    if completed.returncode in (0, 1):
        return completed.returncode
    print("pinned validator exited %d: no verdict" % completed.returncode, file=sys.stderr)
    return EXIT_UNAVAILABLE


if __name__ == "__main__":
    sys.exit(main())
