# Sealed Skill Protocol (SSP/1)

Status: **draft for implementation**, protocol identifier
`metask.sealed-skill/v1`, revision 2026-10-15. Owner: Metask Lab. This
document is normative for the wire protocol between a *client* (an agent
harness that owns tools, permissions and a user's budget) and a *gateway*
(a service that executes a Skill it never discloses). metacodes is the
reference client; §9 records how it maps the protocol onto its own kernel.

The words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. Problem and shape

A Skill today is a plaintext `SKILL.md` plus assets, discovered and read by
the agent on the user's machine. Whatever it contains is readable by the
user, by every process on the machine, and by every model provider the
agent talks to. That makes Skills impossible to sell: a Skill marketplace
needs creators who can publish without handing the work to every subscriber.

SSP turns a Skill into a *service* without moving the user's environment to
the service. The split is:

- **the brain runs on the gateway**: the Skill body, its workflow, its
  private knowledge and its model calls stay on the gateway;
- **the hands stay on the client**: every tool call the Skill needs is sent
  to the client as a request, executed there under the client's own
  permission system, sandbox and credentials, and only the result goes back;
- **the client pays**: every model call the gateway makes on the client's
  behalf is metered and charged to the client's account, step by step, under
  a cap the client set before the run started.

It is the hosted-agent / client-executed-tools pattern (computer use agents,
managed agents with client tools) applied in reverse to the Skill: the
remote side holds the instructions, the local side holds the environment.

### 1.1 What the protocol protects, stated honestly

| Layer of a Skill | Where it lives under SSP | Visible to the client? |
|---|---|---|
| Reasoning: system prompt, judgement, domain knowledge, exception handling | gateway | **no** |
| Actions: which tools are called, with which inputs, in which order | both | **yes** — the client executes and the user approves each one |
| Code assets the Skill ships | gateway (`server` class) or client (`client-sealed`, §7) | server: no; client-sealed: deterrent only |

A run reveals one path through the Skill, never the Skill. A Skill whose
value is a fixed procedure is reconstructible from enough runs; a Skill
whose value is judgement and the long tail of exception handling is not.
The gateway's language model is itself a disclosure channel (a tool result
can carry an injection that asks the model to write its instructions into a
file), so SSP specifies detection and accountability for that channel
(§8.5), not impossibility. Nothing in this document is encryption of the
Skill against the party that runs it; the Skill is confidential because it
never leaves the gateway, and the gateway is operated by the party the
creator chose to trust.

### 1.2 Roles

| Role | Holds | Trusts |
|---|---|---|
| **Creator** | the Skill: `SKILL.md`, workflow, assets, manifest | the gateway operator (contractually; §8.6 for the attested variant) |
| **Gateway** | Skill content, the brain (model or workflow engine), metering, sealing keys | nobody: every client message is untrusted input |
| **Client** | the user's tools, permissions, sandbox, credentials, budget, audit log | nobody: every gateway message is untrusted model output |
| **Subscriber** | an account on the gateway | the gateway for billing, the client for everything that touches their machine |

In the reference deployment one service implements the gateway's four
internal identities — *skill host* (content and brain), *inference gateway*
(model calls and metering), *sealing issuer* (§7) and *billing*. They are
named separately so that a later revision can let a third party host Skills
behind a Metask inference gateway; a v1 implementation MAY merge them and
MUST still populate the identity fields (§4.2) distinctly.

## 2. Transport

- **JSON-RPC 2.0** messages, each POSTed to one gateway URL with
  `Content-Type: application/json`. The gateway answers with
  `application/json` (one response) or `text/event-stream` (a stream of
  JSON-RPC messages, last one the response), the same framing as MCP
  Streamable HTTP; a client MUST accept both.
- Every request carries the header `Sealed-Skill-Version: 1`. A gateway
  that does not implement that major version MUST answer HTTP 400 with
  error `unsupported_version`.
- Authentication is a bearer token for the subscriber's gateway account in
  `Authorization`. How the token is obtained (OAuth, API key) is outside this
  protocol. A gateway MUST NOT accept model-provider credentials from the
  client; the client's own provider keys never cross this interface (§8.1).
- The gateway SHOULD be **stateless per run**: run state travels in the
  opaque `run_state` blob (§4.4) that the client returns unchanged with every
  message. A gateway MAY keep state server-side instead; the client cannot
  tell and MUST behave identically.
