# CI design: required checks, change scope and the merge queue

`ci.yml` runs the AGENTS.md pre-submit checklist on three platforms plus the
offline TTY suites. One run takes about 25 minutes of wall time. The gates
take 20 to 25 minutes per platform, TTY (Linux) about 13 and TTY (Windows)
about 23. This document covers how a required job skips work (§1), which of
that work a change has to pay for (§2), and how a batch of approved PRs lands
without every PR merging `main` in and starting over (§3).

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
| `docs` | `doc/**`, or a top-level `*.md` other than the three the release layout installs, added or edited (not removed or changed in type) | Documentation link and fact checks, their unit tests, the gate-manifest test, the version state gate and the diff check |
| `eval` | documentation, `scripts/eval/**` or `evals/**` | All three gates in full; the TTY jobs report success without running |
| `full` | anything else | Everything |

Push and manual runs are always `full`, and so are an empty diff and any
error.

The boundaries are deliberately narrow:

- **`README.md`, `CHANGELOG.md` and `THIRD_PARTY_NOTICES.md` are not
  documentation for this purpose.** `build.zig` installs all three into the
  release layout, and `gen_third_party_notices.py --check` regenerates the
  notices. A test checks the list against `build.zig`.
- **Removing or moving a documentation file is a code change.** Other files
  pin doc paths: `evals/plugin-v1/protocol.json` lists some in
  `implementation_paths`, which `zig build test` resolves. Adding or editing
  a doc file is harmless, because that fingerprint is stale by design.
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

- An approved PR joins the queue. The queue builds a temporary branch for it,
  `gh-readonly-queue/main/pr-<n>-<sha>`, with `main` plus every PR ahead of
  it and the PR itself merged in order. The workflow runs on that branch
  through the `merge_group` event.
- Each entry is tested once, on top of the entries ahead of it. Up to the
  build concurrency of these runs go in parallel. Up to that many queued PRs
  therefore take about one run's wall time and one run each, instead of
  runs in series plus a merge-`main`-and-rerun round for each PR still
  waiting.
- When an entry's run passes, the queue merges it together with the entries
  ahead of it that passed, up to the maximum group size, and `main` becomes
  exactly a tested tree. When it fails, the queue drops that PR and rebuilds
  the entries behind it without it.

`ci.yml` and `agentcore-windows.yml` run on `merge_group`. In a group:

- **Change scope** diffs the whole group against its `base_sha`, so a group
  of documentation PRs still skips the suites.
- **Release fast path** also diffs against `base_sha`. Only a group whose
  whole diff is the generated bump takes the fast path, which in practice
  means the bump queued alone.
- **Version state gate.** The event carries no pull request. The group's ref
  names the PR at its head, the newest entry, so the gate checks that PR's
  head branch, title and labels. The release PR therefore passes only as its
  group's head. A PR queued behind it sees the bare released version and is
  dropped from the queue, exactly as it would be refused on `main`, until
  the reopen PR has merged
  ([RELEASE_AUTOMATION_DESIGN.md](RELEASE_AUTOMATION_DESIGN.md) stage D).
  This relies on every entry having to pass its own run. Under "only the
  head must pass" (HEADGREEN), a PR queued just ahead of the reopen PR would
  merge with it although its own run was refused.

### Switching it on

The workflows above report on `merge_group` before the rule exists, so the
ruleset can be switched in one edit. A maintainer makes it in `Protect main`:

- **Required status checks:** keep the four checks, and turn off "require
  branches to be up to date before merging"; the queue provides that
  guarantee.
- **Add "require merge queue"** with these settings:
  - merge method: merge commit (the repository's history convention);
  - build concurrency 5: up to five entries tested at once, about eight
    hosted jobs each;
  - maximum group size 5 and minimum 1. With a minimum of 1 the wait time
    setting has no effect;
  - only merge non-failing pull requests (ALLGREEN), which the release
    ordering above relies on;
  - status check timeout 120 minutes. The long pole is a version-bump entry:
    `Release fast path` can wait up to 45 minutes for the base's push run
    before the gates start, and then they run in full if that run was not
    green.

### What stays the same

Pushes to `main` still run the full workflow. The release fast path needs
that run, because its base check is the base commit's push run
(`release_fast_path.py`). When merges land back to back, the concurrency
group cancels the older push run. A release or reopen PR whose base run was
cancelled then takes the full path, which costs one run and never coverage.

Once the queue merges every PR, the push run repeats an entry's run on the
same tree. Replacing it, for instance with a nightly full run plus a
fast-path base check that accepts the merge group run, is the next step and
is not designed here. The per-PR `pull_request` run also stays full for now;
with the queue as the final gate it could shrink to a subset.
