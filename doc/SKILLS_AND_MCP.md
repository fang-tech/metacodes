# Skills and MCP servers

metacodes keeps its own Skills and MCP configuration under its state root
(`~/.metacodes` unless `--state-dir`, `METACODES_HOME` or the install manifest
chooses another), and also reads what Claude Code and Codex users already have,
with each tool's own semantics. This page is the contract for the CLI hosts
(terminal REPL, `--web`, `serve`). AgentCore keeps the narrower,
`.agents/skills`-only policy described in
[AGENTCORE_BINARY_ABI.md](AGENTCORE_BINARY_ABI.md).

## Skills

### Where Skills are found

Every root below is a *compat* source (`catalog.Profile.compat` in
`src/skills/runtime/catalog.zig`). A name defined in several places takes the
highest tier, as in Claude Code — enterprise, then personal, then project — so a
checked-out repository cannot shadow a Skill the user installed.

| Tier | Roots, highest first |
|---|---|
| Enterprise | `/etc/metacodes/skills`, Claude Code's managed `<dir>/.claude/skills` (`/Library/Application Support/ClaudeCode`, `/etc/claude-code`, `C:\Program Files\ClaudeCode`), `/etc/codex/skills` |
| Personal | `<state root>/sealed-skills` (pinned sealed Skills, see below), `<state root>/skills`, `~/.agents/skills`, `~/.claude/skills`, `$CODEX_HOME/skills` (default `~/.codex/skills`) |
| Project | each directory from the repository root down to the working directory — a level closer to the working directory wins — and within a directory `.metacodes/skills`, `.agents/skills`, `.claude/skills`, `.codex/skills` |
| `--add-dir` | `.metacodes/skills`, `.agents/skills`, `.claude/skills` under each added directory |

Discovery follows what both tools do:

- A Skill is a directory holding `SKILL.md`, found up to 6 directory levels
  below a root (Codex); a Skill's own subtree is not searched again.
- Hidden directories and Claude Code's reserved `synced` folder are skipped.
- A symlinked root or Skill directory is followed. A Skill reached through
  several links (the `npx skills` layout links `~/.claude/skills/x` to
  `~/.agents/skills/x`) is loaded once, through its highest-priority path.
- A root that exists but cannot be read is skipped and reported by `/skills`;
  it never hides the other roots.
- Names may contain non-ASCII letters (`/地址库`); spaces, controls and
  zero-width characters are refused with a typed issue.

### `SKILL.md`

The frontmatter is YAML (`src/skills/runtime/frontmatter.zig`): quoted
strings, folded `>` and literal `|` blocks, block and flow lists, nested maps,
comments, CRLF and a BOM all parse. As in Codex, a one-line value that only
looks like a flow collection (`argument-hint: [pr] [priority]`) stays text, and
`key: value: more` keeps everything after the first colon. Unknown keys are
ignored.

| Field | Meaning |
|---|---|
| `name` | display name (the invocation name is the directory name) |
| `description` | listed to the model; when absent, the first body line (Claude Code), and `/skills` reports the Skill |
| `when_to_use` | appended to the description in listings |
| `argument-hint` | shown beside the command in the `/` menu |
| `arguments` | positional names for `$name` substitution |
| `allowed-tools`, `disallowed-tools` | the Skill's tool policy frame |
| `disable-model-invocation` | not listed to the model and not activatable by it; the user can still run `/name` (`skillOverrides` cannot list it) |
| `user-invocable: false` | hidden from the `/` menu, still model-invocable |
| `model`, `context: fork`, `agent` | a forked Skill runs under the named subagent's prompt, tool set, permission mode and model |
| `model-activation`, `shell` | metacodes extensions |