- TLS is required outside loopback test deployments.

## 3. Methods

| Method | Direction | Purpose |
|---|---|---|
| `sealed/discover` | client → gateway | protocol versions, capabilities, operator identity |
| `sealed/skills.list` | client → gateway | the Skills this subscriber may run, with manifests |
| `sealed/skills.get` | client → gateway | one Skill's current manifest (for pin refresh) |
| `sealed/runs.start` | client → gateway | begin a run; returns the first Step |
| `sealed/runs.continue` | client → gateway | deliver tool results; returns the next Step |
| `sealed/runs.cancel` | client → gateway | end a run early |

There are no gateway-initiated requests. Everything the gateway needs from
the client is expressed as a Step (§4.3); this keeps the client's transport a
plain request/response client and keeps the gateway free of per-client
connections.

### 3.1 `sealed/discover`

Params: `{}`. Result:

```json
{
  "protocol": "metask.sealed-skill/v1",
  "revisions": ["2026-10-15"],
  "operator": {"id": "metask", "display_name": "Metask Lab"},
  "identities": {"skill_host": "metask", "inference_gateway": "metask",
                 "sealing_issuer": "metask", "billing": "metask"},
  "capabilities": {
    "run_state": "opaque",
    "step_signature": true,
    "input_required": true,
    "prefetch": false,
    "client_sealed": false,
    "currencies": ["USD"]
  }
}
```

`capabilities.run_state` is `"opaque"` or `"server"`. `step_signature` says
every Step carries `sig` (§8.4). `prefetch` and `client_sealed` are §7
features and are `false` in revision 2026-10-15.

### 3.2 `sealed/skills.list`

Params: `{"cursor": "<opaque>"?}`. Result: `{"skills": [Entry...],
"next_cursor": "<opaque>"?}`. An Entry is:

```json
{
  "skill_id": "ssk_7f3a…",
  "version": "1.4.0",
  "manifest": { … §5 … },
  "manifest_digest": "sha256:…",
  "manifest_sig": "<base64 Ed25519 over the canonical manifest>"?,
  "subscription": {"state": "active" | "available" | "expired"}
}
```

`manifest_digest` is SHA-256 over the canonical JSON (§4.5) of `manifest`.
The client stores Entries it installs as **pins**; a pin is the user's
consent to exactly that manifest (§6.1).

### 3.3 `sealed/skills.get`

Params: `{"skill_id"}`. Result: one Entry. Error `skill_not_found` when the
id is unknown or not visible to this subscriber.

### 3.4 `sealed/runs.start`

```json
{
  "skill_id": "ssk_7f3a…",
  "manifest_digest": "sha256:…",
  "prompt": "the user's task, as the activating turn would have given a local Skill",
  "arguments": ["positional", "values"],
  "tools": [ToolDefinition...],
  "budget": {"max_cost_micros": 500000, "currency": "USD", "max_steps": 200},
  "client": {"name": "metacodes", "version": "0.6.0", "platform": "windows-x86_64",
             "run_ref": "<client-side run id, for audit joins>"},
  "locale": "zh-CN"?,
  "confirmation": "client" | "always"
}
```

- `manifest_digest` is the pinned digest. If the Skill's current manifest
  differs the gateway MUST fail with `manifest_changed` and MUST NOT run; the
  client refreshes the pin through `skills.get` and asks the user again.
- `tools` are the definitions (name, description, input schema) of the
  client's tools that fall inside the manifest's `tools.allow` and outside
  `tools.deny`, in the client's own schema dialect. A gateway MUST request
  only tools listed here, by exactly these names and against these schemas;
  it MUST NOT assume a tool exists because the manifest allows it.
- `budget.max_cost_micros` is the cap for this run in micro-units of
  `currency` (USD 0.50 is `500000`). The gateway MUST stop with
  `budget_exceeded` before the cumulative charge would pass it.
  `max_steps` bounds the number of Steps.
- `confirmation: "always"` asks the gateway to mark every call `confirm:
  true`; `"client"` (default) leaves it to the manifest and the gateway.

Result: a Step (§4.3).

### 3.5 `sealed/runs.continue`

