#!/usr/bin/env python3
"""Pinned full-validator check for learning-turn-v1 configuration D.

The check gate's command (`--host-check`) is fixed per arm wrapper, but each
check-gate v3 task has its own validator. This dispatcher is that one fixed
command: it reads the task from METACODES_TASK_HINT (which `cli.py
run-chained` sets on every attempt), runs that task's validator — pristine
visible tests plus hidden tests — against the workspace (the first argument,
else the working directory, which is where the check gate runs it), and
passes on the validator's output: `FAILED <test> - <reason>` lines and a
final `<failed> failed, <passed> passed` line, which the verdict codecs parse.

Exit codes are chosen for the check gate's verdict classes
(src/core/check_gate.zig `runCheck`): 0 passed, 1 failed, and 127 whenever
there is no verdict. 127 makes the gate record `unavailable`, which a
learning turn never learns from, instead of turning a broken check into a
lesson about the candidate.

A validator's exit status alone is not a verdict: an exception escaping the
validator (say, a dangling symlink its workspace copy cannot follow) exits 1
exactly like a failing test run. So 0 and 1 are passed on only when the last
of the validator's own verdict lines in its output agrees with its status:
the count line with no failures and exit 0, the count line with failures and
exit 1, or `tests timed out` (the validator's line for a test run that hung,
a failure of the candidate) with exit 1. The last verdict line, not the last
line: a validator prints the test run's stdout, which ends on the count line,
and then its stderr, where the candidate's own code may write anything. A
crashed validator prints no verdict line at all. A line the candidate forges
on stderr can only disagree with the real status, which gives no verdict;
it cannot turn a failure into a pass. Everything else is 127: no or an
unknown task hint, a missing validator, a validator that crashed or hung
past the dispatcher's limit, or output without a verdict line.

Wrapper usage (both arms of configuration D):

    --host-check 'python3 -I <repo>/evals/validators/check_gate_v3_pinned.py' --check-gate-observe
"""

import os
import re
import subprocess
import sys
from pathlib import Path

TASK_HINT_ENV = "METACODES_TASK_HINT"
EXIT_PASSED = 0
EXIT_FAILED = 1
EXIT_UNAVAILABLE = 127
# evals/suites/check-gate-v3.json: task id -> its success-check validator.
VALIDATORS = {
    "d1_cg3_cron": "d1_check_gate_v3_cron.py",
    "d2_cg3_sheet": "d2_check_gate_v3_sheet.py",
    "d3_cg3_calc": "d3_check_gate_v3_calc.py",
    "d4_cg3_ranges": "d4_check_gate_v3_ranges.py",
}
VALIDATOR_TIMEOUT_SECONDS = 150
# The verdict lines the four validators end on: tests/run.py's count line,
# and the validator's own line when the test run times out.
SUMMARY_LINE = re.compile(r"(\d+) failed, (\d+) passed")
TIMEOUT_LINE = "tests timed out"


def resolve(task_hint, validators_dir=None):
    """The validator for `task_hint`, or None when there is none to run."""
    name = VALIDATORS.get(task_hint)
    if name is None:
        return None
    path = (validators_dir or Path(__file__).resolve().parent) / name
    if path.is_symlink() or not path.is_file():
        return None
    return path


def verdict(returncode, stdout):
    """EXIT_PASSED or EXIT_FAILED when the validator reported a verdict,
    else None: the last of its verdict lines in the output decides, and its
    exit status must agree with that line."""
    for raw in reversed(stdout.splitlines()):
        line = raw.strip()
        if line == TIMEOUT_LINE:
            return EXIT_FAILED if returncode == 1 else None
        match = SUMMARY_LINE.fullmatch(line)
        if match is None:
            continue
        failed, passed = int(match.group(1)), int(match.group(2))
        if returncode == 0 and failed == 0 and passed > 0:
            return EXIT_PASSED
        if returncode == 1 and failed > 0:
            return EXIT_FAILED
        return None
    return None


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
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=VALIDATOR_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("pinned validator produced no verdict: %s" % exc, file=sys.stderr)
        return EXIT_UNAVAILABLE
    stdout = completed.stdout.decode("utf-8", "replace")
    stderr = completed.stderr.decode("utf-8", "replace")
    sys.stdout.write(stdout)
    sys.stdout.flush()
    if stderr:
        sys.stderr.write(stderr)
    result = verdict(completed.returncode, stdout)
    if result is None:
        print(
            "pinned validator exited %d without a verdict line that agrees: no verdict"
            % completed.returncode,
            file=sys.stderr,
        )
        return EXIT_UNAVAILABLE
    return result


if __name__ == "__main__":
    sys.exit(main())
