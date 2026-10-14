#!/usr/bin/env python3
"""Is the AgentDef isolation worktree really kept, with the child's change in it?

Grades the harness, not the model's prose. The facts come from the Task
tool's own structured result (the transcript the E2E runner copies into the
workspace) and from the disk: the result says ``worktree_kept: true``, its
``worktree_path`` lies inside this rollout's fake HOME, still exists, and holds
the file the isolated subagent wrote. The previous check looked for the
literal ``worktree_kept=true`` in the model's proof file and failed every run
where the model copied the same fact as ``worktree_kept: true``.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

CHILD_FILE = "isolation-child.txt"
CHILD_MARKER = "ISOLATED_WORKTREE_ONLY"
TASK_TOOLS = ("Task", "Agent")


def _text(content: object) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            item.get("text", "") for item in content if isinstance(item, dict)
        )
    return ""


def task_results(transcript: Path) -> list:
    """Structured results of every Task/Agent call, in transcript order."""
    task_ids = set()
    results = []
    for line in transcript.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if not isinstance(message, dict):
            continue
        for block in message.get("blocks") or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use" and block.get("name") in TASK_TOOLS:
                task_ids.add(str(block.get("id")))
            elif block.get("type") == "tool_result" and str(block.get("tool_use_id")) in task_ids:
                try:
                    parsed = json.loads(_text(block.get("content")))
                except ValueError:
                    continue
                if isinstance(parsed, dict):
                    results.append(parsed)
    return results


def _inside(path: str, root: str) -> bool:
    try:
        return os.path.commonpath([path, root]) == root
    except ValueError:  # different drives on Windows
        return False


def check(workspace: Path) -> list:
    transcript = workspace / "transcript.jsonl"
    if not transcript.is_file():
        return ["transcript.jsonl is missing: no Task result to grade"]
    results = task_results(transcript)
    if not results:
        return ["no structured Task/Agent result in the transcript"]
    home = os.path.realpath(workspace / ".home")
    failures = []
    for result in results:
        reported = result.get("worktree_path")
        if not isinstance(reported, str) or not reported:
            failures.append("a Task result carries no worktree_path")
            continue
        if result.get("worktree_kept") is not True:
            failures.append(
                f"Task reported worktree_kept={result.get('worktree_kept')!r} for {reported}"
            )
            continue
        real = os.path.realpath(reported)
        if not _inside(real, home):
            failures.append(f"worktree {reported} is outside this rollout's HOME")
            continue
        if not os.path.isdir(real):
            failures.append(f"worktree {reported} was reported kept but does not exist")
            continue
        try:
            child_text = (Path(real) / CHILD_FILE).read_text(encoding="utf-8", errors="replace")
        except OSError:
            failures.append(f"kept worktree {reported} has no {CHILD_FILE}")
            continue
        if CHILD_MARKER not in child_text:
            failures.append(f"{CHILD_FILE} in {reported} lacks {CHILD_MARKER}")
            continue
        print(f"kept worktree {reported} holds the child's {CHILD_FILE}")
        return []
    return failures


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: 42_agentdef_isolation.py <workspace>")
        return 2
    failures = check(Path(sys.argv[1]))
    for failure in failures:
        print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