```json
{
  "run_id": "run_…",
  "run_state": "<opaque, from the previous Step>",
  "seq": 4,
  "results": [
    {"tool_use_id": "call_1", "content": "…", "is_error": false,
     "truncated": false, "redactions": ["erp-main"]}
  ]
}
```

- `seq` is the `seq` of the Step being answered. A gateway MUST reject a
  stale or future `seq` with `run_state_invalid`.
- `results` MUST contain exactly one entry per call in that Step, in any
  order. `content` is the tool's result as the client would have given its
  own model: text, or a JSON array of content parts when the tool returned
  parts (images are allowed only when the manifest's egress classes include
  `images`).
- `truncated` is `true` when the client cut the result to the manifest's
  `egress.max_result_bytes` (§6.3). `redactions` lists the credential
  references whose values the client replaced in the content (§6.4).
- A call the client refused (policy, permission denied by the user, tool
  missing) is reported with `is_error: true` and a `refusal` field:
  `"policy_violation" | "permission_denied" | "tool_unavailable" |
  "budget" | "aborted"`. The gateway MUST treat a `policy_violation`
  refusal as a defect in its own Skill, not as something to retry.

Result: the next Step.

### 3.6 `sealed/runs.cancel`

Params: `{"run_id", "run_state", "reason": "user_abort" | "budget" |
"policy" | "client_error"}`. Result: a Step of kind `failed` with
`reason: "cancelled"` and the final `cumulative` usage. The gateway MUST
charge nothing for work after a cancel is received.

## 4. Objects

### 4.1 ToolDefinition

