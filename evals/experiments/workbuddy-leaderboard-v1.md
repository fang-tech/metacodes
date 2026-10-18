# WorkBuddy-Bench under the leaderboard protocol (v1)

Status: proposed 2026-10-18. No provider-backed request has been made under
this protocol. Every paid step below needs explicit owner authorization, a
dollar cap and the durable budget journals ([BENCHMARKS.md](../../doc/BENCHMARKS.md) §5).

Goal: a metacodes result on WorkBuddy-Bench that a third party can cite,
produced under the protocol of the official leaderboard
([workbuddybench.com](https://workbuddybench.com/), v1.2 of 2026-10-15), and,
if the maintainers agree, listed there.

## 1. Is there a way onto the leaderboard?

Checked on 2026-10-18 against the site source (the `gh-pages` branch of
[Tencent/workbuddy-bench](https://github.com/Tencent/workbuddy-bench)), the
repository README, its issues and pull requests, and the technical report
(`report/main.pdf` on `gh-pages`).

- **No public submission process exists.** There is no form, address,
  CONTRIBUTING file or submission section in the README, the site or the
  report. GitHub Discussions are disabled; issues are the only public channel.
- The board is two harness tabs, CodeBuddy Code 2.109.3 and Claude Code
  2.1.187, kept in the site's `roster.js`/`data.js` by maintainer commits.
  The report ties every result to those two builds (§4).
- A request to support more harnesses
  ([#21](https://github.com/Tencent/workbuddy-bench/issues/21), "pi") was closed
  as not planned on 2026-09-22 without comment. On
  [#1](https://github.com/Tencent/workbuddy-bench/issues/1) a maintainer wrote
  (2026-07-28) that adding harnesses such as Codex is not scheduled and that the
  community is welcome to report results for other harnesses on the open
  dataset.
- The maintainers who answer issues are the repository collaborators
  `yyong119`, `pakchoi-i`, `keli-61` and `xfey`.

So the path is outreach, not submission: ask the maintainers whether they would
list a third-party harness result with its artifacts, or run metacodes
themselves from the overlay. Until they answer, the result is a self-reported
run under the published protocol, labelled as such. The outreach draft is
held outside the repository until the owner approves sending it.

Two facts limit any comparison and go into the outreach as questions:

- the board's Code row is labelled `wb-bench-code-v2.3-lite` (80 tasks) while
  the Hugging Face dataset publishes only `wb-bench-*-v1.0`; how the public
  archives map to the board's task sets is not stated anywhere public;
- GLM-5.2's Security score was withheld from v1.2 on 2026-10-17 ("pending
  re-verification", site commit `be43b75`).

## 2. Protocol alignment

The protocol, from report §4 and the upstream configs at the pinned commit:
three-run means, think mode, reasoning effort high, a 200k context window
with one auto-compaction threshold, WebSearch and AskUserQuestion disabled,
provider-default inference parameters otherwise. Bench configs: three
attempts, `timeout_multiplier: 2.0`, `context_window: 200000`,
`context_compact_pct: 92`. Web and Office are judged by Kimi K2.7 Code
([#3](https://github.com/Tencent/workbuddy-bench/issues/3)).

| # | Item | Official | September 2026 run | Now |
|---|---|---|---|---|
| 1 | Runs | mean of 3 | 1 pass | three run sets `r1..r3`; a paid launch binds one attempt, so each set is 16 frozen-cohort jobs (`leaderboard_jobs.py`) |
| 2 | Reasoning | think mode, effort high | no effort flag; requests carried no thinking field (the provider thought by default) | `--reasoning-effort high`; upstream body carries `thinking: {type: adaptive}` and `output_config: {effort: high}`. Gateway acceptance is not yet observed (probe in §3) |
| 3 | Sampling | provider defaults | `temperature: 0.0`, injected by the job proxy from `metacodes-glm52.yaml` | `metacodes-glm52-leaderboard.yaml` injects only `max_tokens`; no temperature, top_p or top_k in the upstream body |
| 4 | Context window | 200k, one threshold | 200,000 only as metacodes' fallback: the adapter recorded the window but did not pass it; a route slug can substring-match the bundled `models.toml` table | the adapter writes `models.toml` in the fresh HOME for the exact route. metacodes compacts at window − output reserve − 13,000 = 154,232 tokens, 92.2% of the 167,232 left after the 32,768-token reserve. The 92% knob has no metacodes equivalent and is recorded; the official harnesses also apply it differently (Claude Code as a percentage override, CodeBuddy 2.109.3 on the bare window) |
| 5 | Tools | WebSearch, AskUserQuestion disabled | both visible (WebSearch called 6 times in Security) | both disabled. WebFetch stays, as in both official harnesses. Agent/Task, teams and plan mode stay disabled as before: delegation is a separate treatment for this harness, and Claude Code's official preset does allow Task |
| 6 | Web/Office judge | Kimi K2.7 Code: temperature 1.0, top_p 0.95, thinking, effort low, JSON object, 32,768 output | `gpt-5.6-sol`, temperature 0.0, 16,384 output | `judge-kimi-k27.yaml` copies the published configuration; the gateway's model id must be confirmed |
| 7 | Turn cap | 256 (both harnesses) | metacodes headless default 400 | unchanged and disclosed: headless has no turn knob, and no September trial stopped on the cap (largest: 281 turns) |
| 8 | Output budget | per-model records unpublished ([#12](https://github.com/Tencent/workbuddy-bench/issues/12)) | 32,768 | unchanged, disclosed |
| 9 | Timeouts, users, network | bench config; open network ([#9](https://github.com/Tencent/workbuddy-bench/issues/9)) | inherited | inherited unchanged; each task's declared network policy applies |
| 10 | Instruction delivery | Claude Code passes it in argv | in argv, so a task's `pkill -f <service>` killed the agent (three Security trials, exit 143) | stdin from an uploaded, hash-checked file; no argv carries task text |
| 11 | Receipts | n/a | 10 of 17 transactions `authorized_failure(post_run_evidence_audit)` | both observed causes fixed: the in-container judge consumed numbers from the proxy's one sequence counter (now one counter per log file), and the exit-143 trials (row 10). Still open: an agent-phase timeout voids its transaction's commit (one `AgentTimeoutError` in September's 260) |
| 12 | Thinking replay | Claude Code returns thinking blocks | metacodes drops them from the next request (`buildApiMessages`) | unchanged: a runtime capability, not a protocol setting; disclosed |
| 13 | Contamination | public dataset | every task, sealed included, was inspected before the September run | cannot be undone: the run is a diagnostic re-test, reported as such |

Rows 1–6 and 10–11 are changed by this PR; the evidence is
`scripts/eval/tests/test_workbuddy_adapter.py` (`WorkBuddyLeaderboardProtocolTest`:
the adapter's command replayed against the installed binary shows the
declared window moving the compaction threshold, the effort fields in the
request, the disabled tools absent and the instruction arriving on stdin,
with the undeclared case as the negative control),
`test_workbuddy_leaderboard.py`, `test_workbuddy_lb_preflight.py` and the
installed-proxy sequence test.

## 3. Run plan

- **Binary**: a release cut from `main` after this PR, so the result names a
  version; staged from that release's Linux x86_64 archive (CLI, TinyKG, both
  Lean kernels, ripgrep) and hash-bound into the split mount.
- **Model**: GLM-5.2 first, through the September gateway, for a same-model
  comparison with the official rows.
- **Scope**: all four subsets, three run sets, 48 transactions, 780 trials.
- **Hosts**: patron (16 cores) for Code and Office, kunshan (8 cores) for
  Security and Web, as in September. A transaction is serial; run up to four
  transactions at once on patron and three on kunshan.
- **Wall time**: September took 10–11 minutes per task serially, so 780
  trials are about 135 serial hours, roughly 20–25 hours at seven in flight;
  plan three days with reviews.
- **Order**:
  1. zero-cost: `run_lb_preflight` on each host; `environment_preflight` for
     every cohort; `launch_gate create` for all 48 transactions (no provider
     I/O);
  2. W1 probe, paid, cap US$1: two actor requests (one tool round) through
     the gateway with the leaderboard flags, to see the gateway accept
     `thinking: adaptive` and `output_config.effort`; one judge request to
     confirm the Kimi K2.7 Code model id. If the gateway rejects the effort
     fields, stop and decide; do not silently drop them;
  3. `r1` dev cohorts (52 tasks), then review cost, receipts and failures;
  4. the rest of `r1`, then `r2`, then `r3`.
- **Stop rules**: an `authorized_failure` receipt stops further launches on
  that host until inspected; no automatic retries (`WBBENCH_PROXY_MAX_RETRIES=0`).
- **Reporting**: per-subset mean of the three run means, with the per-run
  values, cost, tokens, wall time, failures and every disclosed difference
  in §2, in a new `evals/benchmarks/` directory generated from data.

## 4. Budget

September actor cost for one pass (trajectory accounting, audited receipts
about 5% higher): Code US$64, Office US$57, Security US$73 (nine trials
without a cost), Web US$99, total US$293. Judge load observed in September:
Web about 23 judge requests per task at about 18k prompt tokens, Office about
10 per task at about 10k, together about 34M prompt tokens per pass.

| Item | Estimate for three passes |
|---|---|
| Actor (GLM-5.2) | US$930–1,210: three passes of about US$310, up to 1.3× if effort high lengthens output |
| Judge (Kimi K2.7 Code, Web + Office) | US$70–160 at US$0.6–1.2/M input and US$2.5–5/M output; the gateway price must be confirmed |
| W1 probe | under US$1 |

Requested caps: **US$1,500 actor** as cumulative exposure over all actor
journals (each launch passes the earlier transactions' exposure as
`prior_exposure_microusd`; per-transaction maximum US$4 per task, as in
September), and **US$150 judge** on its own gateway key with a hard quota,
because judge spend does not pass through the launch gate's journal. Total
US$1,650, under the gate's US$2,000 per-authority ceiling.
