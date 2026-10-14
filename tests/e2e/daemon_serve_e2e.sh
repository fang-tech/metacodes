#!/usr/bin/env bash
# daemon serve e2e: the real `metacodes serve` (one session) against a loopback
# mock provider (tests/e2e/daemon_mock_provider.py; no network, no paid call).
#
#   1. Default surface (127.0.0.1, no token): GET /health (#251), message →
#      agent_loop → journal → SSE, rich /state, /command (/mode dont-ask and the
#      `!cmd` shell lane), SIGINT shutdown.
#   2. Bearer token from METACODES_WEB_TOKEN (#252) on --web-bind ::1 (#253;
#      127.0.0.1 on an IPv4-only host): /health stays open, everything else
#      needs the token (header, or ?token= on GET), a POST never takes it from
#      the query, the token is never printed.
#   3. A non-loopback bind without a token is refused (exit 2) before anything
#      starts, from the flag and from METACODES_WEB_BIND.
#
# Run by `zig build test` on POSIX hosts (build.zig sets
# METACODES_DAEMON_E2E_BIN); by hand: `zig build && bash tests/e2e/daemon_serve_e2e.sh`.
set -euo pipefail
# shellcheck source=tests/e2e/daemon_e2e_lib.sh
source "$(dirname "$0")/daemon_e2e_lib.sh"

start_mock
version="$(binary_version)"
[[ -n "$version" ]] || fail "metacodes --version printed no version"

# ── 1. default surface ──────────────────────────────────────────────────────
start_daemon "$TMP/plain.out" "$BIN" serve 0 --api-key test --base-url "$BASE_URL"
wait_listening "$TMP/plain.out"
url="$DAEMON_URL"
[[ "$url" == http://127.0.0.1:* ]] || fail "default bind is not 127.0.0.1: $url"
grep -q "daemon (1 session): $url" "$TMP/plain.out" || fail "unexpected startup line"
if grep -q "bearer-token auth is on" "$TMP/plain.out"; then fail "auth note without a token"; fi
check_health "$url" "$version" 1

ack="$("${CURL[@]}" -X POST "$url/message" -H "Origin: $url" -d '{"text":"hi"}')"
grep -q '"ok":true' <<<"$ack" || fail "/message not accepted: $ack"
events="$(events_until '"run_done".*end_turn' "$url/events")" || fail "no run_done end_turn: $events"
grep -q "DAEMON_OK" <<<"$events" || fail "SSE has no assistant text (driver did not run agent_loop?)"

# Rich /state and the canonical command surface (U11).
state="$("${CURL[@]}" "$url/state")"
grep -q '"session_id"' <<<"$state" || fail "/state is not the rich snapshot: $state"
grep -q '"permission_mode"' <<<"$state" || fail "/state lacks permission_mode: $state"
cack="$("${CURL[@]}" -X POST "$url/command" -H "Origin: $url" -d '{"cmd":"/mode dont-ask"}')"
grep -q '"ok":true' <<<"$cack" || fail "/command not queued: $cack"
events="$(events_until 'permission mode → dont_ask' "$url/events")" || fail "no command_result mode → dont_ask: $events"
"${CURL[@]}" "$url/state" | grep -q '"permission_mode":"dont_ask"' || fail "/state does not show dont_ask"
# The `!cmd` shell lane: runs, and its stdout comes back in command_result.
sack="$("${CURL[@]}" -X POST "$url/command" -H "Origin: $url" -d '{"cmd":"!echo WIRE_SHELL_OK"}')"
grep -q '"ok":true' <<<"$sack" || fail "shell /command not queued: $sack"
events_until 'WIRE_SHELL_OK' "$url/events" >/dev/null || fail "shell output not echoed into command_result"
# Cross-origin POST stays refused.
[[ "$(http_code -X POST "$url/message" -H "Origin: http://evil.example" -d '{"text":"x"}')" == 403 ]] ||
  fail "cross-origin POST not refused"
# DNS rebinding: a foreign Host name is refused without a token.
[[ "$(http_code -H "Host: rebound.example:${url##*:}" "$url/state")" == 403 ]] || fail "rebound Host not refused"

stop_daemon "$TMP/plain.out"

# ── 2. bearer token (environment) on an IPv6 loopback bind ──────────────────
token="e2e-$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
bind="::1"
# A v4-only host (many containers) has no ::1: skip only the IPv6 part.
if ! python3 -c 'import socket; s = socket.socket(socket.AF_INET6); s.bind(("::1", 0))' 2>/dev/null; then
  echo "SKIP: IPv6 bind (no ::1 on this host); the token checks run on 127.0.0.1"
  bind="127.0.0.1"
fi
start_daemon "$TMP/token.out" METACODES_WEB_TOKEN="$token" "$BIN" serve 0 --web-bind "$bind" --api-key test --base-url "$BASE_URL"
wait_listening "$TMP/token.out"
url="$DAEMON_URL"
if [[ "$bind" == "::1" ]]; then
  [[ "$url" == "http://[::1]:"* ]] || fail "startup line does not show the IPv6 bind: $url"
else
  [[ "$url" == http://127.0.0.1:* ]] || fail "startup line does not show the bind: $url"
fi
grep -q "bearer-token auth is on (token not shown)" "$TMP/token.out" || fail "no auth note"
if grep -qF "$token" "$TMP/token.out"; then fail "the token was printed"; fi
auth=(-H "Authorization: Bearer $token")

check_health "$url" "$version" 1 # no token needed
[[ "$(http_code "$url/state")" == 401 ]] || fail "/state without a token is not 401"
[[ "$(http_code -H "Authorization: Bearer wrong-$token" "$url/state")" == 401 ]] || fail "wrong token is not 401"
[[ "$(http_code --max-time 2 "$url/events")" == 401 ]] || fail "/events without a token is not 401"
[[ "$(http_code -X POST "$url/message?token=$token" -H "Origin: $url" -d '{"text":"query"}')" == 401 ]] ||
  fail "a POST authenticated by query"
[[ "$(http_code "$url/")" == 401 ]] || fail "the SPA loads without a token"
"${CURL[@]}" "$url/?token=$token" | grep -q "<title>metacodes web</title>" || fail "the SPA does not load with ?token="
"${CURL[@]}" "${auth[@]}" "$url/state" | grep -q '"session_id"' || fail "/state with the token failed"
ack="$("${CURL[@]}" "${auth[@]}" -X POST "$url/message" -H "Origin: $url" -d '{"text":"with token"}')"
grep -q '"ok":true' <<<"$ack" || fail "/message with the token not accepted: $ack"
events="$(events_until '"run_done".*end_turn' "$url/events?token=$token")" || fail "SSE with ?token= did not stream: $events"
grep -q '"user_message":"with token"' <<<"$events" || fail "the authenticated message is missing from the stream"
if grep -q '"user_message":"query"' <<<"$events"; then fail "the query-authenticated POST had an effect"; fi
stop_daemon "$TMP/token.out"

# ── 3. non-loopback bind without authentication: refused before startup ────
expect_refusal "$TMP/refuse-flag.out" "$BIN" serve 0 --web-bind 0.0.0.0 --api-key test --base-url "$BASE_URL"
expect_refusal "$TMP/refuse-env.out" METACODES_WEB_BIND=:: "$BIN" serve 0 --api-key test --base-url "$BASE_URL"

echo "PASS: daemon e2e — /health, message→agent_loop→journal→SSE, /state·/command, bearer token, bind $bind, non-loopback refusal, SIGINT shutdown"
