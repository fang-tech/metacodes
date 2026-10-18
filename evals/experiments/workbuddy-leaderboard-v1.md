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
| 4 | Context window | 200k, one threshold | 200,000 only as metacodes' fallback: the adapter recorded the window but did not pass it; a route slug can substring-match the bundled `models.toml` table | the adapter writes `models.toml` in the fresh HOME for the exact route. metacodes compacts at window − output reserve − 13,000 = 154,232 tokens, 92.2% of the 167,232 left after the full 32,768-token output reserve. Claude Code under the same knobs compacts at min(⌊92% × (200,000 − 20,000)⌋, 180,000 − 13,000) = 165,600, so metacodes compacts about 11k tokens earlier; CodeBuddy 2.109.3 uses the bare window. The 92% knob has no metacodes equivalent and is recorded |
| 5 | Tools | WebSearch, AskUserQuestion disabled | both visible (WebSearch called 6 times in Security) | both disabled. WebFetch stays, as in both official harnesses. Agent/Task, teams and plan mode stay disabled as before: delegation is a separate treatment for this harness, and Claude Code's official preset does allow Task |
| 6 | Web/Office judge | Kimi K2.7 Code: temperature 1.0, top_p 0.95, thinking, effort low, JSON object, 32,768 output | `gpt-5.6-sol`, temperature 0.0, 16,384 output | `judge-kimi-k27.yaml` copies the published configuration; the gateway's model id must be confirmed |
| 7 | Turn cap | 256 (both harnesses) | metacodes headless default 400 | unchanged and disclosed: headless has no turn knob, and no September trial stopped on the cap (largest: 281 turns) |
| 8 | Output budget | per-model records unpublished ([#12](https://github.com/Tencent/workbuddy-bench/issues/12)) | 32,768 | unchanged, disclosed |
| 9 | Timeouts, users, network | bench config; open network ([#9](https://github.com/Tencent/workbuddy-bench/issues/9)) | inherited | inherited unchanged; each task's declared network policy applies |
| 10 | Instruction delivery | Claude Code passes it in argv | in argv, so a task's `pkill -f <service>` killed the agent (three Security trials, exit 143) | stdin from an uploaded, hash-checked file; no argv carries task text |
| 11 | Receipts | n/a | 10 of 17 transactions `authorized_failure(post_run_evidence_audit)` | both observed causes fixed: the in-container judge consumed numbers from the proxy's one sequence counter (now one counter per log file), and the exit-143 trials (row 10). Still open: an agent-phase timeout voids its transaction's commit (one `AgentTimeoutError` in September's 260) |
| 12 | Thinking replay | Claude Code returns thinking blocks | metacodes drops them from the next request (`buildApiMessages`) | unchanged: a runtime capability, not a protocol setting; disclosed |
| 13 | Contamination | public dataset | every task, sealed included, was inspected before the September run | cannot be undone: the run is a diagnostic re-test, reported as such |
| 14 | Binary vs task images | n/a | the staged binary needed GLIBC_2.34 or older | the split mount carries no C library, and two Security task images ship glibc 2.35, while the default `x86_64-linux-gnu` release build needs GLIBC_2.36 (it exits with "version `GLIBC_2.36' not found" there). `stage_artifacts` now refuses such a binary; the run stages metacodes built with `-Dtarget=x86_64-linux-gnu.2.31` (needs GLIBC_2.28) beside the release's Lean kernels, TinyKG and ripgrep |

Rows 1–6, 10–11 and 14 are changed by this PR; the evidence is
`scripts/eval/tests/test_workbuddy_adapter.py` (`WorkBuddyLeaderboardProtocolTest`:
the adapter's command replayed against the installed binary shows the
declared window moving the compaction threshold, the effort fields in the
request, the disabled tools absent and the instruction arriving on stdin,
with the undeclared case as the negative control),
`test_workbuddy_leaderboard.py`, `test_workbuddy_lb_preflight.py` and the
installed-proxy sequence test.

## 3. Run plan

- **Binary**: a release cut from `main` after this PR, so the result names a
  version. The Lean kernels, TinyKG and ripgrep come from that release's
  Linux x86_64 archive; metacodes itself is built from the same commit with
  `-Dtarget=x86_64-linux-gnu.2.31` and the release's kernel pins
  (`scripts/kernel_pins.py`), because the archive's binary needs a newer glibc
  than two task images ship (§2 row 14). All of it is hash-bound into the
  split mount.
- **Model**: GLM-5.2 first, through the September gateway, for a same-model
  comparison with the official rows.
- **Scope**: all four subsets, three run sets, 48 transactions, 780 trials.
- **Hosts**: patron (16 cores) for Code and Office, kunshan (8 cores) for
  Security and Web, as in September. A transaction is serial and brings its
  own job proxy on its own port. kunshan's firewall lets containers reach the
  host only on ports 4400 and 4401 (probed 2026-10-18; the default 3456 is
  dropped, which is why every September kunshan job used 4401), so kunshan
  runs at most two transactions at once, each launched with its
  `PROXY_PORT`, unless the owner opens more ports; patron used the default
  ports. Plan four on patron and two on kunshan.
- **Wall time**: September took 10–11 minutes per task serially, so 780
  trials are about 135 serial hours, roughly 23 hours at six in flight;
  plan three days with reviews.
- **Order**:
  1. zero-cost: `run_lb_preflight` on each host; `environment_preflight` for
     every cohort; `launch_gate create` for all 48 transactions (no provider
     I/O);
  2. W1 probe, paid, cap US$1 (done 2026-10-18, §5): two actor requests
     (one tool round) through the gateway with the leaderboard flags, to see
     the gateway accept `thinking: adaptive` and `output_config.effort`; one
     judge request to confirm the Kimi K2.7 Code model id. Outcome: the
     effort fields are accepted; Kimi is not in the judge key's catalog, so
     Web and Office cannot be judged as on the leaderboard until a credential
     that reaches Kimi K2.7 Code exists. The gateway (`shuzuan-org/sub2api`)
     parses `thinking.type` `enabled`/`adaptive` and `output_config.effort`
     as Claude API fields and forwards them with no GLM-specific rewrite, so
     only the upstream's answer is unknown. If it rejects them, stop and
     decide; the candidate fallback is `thinking: {type: enabled}` injected by
     the model config, recorded as "effort not expressible for GLM-5.2 on this
     route". Do not silently drop the fields;
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

A journal's exposure is its committed actual cost plus the maximum of every
transaction not yet committed, and an `authorized_failure` keeps its maximum
exposed. With US$4 per task, one run's sixteen maxima add up to US$1,040
(Code US$64/32/32/192, Office US$40/20/20/120, Security US$48/24/24/144,
Web US$56/28/28/168 for dev/promotion A/promotion B/sealed), so the operator
launches a transaction only when committed cost plus open maxima stays under
the cap; with about US$1.2 actual per task this leaves room for six or seven
transactions in flight until the last run's sealed cohorts.

## 5. Zero-cost evidence so far

- **Containerized preflight** (`run_lb_preflight`, kunshan, 2026-10-18): the
  official runner, the job proxy and a fresh pinned checkout, with
  metacodes built at `4f656124` (`-Dtarget=x86_64-linux-gnu.2.31`) beside the
  Lean kernels, TinyKG and ripgrep of the CI release dry run of `25bfae9b`.
  Zero external requests, two scripted ones. The upstream bodies, as the
  proxy recorded them after its injection, carried only `cache_control`,
  `max_tokens` (32768), `model`, `output_config` (`effort: high`), `stream`
  and `thinking` (`adaptive`); 34 tools were visible, none of WebSearch,
  AskUserQuestion, Agent or Task; the request wave was gapless; metacodes
  reported its auto-compact threshold as 154,232 with the anchored context at
  150,205; the instruction arrived on stdin and the verifier awarded 1.
  Receipt: `quality_evidence=false`.
- **Dry run** (kunshan, 2026-10-18): `leaderboard_jobs --run 1`, then for
  one real transaction, Security promotion A (6 tasks):
  `environment_preflight` built and bound all six task images, and
  `launch_gate create` produced a `metacodes-workbuddy-paid-launch-v3` plan
  binding the cohort, the leaderboard job and model (the job file by content
  hash, so its tool policy, effort and window), the split mount and the
  runner tools, with a US$24 maximum. No journal was written and no
  credential was read; the plan was not run.
- Host facts the runs need: the gate refuses multi-link `bash` and `docker`
  (`/usr/bin/{bash,docker}` on kunshan have two links; the operator copies in
  `~/frontier-bench/bin/` pass), and `uv run --frozen` downloads WorkBuddy's
  locked packages from PyPI on a fresh checkout (about 30 minutes on kunshan).
- What the preflight caught before any spend: the release archive's
  metacodes needs GLIBC_2.36 and does not start in two Security task images
  (§2 row 14), and kunshan drops container traffic to the WorkBuddy default
  proxy port (§3 Hosts). The first preflight attempt failed closed on the
  second ("expected 2 scripted requests, found 0").
- **W1 probe** (paid, authorized by the owner with a US$1 cap, kunshan,
  2026-10-18): one durable budget journal (US$1 authority), one transaction
  per route, each `request_authorized` before sending; metacodes `4f656124`
  with the leaderboard flags through a relay that only rewrote the route to
  `glm-5.2` and added the key, capped at two upstream requests and an
  ~8K-token stream cutoff.
  - GLM-5.2 on the gateway returned HTTP 200 to both requests with
    `thinking: {type: adaptive}`, `output_config: {effort: high}` and
    `max_tokens: 32768`: request 1 came back as a thinking block (65
    characters, no signature) and a `tool_use`; request 2, whose history
    carried the `tool_use` without the thinking block, was accepted and read
    13,888 prompt tokens from cache. So the fields are accepted; whether
    `effort` changes GLM-5.2's thinking depth is not observable from one
    trivial task.
  - The judge key's catalog lists one model and no Kimi id, so no judge
    request was sent: Kimi K2.7 Code is not reachable with the current judge
    credential, and its model id on the gateway is still unknown.
  - Spend: 2 provider requests, 28,163 metered tokens, US$0.048 at the
    repository's conservative GLM-5.2 guardrail rates (an estimate, not the
    gateway's bill); the judge transaction committed zero.
- Not yet exercised: the Web/Office judge route and an agent timeout inside a
  transaction.
