# CI design: required checks, change scope and the merge queue

`ci.yml` runs the AGENTS.md pre-submit checklist on three platforms plus the
offline TTY suites. One run takes about 25 minutes of wall time. The gates
take 20 to 25 minutes per platform, TTY (Linux) about 13 and TTY (Windows)
about 23. This document covers three things: which of that work a change has
to pay for (§2), and how a batch of approved PRs is tested and merged once
instead of once per PR (§3).

## 1. Required checks and how a job skips work

The `Protect main` ruleset requires `Gates (Linux)`, `Gates (macOS)`,
`Gates (Windows)` and `TTY (Linux)`. Each of these jobs always runs and
reports under its own name. Work is skipped by step conditions, never by
skipping the job, for two reasons:

- A matrix job skipped by a job-level `if` reports under its unexpanded name
  (`Gates (${{ matrix.os }})`), so the required check stays pending.
- A workflow `paths` filter leaves the check pending the same way, which is
  how doc-only PRs were blocked in #134.

Three switches decide which steps run. Each one fails open: an empty value,
meaning its decision job failed, runs the step.

| Switch | Decided by | Effect |
|---|---|---|
| `FAST_PATH` | `Release fast path` job (`scripts/release_fast_path.py`) | `true` for a generated release or reopen bump over a green base: only the checkout and the version state gate run ([RELEASE_AUTOMATION_DESIGN.md](RELEASE_AUTOMATION_DESIGN.md) §3). |
| `SUITES` | `Change scope` job (`scripts/ci_scope.py`) | `false` for a documentation-only change: `Gates` runs only the documentation, version-state and gate-manifest checks, and `Gates (Windows)` runs nothing. |
| `TTY` | `Change scope` job | `false` for a change confined to documentation and the evaluation harness: the TTY jobs run nothing. |

`scripts/tests/test_ci_scope.py` pins the wiring:

- the `Gates` steps that still run on a documentation-only change;
- that every other step of the required jobs reads its switch, as
  `!= 'false'`, together with `FAST_PATH`;
- which base each decision step diffs against, per event.

## 2. Change scope

`scripts/ci_scope.py` compares the changed paths against a base. On a pull
request the base is `HEAD^1`, the first parent of the merge commit CI tests.
In a merge queue group it is the group's `base_sha`. Renames count as a delete
plus an add, so moving a file out of `doc/` is a code change.

| Scope | Every changed path is | What runs |
|---|---|---|
| `docs` | `doc/**`, or a top-level `*.md` other than `README.md` and `CHANGELOG.md` | Documentation link and fact checks, their unit tests, the gate-manifest test, the version state gate and the diff check |
| `eval` | documentation, `scripts/eval/**` or `evals/**` | All three gates in full; the TTY jobs report success without running |
| `full` | anything else | Everything |

Push and manual runs are always `full`, and so are an empty diff and any
error.

The boundaries are deliberately narrow:

- **`README.md` and `CHANGELOG.md` are not documentation for this purpose.**
  `build.zig` installs both into the release layout.
- **Markdown outside `doc/` and the top level is an input.** Prompt templates
  are `@embedFile`'d, and agent and Skill fixtures are read by tests.
- **The evaluation harness keeps the gates.** `zig build test` runs its suites
  and the smokes against the built binary, for example
  `scripts/eval/chained_memory_smoke.py`. It skips only the TTY suites, which
  drive the interactive binary and read neither tree.

## 3. Merge queue

With the ruleset's "require branches to be up to date" policy, every merge to
`main` invalidates the green checks of every other open PR. Each PR must then
merge `main` in and run the full workflow again, and the PRs merge one after
another. With N PRs ready, that is close to N²/2 runs in series.

The merge queue removes the up-to-date requirement and tests what will
actually land:

- An approved PR joins the queue. The queue builds a temporary branch,
  `gh-readonly-queue/main/pr-<n>-<sha>`, with `main` plus the PRs ahead of it
  and the PR itself merged in order.
- The workflow runs on that branch through the `merge_group` event, and a
  group of several PRs is tested in one run.
- When the group passes, its PRs merge together, and `main` becomes exactly
  the tested tree. When it fails, the queue drops the failing PR and retests
  the rest without it.

`ci.yml` and `agentcore-windows.yml` run on `merge_group`. In a group:

- **Change scope** diffs the whole group against its `base_sha`, so a group
  of documentation PRs still skips the suites.
- **Release fast path** also diffs against `base_sha`. Only a group whose
  whole diff is the generated bump takes the fast path, which in practice
  means the bump queued alone.
- **Version state gate.** The event carries no pull request, so the gate
  takes the PR number from the group's ref and checks that PR's head branch,
  title and labels. The release PR therefore passes only at the top of its
  group. A PR queued behind it sees the bare released version and is dropped
  from the queue, exactly as it would be refused on `main`, until the reopen
  PR has merged
  ([RELEASE_AUTOMATION_DESIGN.md](RELEASE_AUTOMATION_DESIGN.md) stage D).

### Switching it on

The workflows above report on `merge_group` before the rule exists, so the
ruleset can be switched in one edit. A maintainer makes it in `Protect main`:

- **Required status checks:** keep the four checks, and turn off "require
  branches to be up to date before merging"; the queue provides that
  guarantee.
- **Add "require merge queue"** with these settings:
  - merge method: merge commit (the repository's history convention);
  - maximum group size 5 and minimum 1, waiting up to 5 minutes to fill a
    group;
  - build concurrency 5;
  - every entry must pass the required checks;
  - status check timeout 60 minutes, since TTY (Windows) takes about 25 and
    a cold runner more.

### What stays the same

Every push to `main` still runs the full workflow. The release fast path
needs that run: its base check is the base commit's push run
(`release_fast_path.py`). Once the queue merges every PR, that run repeats
the group's run on the same tree. Replacing it, for instance with a nightly
full run plus a fast-path base check that accepts the merge group run, is
the next step and is not designed here. The per-PR `pull_request` run also
stays full for now; with the queue as the final gate it could shrink to a
subset.
