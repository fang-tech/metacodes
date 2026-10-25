#!/usr/bin/env python3
"""Run one shard of the evaluation suite: `run_shard.py K/N [-v]`.

`zig build test:product` runs `scripts/eval/tests` as N shards at once
(build.zig). One `python3 -m unittest discover -s scripts/eval/tests` used to
run behind every smoke: the build runner runs a command that inherits the
terminal one at a time, and that command was the longest of them. Shards with
captured output run beside the smokes and beside each other
(doc/CI_DESIGN.md §4).

A shard is every N-th module of the suite `unittest discover` finds, in its
sorted order, starting at the K-th, so N shards run every module exactly once
(test_run_shard.py). A module that fails to import is a module like any other
and fails its shard. Python 3.9, stdlib only.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def parse_shard(text: str) -> tuple[int, int] | None:
    """`K/N` with 1 <= K <= N, or None."""
    parts = text.split("/")
    if len(parts) != 2 or not all(part.isdigit() for part in parts):
        return None
    index, count = int(parts[0]), int(parts[1])
    if count < 1 or not 1 <= index <= count:
        return None
    return index, count


def select_shard(modules: list, index: int, count: int) -> list:
    """Shard `index` (from 1) of `count`: every count-th module from the index-th."""
    return [module for position, module in enumerate(modules) if position % count == index - 1]


def main(argv: list[str]) -> int:
    shard = parse_shard(argv[0]) if argv else None
    if shard is None:
        print("usage: run_shard.py K/N [-v]  (1 <= K <= N)", file=sys.stderr)
        return 2
    index, count = shard
    # `python3 -m unittest` has the working directory, the repository root,
    # on sys.path; the suite imports `scripts.eval`.
    sys.path.insert(0, str(ROOT))
    modules = list(unittest.defaultTestLoader.discover(str(HERE)))
    selected = unittest.TestSuite(select_shard(modules, index, count))
    print(
        f"evaluation suite shard {index}/{count}: {selected.countTestCases()} tests"
        f" from {len(select_shard(modules, index, count))} of {len(modules)} modules",
        file=sys.stderr,
    )
    if selected.countTestCases() == 0:
        print("this shard selects no tests", file=sys.stderr)
        return 1
    verbosity = 2 if "-v" in argv[1:] else 1
    result = unittest.TextTestRunner(verbosity=verbosity).run(selected)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