Codex's `agents/openai.yaml` is read too: `policy.allow_implicit_invocation:
false` hides the Skill from the model like `disable-model-invocation`.

A malformed policy value (`context`, `shell`, a boolean, `model-activation`) or
malformed YAML makes the Skill a typed `invalid_definition` issue rather than
silently changing its meaning.

### What the model sees

The system prompt and the `Skill` tool list each model-invocable Skill as
`name — description when_to_use`, whitespace collapsed and capped at 1536
bytes per Skill; past a 16 KiB total, descriptions are shortened and then
dropped (names stay). Activating a Skill returns its rendered body preceded by
`Base directory for this skill: <dir>`: relative references such as
`scripts/x.py` resolve there, and `${CLAUDE_SKILL_DIR}` expands to the same
directory.

For compat sources that directory is the live Skill directory, as in Claude
Code and Codex: only `SKILL.md` and `agents/openai.yaml` are read at startup,
so Skills that carry a virtualenv, `node_modules` or large assets work.
(AgentCore's canonical sources still snapshot and materialize the whole tree.)

### `skillOverrides`

Claude Code's per-Skill setting, read from the same files
(`src/skills/overrides.zig`): `~/.claude/settings.json` <
`<project>/.claude/settings.json` < `<project>/.claude/settings.local.json`,
where the project is the repository root or, outside one, the working
directory.

```json
{ "skillOverrides": { "release-notes": "name-only", "deploy": "off" } }
```

| Value | Model listing | Skill tool | `/name` and `/` menu |
|---|---|---|---|
| `on` (absent) | name and description | admitted | yes |
| `name-only` | name only (`- name`) | admitted | yes |
| `user-invocable-only` | not listed | refused | yes |
| `off` | not listed | refused | refused, not in the menu |

The Skill tool refuses with Claude Code's words (`Skill <name> is disabled
for model invocation in skillOverrides settings`); `/name` of an `off` Skill
prints `Skill "<name>" is disabled via skillOverrides. Re-enable it in /skills
or remove the override from your settings to run it.` in place of its echo.
The Skill Runtime enforces the state at activation, so background jobs and
teammates obey a change at once. An unknown value is ignored (and kept in the
file); a settings file that does not parse contributes nothing.

The `Skill` tool is registered whenever a Skill may be model-invoked by its
definition, so an override changes the tool's description, never the tool
set. The listings change only when an override does: `/skills` closed with
no change leaves the request bytes as they were.

### Commands

- Typing `/` opens the command menu: built-in commands in alphabetical
  order, then every user-invocable Skill (its description followed by its
  tier, e.g. `(user)`, and its `argument-hint`). Prefix matches come first, then substring matches; the
  window scrolls with the selection; Esc closes the menu and keeps the draft.
  Enter on a Skill that takes arguments fills `/name ` instead of submitting.
- `/name args` runs the Skill as a turn of the conversation: the reply
  streams with the spinner and tool cards and Esc interrupts it, as for any
  prompt; the rendered Skill body goes to the model, not to the scrollback.
- In the TUI, `/skills` opens Claude Code's pane: each Skill with its
  `skillOverrides` state, tier and listing cost (`✔ on  name · user · < 20
  tok`), and how many Skills did not load. Enter or Space cycles the selected
  Skill through on → name-only → user-only → off (a
  `disable-model-invocation` Skill is `🔒 locked by author`); typing or `/`
  searches, Esc clears the search, then leaves it, then closes the pane.
  Closing writes the changes to `.claude/settings.local.json` (an entry equal
  to what the project and user settings give is removed) and prints
  `Updated N skill overrides` or `No changes`; the next request carries the
  new listing. Without a terminal (and as the data behind it) `/skills`
  prints the full report: tier, any override state, and directory, the
  Skills without a `description` (listed with their first body line or with
  nothing), the Skills that did not load and why, and skipped roots. The
  startup banner and `/doctor` count these, together with hook and agent
  configuration problems (`/hooks`, `/agents`), so a broken file is noticed
  without knowing where to look.

### Sealed Skills

A sealed Skill is one whose body never reaches this machine: it runs on a
gateway speaking the Sealed Skill Protocol (`metask.sealed-skill/v1`,
[SEALED_SKILL_PROTOCOL.md](SEALED_SKILL_PROTOCOL.md)), and every tool call it
needs is sent back here, executed under the ordinary permission system, and
its result returned. `metacodes sealed install <gateway-url> <skill_id>`
shows the manifest the user consents to (tool allowlist, data egress classes,
credentials, price) and pins it under `<state root>/sealed-skills/<name>/`;
the pin's projected `SKILL.md` carries `sealed-gateway`, `sealed-skill-id`
and `sealed-manifest-digest`, `context: fork`, and the allowlist as
`allowed-tools`. `/skills` lists it like any Skill; `/name args` and the
`Skill` tool run it as a fork whose model is the gateway. The model is this
session's own: the gateway runs the Skill's loop as a shadow of the fork and
calls the model over the session's provider route and credential, so the
request the model sees is the one a local fork would have sent, on the
user's own account and bill. The gateway reports each Step's tokens and its
estimate of their cost; the client stops the run at
`METACODES_SEALED_MAX_COST_MICROS` and records every Step in
`<state root>/ledger/sealed.ndjson` (`metacodes sealed ledger`). The gateway
account owes only the Skill's own fee, when a gateway charges one. A call
the gateway marks `confirm: true` is approved
interactively even in a mode that would auto-allow it; a question the
Skill has for the user is asked through the session's own AskUserQuestion
dialog and answered in place. A credential reference the manifest declares
is bound with `metacodes sealed bind <name> <ref>` (secret from stdin or
`--from-env`), kept in `<state root>/sealed-credentials.json`, substituted
into the call on this machine and redacted from the result before it
leaves. The Skill's public files (scripts, data) are installed under the
pin directory; its `sealed/` reference files are read on the gateway.
`metacodes sealed serve` runs the reference gateway; it has no provider
credentials of its own.

## MCP servers

### Sources and precedence

`src/mcp/config.zig` reads, highest precedence first; a server name takes the
whole entry from the highest source (fields never merge):

| Source | Format | Child environment | `${VAR}` expansion |
|---|---|---|---|
| `<state root>/config.json` `mcpServers` | Claude Code JSON, plus Codex keys | Codex allowlist (`inheritEnv: true` to inherit) | yes |
| `<state root>/config.json` `mcp_servers` | legacy `[{"name", "command": [argv]}]` | Codex allowlist | yes |
| `~/.claude.json` `projects[<cwd>].mcpServers` | Claude Code local scope | inherited | yes |
| `<project>/.mcp.json` | Claude Code project scope, approval required | inherited | yes |
| `~/.claude.json` `mcpServers` | Claude Code user scope | inherited | yes |
| `<dir>/.codex/config.toml` `[mcp_servers.*]` | Codex project layer, trusted projects only | Codex allowlist | no |
| `$CODEX_HOME/config.toml` `[mcp_servers.*]` | Codex user layer | Codex allowlist | no |

`"mcpImport": {"claude": false, "codex": false}` turns the foreign sources off;
an entry `{"enabled": false}` without a command or URL disables that name in
every lower source.

A `.mcp.json` server runs a command from a checked-out repository, so it starts
only when approved: `enableAllProjectMcpServers` or `enabledMcpjsonServers` in
metacodes' config, in Claude Code's user or local settings, or in Claude Code's
per-project state in `~/.claude.json`. `disabledMcpjsonServers` anywhere wins,
and the shared `.claude/settings.json` can reject but not approve. A Codex
project layer is read only when `$CODEX_HOME/config.toml` marks the project
`trust_level = "trusted"`.

### Entry fields

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"},
      "envVars": ["HTTPS_PROXY"],
      "cwd": "/path",
      "startupTimeoutSec": 30,
      "toolTimeoutSec": 300,
      "enabledTools": ["create_issue"],
      "disabledTools": []
    },
    "docs": {
      "type": "http",
      "url": "https://example.com/mcp",
      "headers": {"X-Team": "core"},
      "bearerTokenEnvVar": "DOCS_TOKEN"
    }
  }
}
```