The client's neutral tool definition: `{"name", "description",
"input_schema": <JSON Schema object>}`. Names are the client's own
(`Read`, `Bash`, `mcp__playwright__browser_click`, …).

### 4.2 Identities

Every Step and every Entry carries `issuer`: `{"skill_host": "<id>",
"inference_gateway": "<id>"}`, the gateway identities that produced it. A
client MUST record them with the run (§8.3).

### 4.3 Step

```json
{
  "run_id": "run_…",
  "seq": 4,
  "run_state": "<opaque>",
  "kind": "tool_calls",
  "calls": [
    {"id": "call_1", "name": "Read", "input": {"file_path": "src/app.zig"},
     "confirm": false, "deadline_ms": 30000, "credentials": [],
     "result_limit_bytes": 65536}
  ],
  "text": "optional progress text for the user",
  "usage": {"model": "claude-sonnet-5-5", "input_tokens": 1830, "output_tokens": 92,
            "cache_read_input_tokens": 1500, "cache_creation_input_tokens": 0,
            "cost_micros": 7100, "currency": "USD"},
  "cumulative": {"steps": 4, "cost_micros": 24400, "currency": "USD",
                 "input_tokens": 7300, "output_tokens": 410},
  "issuer": {"skill_host": "metask", "inference_gateway": "metask"},
  "prev_digest": "sha256:…",
  "digest": "sha256:…",
  "sig": "<base64 Ed25519 over digest>"?
}
```

`kind` is one of:

| kind | meaning | fields |
|---|---|---|
| `tool_calls` | execute `calls`, answer with `runs.continue` | `calls` (1..n) |
| `final` | the run is complete | `text` (the Skill's result for the user), `charge` (§4.6) |
| `input_required` | the Skill needs something only the user can give | `question`: `{"message", "schema"?}` (MCP elicitation form shape); answered through `runs.continue` with one result whose `tool_use_id` is the Step's `question.id` |
| `failed` | the run ended without a result | `reason`: `"budget_exceeded" \| "max_steps" \| "cancelled" \| "skill_error" \| "policy_violation" \| "upstream_unavailable"`, `message`, `charge` |

A `usage` block is present on every Step and describes the gateway's work
*since the previous Step* (zero for a pure workflow-engine step).
`cumulative` is the running total. `cost_micros` is **authoritative**: the
client's own token-price tables are an estimate for display; the gateway's
number is what the subscriber is charged (§8.2).

Call fields:

- `confirm: true` means the client MUST obtain an explicit user approval for
  this call even in a permission mode that would otherwise auto-allow it.
- `deadline_ms` is how long the gateway will wait for this Step's results;
  the client SHOULD report `is_error` with `refusal: "aborted"` for a call
  it could not finish in time rather than letting the run die.
- `credentials` names credential references (§6.4) the call needs.
- `result_limit_bytes` caps the result the gateway wants; it MUST NOT exceed
  the manifest's `egress.max_result_bytes`.

### 4.4 `run_state`

An opaque string. The client MUST return it unchanged on the next message
and MUST NOT interpret it. A stateless gateway encodes the run's
conversation and workflow position in it, encrypted and authenticated with
a gateway key (AEAD, key id in the clear), so that a tampered or replayed
blob fails with `run_state_invalid`. Size SHOULD stay under 256 KiB; a
gateway that needs more SHOULD switch to server-side state for that run.

### 4.5 Canonical JSON

Digests are computed over the canonical JSON of an object: UTF-8, keys
sorted by code point, no whitespace, no `+`/leading zeros/exponent in
integers, floats forbidden in digested objects (use integers in micro-units
or strings). The `digest`, `sig` and `run_state` fields are removed before
digesting a Step; `manifest_digest` and `manifest_sig` are not part of the
manifest.

### 4.6 Charge

The `final` and `failed` Steps carry
`charge: {"run_id", "cost_micros", "currency", "steps", "issued_at",
"digest", "sig"?}`: the receipt the client appends to its ledger. A gateway
MUST make `charge.cost_micros` equal `cumulative.cost_micros` of the same
Step.

## 5. Manifest

The manifest is the only part of a Skill the client ever holds. It is
written by the creator, validated and possibly annotated by the gateway at
publish time, and pinned by the user at install time.

```json
{
  "schema": "metask.sealed-skill.manifest/v1",
  "skill_id": "ssk_7f3a…",
  "version": "1.4.0",
  "name": "erp-post-invoice",
  "display_name": "ERP invoice posting",
  "description": "Posts supplier invoices into the ERP from a folder of PDFs. Use when…",
  "when_to_use": "…",
  "argument_hint": "[folder]",
  "arguments": ["folder"],
  "creator": {"id": "cr_…", "display_name": "…"},
  "tools": {
    "allow": ["Read", "Glob", "Grep", "Bash(python3 *)", "mcp__playwright__*"],
    "deny": ["Bash(rm *)"]
  },
  "confirmation": {"required_for": ["Write", "Edit", "mcp__playwright__browser_click"]},
  "egress": {
    "classes": ["file_contents", "command_output", "page_snapshot"],
    "max_result_bytes": 65536,
    "retention": "run"
  },
  "credentials": [{"ref": "erp-main", "purpose": "ERP login", "kind": "password"}],
  "execution": {"classes": ["server"]},
  "pricing": {"model": "subscription", "estimate_micros_per_run": 60000, "currency": "USD"},
  "protection": {"rating": "judgement_heavy", "action_layer_reconstructibility": 0.31},
  "requires": {"protocol": "metask.sealed-skill/v1", "client_min_version": "0.6.0"}
}
```

- `tools.allow` / `tools.deny` use the client's permission-rule syntax
  (`Tool`, `Tool(pattern)`, `prefix__*`). **The client enforces them**
  (§6.2); the gateway promises not to exceed them.
- `confirmation.required_for` lists tools whose calls the gateway MUST mark
  `confirm: true`; the client MAY add more.
- `egress.classes` declares what kinds of data leave the machine as tool
  results: `file_contents`, `command_output`, `page_snapshot`, `images`,
  `repository_structure`, `environment`. A client MUST refuse a call whose
  result would fall outside the declared classes when it can tell (a Read
  under `command_output` only), and MUST show the classes at install time.
  `retention` is the gateway's promise for tool results: `"run"` (discarded
  when the run ends) or `"audit"` (kept for the audit window the operator
  publishes).
- `credentials` declares references the Skill will ask for; the user binds
  each to a local secret at install time or on first use (§6.4).
- `execution.classes` is `["server"]` in revision 2026-10-15; §7 adds
  `client-sealed`.
- `protection` is written by the gateway, not the creator: the publish-time
  self-check's estimate of how much of the Skill a tool trace reconstructs.
  It is informative, shown to the creator, and MAY be shown to users.

A gateway MUST reject a manifest whose `tools.allow` is empty, whose
`egress.classes` is empty while `tools.allow` names a tool that returns
data, or whose `description` is empty.

## 6. Client obligations

### 6.1 Pinning and consent

Installing a Skill means storing its Entry (manifest + digest + signature)
as a pin after showing the user, at minimum: name, description, creator,
the tool allowlist, the egress classes, the credentials it will ask for and
the price estimate. A run MUST send the pinned digest. A `manifest_changed`
error MUST NOT be resolved silently: the client refreshes the Entry and
repeats the consent step with a diff of the manifest.

### 6.2 Policy enforcement

The client evaluates every call in a Step against the pinned
`tools.allow`/`tools.deny` **before** its ordinary permission system sees
it. A call outside the allowlist is never executed; it is answered with
`refusal: "policy_violation"`, logged, and counted. After three policy
violations in one run the client MUST cancel the run with `reason:
"policy"`. A call inside the allowlist then goes through the client's normal
permission, sandbox and budget machinery exactly as a model-originated tool
call would; `confirm: true` additionally forces an interactive approval.

The gateway is an untrusted principal: no path in the client may execute a
gateway-requested tool with more authority than the user's own model would
have had in the same session.

### 6.3 Result limits

Results are truncated to `min(call.result_limit_bytes,
manifest.egress.max_result_bytes)` with `truncated: true`; the client
SHOULD keep the head and a marked tail, as it does for its own model.

### 6.4 Credentials

A credential reference is a name (`erp-main`) bound locally to a secret.
When a call lists references, the client substitutes the secret for the
placeholder `${SEALED_CRED:erp-main}` wherever it appears in string values
of `input`, executes, and then **replaces every occurrence of the secret's
value in the result with `[redacted:erp-main]`** before sending it, listing
the reference in `redactions`. The gateway never receives the secret. A
reference not bound locally makes the call fail with `refusal:
"permission_denied"` and the client prompts the user to bind it.

### 6.5 Budget

Before `runs.start` the client decides `max_cost_micros` (a per-skill or
global setting, or a prompt to the user). It MUST stop executing calls and
cancel with `reason: "budget"` as soon as `cumulative.cost_micros` exceeds
the cap, independently of the gateway's own enforcement.

### 6.6 Audit

For every Step the client records `run_id`, `seq`, `digest`, `prev_digest`,
`issuer`, the call ids and names, a digest of each result it sent,
`usage`, and the `charge` receipt. The record is append-only and local to
the subscriber (§8.3).

## 7. Execution classes beyond `server`

Revision 2026-10-15 defines one execution class, `server`: everything the
Skill is runs on the gateway. Two extensions are reserved and MUST be
advertised through `capabilities` before use:

- **`client-sealed`**: a creator asset compiled to WebAssembly, encrypted
  per run by the sealing issuer, delivered inside a Step and executed by
  the client **in memory only** on a signed runtime whose host calls go
  through the same permission and sandbox as every other tool. The module is
  bound to a machine fingerprint and a time window. This is *deterrent-grade*
  confidentiality plus licensing control, never secrecy: it exists for
  logic that must touch large local state the Skill cannot afford to upload.
- **`prefetch`**: a workflow-engine gateway may include up to N future
  Steps whose inputs do not depend on results, so a transient gateway
  outage does not stall a deterministic run. N is small by design; a
  prefetched sequence must not amount to the workflow.

Both are specified in a later revision; the identifiers are reserved here
so manifests and capability negotiation do not change shape.

## 8. Security and accountability

### 8.1 Provider credentials never cross

The gateway calls models with its own keys and charges the subscriber. A
client MUST NOT send provider keys; a gateway MUST NOT ask for them. A user
who only has their own provider keys and no gateway account cannot run
sealed Skills; the client says so rather than proxying.

### 8.2 Metering

`usage.cost_micros` is the gateway's authoritative charge, derived from the
gateway's own upstream usage records. When the inference gateway and the
billing identity are the same operator this is first-party data; a later
revision defines reconciliation for a third-party skill host. The client
may display its own estimate from tokens, labelled as such.

### 8.3 Tamper-evident log

Steps form a hash chain: `prev_digest` is the previous Step's `digest`
(`sha256:` over 32 zero bytes for `seq: 1`), and the client's `results` are
digested into the next Step by the gateway (the gateway includes
`results_digest` in the Step it derives from them). Either side can show,
after the fact, what the other sent. With `step_signature`, `sig` is an
Ed25519 signature by the inference gateway over `digest`; the key is
published at `<gateway>/.well-known/sealed-skill.json`.

### 8.4 Replay and ordering

`run_state` is authenticated; `seq` is checked; a `runs.continue` for a
`seq` already answered is rejected. A client that crashes mid-run cannot
resume it (there is no resume method in v1); it cancels or lets the
gateway's run deadline expire, and is charged for the work done.

### 8.5 Disclosure through the model

Tool results are untrusted data to the gateway's model, exactly as they are
to the client's. A gateway SHOULD screen outgoing call inputs and `text`
against the Skill's own content (n-gram and embedding similarity), SHOULD
seed each creator's Skill with canary phrases, and MUST log and attribute
an attempt to the subscriber account. Operators publish what they do here;
the protocol does not promise that extraction is impossible.

### 8.6 Attested gateway (reserved)

A gateway MAY run Skills inside an attested enclave and publish the
attestation under `.well-known/sealed-skill.json`, so that creators can
encrypt Skills to the enclave and the operator's staff cannot read them.
The protocol fields do not change; `discover.capabilities.attestation`
is reserved for it.

### 8.7 Protecting the user from the Skill

The manifest allowlist, egress classes and `confirm` flags are enforced by
the client, and the gateway reviews Skills at publish time (allowlist versus
stated purpose) and watches runs for anomalies (a Skill that reads
credential directories it never declared). Those are gateway duties the
operator publishes; the client's duty is to never execute what the pin did
not consent to.

## 9. Reference implementation: metacodes

This section is informative for other implementations and binding for
metacodes. Both sides of the protocol live in `src/skills/sealed/`:
`protocol.zig` (objects, digests, envelope), `transport.zig` (client HTTP),
`pin.zig`, `credentials.zig`, `provider.zig` and `ledger.zig` (client),
`gateway.zig` (server). `tests/component/sealed_skill_test.zig` runs a pinned
Skill through a loopback gateway whose model is a mock SSE server, with a
probe standing in for the session's UI, and asserts the Skill body reaches
only the model, the tool result is produced locally, the ledger holds the
charge, an allowlist violation is refused locally, the bearer token gates the
gateway, a stale pin is refused before any model call, a `confirm: true`
call is approved interactively in bypass mode (and a declined one reported as
`permission_denied`), an `input_required` Step is answered through the UI
channel and the run continues (or ends with the question when there is no
channel), and a bound credential is substituted into the call and redacted
from the result while an unbound one refuses the call.

### 9.1 Client

- **Catalog.** `metacodes sealed install <gateway> <skill_id>` fetches the
  Entry, verifies the digest, prints the consent summary (§6.1) and writes
  the pin under `<state root>/sealed-skills/<name>/`: `sealed.json` (the
  Entry verbatim, gateway URL, token variable) and a projected `SKILL.md`
  whose frontmatter carries the listing fields, the allowlist as
  `allowed-tools` / `disallowed-tools`, `context: fork` and the three
  binding keys `sealed-gateway`, `sealed-skill-id`,
  `sealed-manifest-digest`, with a body of `$ARGUMENTS`. The pin root is a
  personal-tier catalog source above every other personal source, so no
  local file shadows a subscribed name. `metacodes sealed list` prints the
  pins; a `sealed.json` that no longer verifies is listed as broken.
- **Activation.** `/name` and the `Skill` tool prepare the same activation
  plan as a local forked Skill. Execution re-reads and re-verifies the pin,
  checks it against the catalog's binding, and spawns the existing subagent
  loop with a `SealedSkillProvider` in place of the model provider: its
  `sendStream` sends `runs.start` on the first call (prompt = the rendered
  arguments, tools = the loop's definitions filtered by the allowlist) and
  `runs.continue` with the new `tool_result` blocks afterwards, replaying
  each Step as neutral stream events (`text`, `tool_use_start` per call,
  `usage`, `done` with stop reason `tool_use` or `end_turn`). The loop
  executes the calls through the ordinary dispatch, so permission, sandbox,
  artifact storage and observation sinks are unchanged. No local model
  client is needed to run a sealed Skill.
- **Chain and sequence.** Every Step's `digest` is recomputed and its
  `prev_digest` / `seq` checked against the previous Step before anything
  is recorded; a mismatch ends the run with `SealedChainBroken`.
- **Policy.** The policy frame derived from the pinned allowlist refuses a
  call outside it before dispatch; the provider reports the refusal as
  `policy_violation`, counts it, and cancels the run with `reason: policy`
  at the third. Results are truncated to the smaller of the call's and the
  manifest's byte cap.
- **Budget.** The cap is `METACODES_SEALED_MAX_COST_MICROS` (default
  `500000`, USD 0.50). It is sent as `budget.max_cost_micros`, enforced by
  the provider on the gateway's `cumulative` (cancel with `reason:
  budget`), and passed to the child loop as `cost_budget_usd` for its own
  estimate-based stop.
- **Ledger.** A `step` record per Step and a `charge` record per receipt
  go to `<state root>/ledger/sealed.ndjson`; `metacodes sealed ledger`
  prints it.
- **Confirmation.** A call marked `confirm: true` is approved
  interactively whatever the permission mode (§6.2). The provider does not
  decide permissions: it answers the child permission context's *confirm
  gate* (`permission/confirm_gate.zig`), which the loop consults after the
  ordinary decision and which can only tighten — an `allow` becomes an `ask`
  whose prompt ignores a remembered "allow always" for the tool (a
  remembered deny still denies), and the stream prefetch never starts a
  gated call. A declined prompt is reported as `refusal: permission_denied`.
- **Credentials.** `metacodes sealed bind <name> <ref>` (secret from stdin
  or `--from-env VAR`, never argv) binds a reference the pinned manifest
  declares to a local secret, scoped to that Skill's `skill_id`, in
  `<state root>/sealed-credentials.json` (mode 0600; a file of its own
  rather than a section of `auth.json`, whose writers rebuild the whole
  document from their own struct on every OAuth refresh). `metacodes sealed
  unbind` removes it and `metacodes sealed list` shows each pin's references
  as bound or not. For a call that lists references the provider replaces
  `${SEALED_CRED:<ref>}` in the input JSON with the JSON-escaped secret
  before streaming the call to the loop, and replaces every byte-exact
  occurrence of the secret in the result with `[redacted:<ref>]` *before*
  truncation, listing the reference in `redactions`. A reference the
  manifest does not declare, or one not bound here, is never dispatched: the
  call is answered with `refusal: permission_denied` and the bind command,
  and the same hint is prepended to the fork's result for the user. A result
  that is JSON-escaped or otherwise transformed differently from the secret
  is not recognized; redaction is byte-exact.
- **Input.** An `input_required` Step is put to the user as one
  `ask_question` dialog over the session's UI requester (the tool context's
  at the top level, else the permission context's), with the options of a
  single-property `enum` in the elicitation schema and the dialog's
  free-text entry otherwise; the answer is sent as the Step's one result
  (`tool_use_id` = `question.id`) in `runs.continue` and the run goes on. A
  dismissed dialog sends `is_error` with `refusal: aborted`. Without a
  channel (headless, or an asynchronous front end that can only stash the
  question) the run is cancelled and the question becomes the fork's text.
- **Token.** The bearer token is read from the environment variable named
  by the pin (`--token-env`, default `METACODES_SEALED_TOKEN`).
- **Transport.** One `std.http.Client` POST per request with
  `Sealed-Skill-Version: 1`; JSON and SSE answers are both accepted;
  in-flight requests sit in the shared abort registry with a two-minute
  liveness limit, so Ctrl+C and a dead socket both end the call.
- **Not in revision 2026-10-15 of the client:** suspending a fork on an
  `input_required` Step for an asynchronous front end (the run is cancelled
  instead, see *Input*); `confirmation: "always"` as a client setting (the
  manifest and the gateway decide which calls carry `confirm`); a run-level
  budget prompt (the cap is the environment variable).

### 9.2 Gateway

`metacodes sealed serve --skills <dir> [--listen PORT] [--token T]
[--provider KIND] [--model M] [--base-url U] [--api-key-env NAME]` is the
reference gateway. A package is `<dir>/<name>/SKILL.md` plus
`manifest.json` (§5, creator fields only); the manifest is canonicalized and
digested at load, and the body becomes the model's system prompt and never
leaves the process. The server listens on loopback only and answers requests
in order; TLS, fan-out and non-loopback exposure are a reverse proxy's job.

- **Provider.** The gateway calls the model with the operator's own
  credentials (`--api-key-env`, default `ANTHROPIC_API_KEY` /
  `OPENAI_API_KEY` / `GEMINI_API_KEY` by kind) through the same provider
  factory the CLI uses; a client's key is never accepted (§8.1).
- **Stateless runs.** The whole run — conversation, pending calls, totals,
  caps — is sealed into `run_state` with XChaCha20-Poly1305 under a process
  key, with the run id as associated data; `runs.continue` and
  `runs.cancel` fail with `run_state_invalid` on a tampered, replayed or
  foreign blob, or a `seq` that does not match. Nothing is stored
  server-side, which is what `retention: "run"` means here.
- **Steps.** Each model call is one Step: `tool_calls` while the model
  calls tools (with `confirm` from the manifest or `confirmation: always`,
  `credentials` from the manifest-declared placeholders the input names,
  and `result_limit_bytes` from the manifest), `input_required` when the
  model calls the gateway's own `AskUser` tool, `final` on `end_turn`,
  `failed` on a budget cap, the step limit, three client policy refusals,
  a cancel, or a model stop the Skill cannot continue from. The digest is
  computed before the state is sealed with it as chain head, then both are
  attached.
- **Input.** `AskUser` (`message`, optional elicitation `schema`) is
  appended to the client's tool definitions on every model call, and the
  system prompt tells the model when to use it. The first `AskUser` call of
  a turn becomes an `input_required` Step whose `question.id` is that call's
  id; its answer arrives as the Step's one result and enters the
  conversation as the call's `tool_result`. Other calls the model issued in
  the same turn are not sent (a Step is one kind): the gateway answers them
  itself with an error result asking the model to call again. `discover`
  reports `capabilities.input_required: true`.
- **Credentials.** The system prompt lists the manifest's credential
  references as `${SEALED_CRED:<ref>}` placeholders with their purpose; a
  call whose input contains a declared placeholder carries that reference
  in `credentials`, and only those (an undeclared name is left for the
  client to refuse).
- **Metering.** `usage.cost_micros` is derived from the provider's reported
  tokens and the local price table; `cumulative` and `charge` carry the
  running total. The gateway stops with `budget_exceeded` as soon as the
  total passes the client's cap.
- **Not in revision 2026-10-15 of the gateway:** Step signatures
  (`step_signature: false`), subscriptions and per-account authorization
  beyond the single bearer token, the publish-time protection rating, and
  the disclosure screening of §8.5.

## 10. Error codes

JSON-RPC `error.code` in the application range, `error.data.code` carrying
the symbolic name:

| code | name | meaning |
|---|---|---|
| -32001 | `unauthorized` | token missing or invalid |
| -32002 | `subscription_required` | the account may not run this Skill |
| -32003 | `skill_not_found` | unknown or invisible `skill_id` |
| -32004 | `manifest_changed` | pinned digest is not current; `data.current` holds the Entry |
| -32005 | `run_not_found` | unknown `run_id` |
| -32006 | `run_state_invalid` | tampered, replayed or stale `run_state`/`seq` |
| -32007 | `budget_exceeded` | the run would pass `max_cost_micros` |
| -32008 | `policy_violation` | the client reported refusals the gateway cannot recover from |
| -32009 | `rate_limited` | retry after `data.retry_after_ms` |
| -32010 | `unsupported_version` | `Sealed-Skill-Version` not implemented |
| -32011 | `upstream_unavailable` | the gateway's model provider failed |

## 11. Versioning

The protocol identifier carries the major version; `revisions` lists the
dated minor revisions a gateway implements. A minor revision adds fields or
capabilities; it never changes the meaning of an existing field. A client
MUST ignore unknown fields in Steps and Entries and MUST NOT ignore an
unknown `kind`: an unknown `kind` ends the run as `failed` with `reason:
"client_error"`.

## 12. Creator-side publishing (informative)

A Skill package is `SKILL.md` (frontmatter and body as today), the manifest
(§5, without the gateway-written fields), and optionally a workflow
definition that lets the gateway drive the happy path without a model and
reserve the model for exceptions, plus assets for the `server` class. The
gateway validates the package, computes the protection rating from sample
runs, signs the manifest, and lists it. Creators are paid per successful
run or per subscription period from the gateway's metering; the wire
protocol carries nothing of that relationship except the identities in
§4.2.