Codex's snake_case spellings (`env_vars`, `startup_timeout_sec`,
`tool_timeout_sec`, `enabled_tools`, `disabled_tools`, `bearer_token_env_var`,
`http_headers`, `env_http_headers`) are accepted in JSON as well, and Claude
Code's per-call `timeout` (milliseconds). `type` may be `stdio` (or absent with
`command`), `http` / `streamable-http`, or `sse`.

- **Environment.** The allowlist is Codex's `DEFAULT_ENV_VARS` (`HOME`,
  `LOGNAME`, `PATH`, `SHELL`, `USER`, `LANG`, `LC_ALL`, `TERM`, `TMPDIR`, `TZ`,
  and the Windows equivalents) plus the CA-bundle variables, then `env_vars`,
  then `env`. A bare command is looked up on the child's own `PATH`; a relative
  path resolves against `cwd` (default: the session's working directory).
- **Timeouts.** The handshake has 30 s by default; a server that does not
  answer is reported and the others start anyway (all servers start in
  parallel). Tool calls are unbounded unless a tool timeout is configured
  (Codex entries default to 300 s); an expired call is cancelled with
  `notifications/cancelled`.
- **Logs.** Each stdio server's stderr goes to `<state root>/logs/mcp/<name>.log`.

### Tools

Tools register as deferred `mcp__<server>__<tool>`, Claude Code's form, so its
permission rules (`mcp__server`, `mcp__server__*`, `mcp__server__get_*`,
`mcp__server__tool`), Skill `allowed-tools` and subagent `tools:` lists apply
unchanged. Characters outside `[A-Za-z0-9_-]` become `_`; a name over 64
bytes, or one that collides after that, keeps a readable prefix and ends in a
stable hash. The earlier metacodes name `<server>__<tool>` still selects the
same tool in those lists and rules. Resources are read through
`ListMcpResourcesTool` and `ReadMcpResourceTool`.

### Protocol

The client (`src/mcp/client.zig`) speaks MCP 2026-07-28 and the handshake
revisions 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05:

- It first sends `server/discover`. A 2026-07-28 answer selects the stateless
  protocol: every request carries `_meta` (protocol version, client
  capabilities, client info), results carry `resultType` (absent means
  `complete`), and an `input_required` result is fulfilled (elicitation through
  the host's handler, declined when there is none) and retried with
  `inputResponses` and the echoed `requestState` under a new request id.
- Any other answer falls back to `initialize` (never keyed to one error code).
  Over stdio, a server that exits or stays silent on the probe is restarted for
  the handshake. Over HTTP, a timeout, a network failure or 401/403 is an error,
  not a reason to fall back.
- The handshake answers server `ping`s and form-mode elicitation requests;
  undeclared requests get `method_not_found`. `tools/list` follows
  `nextCursor` (an empty string is a cursor too).
- Streamable HTTP POSTs every message with `Accept: application/json,
  text/event-stream`, reads JSON or SSE responses (a mid-stream server request
  is answered on its own POST), keeps the handshake's `MCP-Session-Id` and
  `MCP-Protocol-Version` (DELETE on close), and sends `Mcp-Method`, `Mcp-Name`
  and `Mcp-Param-*` (from `x-mcp-header`; a tool with an invalid annotation is
  dropped) on 2026-07-28. OAuth login is not implemented: authenticate with
  `bearerTokenEnvVar` or headers.
- A server's requests share one kept-alive connection while they come in quick
  succession (the handshake, a burst of tool calls), so startup costs one TLS
  handshake rather than one per message, and `Connection: close` is never
  sent (Vercel-hosted servers such as developers.openai.com drop such
  requests). A connection is reused only after its response was read to the
  end — an answered SSE stream is finished before the next request, waiting
  at most 250 ms of silence — and only within 4 s of its last use; a request
  that finds a reused connection already closed by the server, before any
  response byte, is sent again on a new connection.

### `/mcp`

`/mcp` lists every configured server with its source, state (connected and
the negotiated revision, or why it failed), tool count and log, followed by
project servers awaiting approval, disabled names and configuration problems.
The tool list is fixed for a session (it is part of the cached prompt); when a
server announces `notifications/tools/list_changed`, `/mcp` says so and the new
list applies after a restart.

## Tests and evaluations

A test that isolates metacodes with a temporary `HOME` must also drop
`CODEX_HOME`: it is an absolute path that the temporary `HOME` does not move,
and the product would load the caller's Codex Skills and start the MCP servers
in its `config.toml`. `build.zig` removes it from every step it runs (as it
sets `METACODES_JEV_URL=off`); the harnesses that run outside the build —
`tests/e2e/lib.sh`, the TTY driver, the session-memory and runtime-arm smokes,
the memory-agent runtime's scripted arms and the plugin gate and pair runner —
remove it from the child environment themselves.
