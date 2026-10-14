#!/usr/bin/env bash
# serve-multi e2e: the real `metacodes serve --sessions 2 --uds <path>` against a
# loopback mock provider (tests/e2e/daemon_mock_provider.py; no network, no
# paid call), with bearer-token auth from METACODES_WEB_TOKEN (#252).
#
#   - GET /health (#251): open, version as `--version` prints it, sessions 2.
#   - The HTTP surface needs the token on every other route (the landing page
#     and session routes included); the UDS transport does not: its access
#     control stays the socket file's 0600 mode.
#   - The resolver routes /s/<id>/* to its own session: message isolation,
#     unknown session → 404, the idle /interrupt gate (409), per-session rich
#     /state and /command (/mode dont-ask) isolation.
#   - UDS + NDJSON: list / message / attach (since, streaming) / interrupt,
#     mid-run interrupt ends the run as aborted, consecutive messages.
#   - SIGINT shuts both drivers down cleanly.
#
# Run by `zig build test` on POSIX hosts (build.zig sets
# METACODES_DAEMON_E2E_BIN); by hand: `zig build && bash tests/e2e/daemon_serve_multi_e2e.sh`.
set -euo pipefail
# shellcheck source=tests/e2e/daemon_e2e_lib.sh
source "$(dirname "$0")/daemon_e2e_lib.sh"

start_mock
version="$(binary_version)"
[[ -n "$version" ]] || fail "metacodes --version printed no version"
token="e2e-$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
auth=(-H "Authorization: Bearer $token")
usock="$TMP/daemon.sock"

start_daemon "$TMP/multi.out" METACODES_WEB_TOKEN="$token" \
  "$BIN" serve 0 --sessions 2 --uds "$usock" --api-key test --base-url "$BASE_URL"
wait_listening "$TMP/multi.out"
url="$DAEMON_URL"
[[ "$url" == http://127.0.0.1:* ]] || fail "default bind is not 127.0.0.1: $url"
grep -q "daemon (2 sessions): $url" "$TMP/multi.out" || fail "unexpected startup line"
if grep -qF "$token" "$TMP/multi.out"; then fail "the token was printed"; fi
# Both session ids (each printed as "session <id> ready"). bash 3.2 compatible.
sids=($(grep -oE "session [0-9a-f]{24} ready" "$TMP/multi.out" | awk '{print $2}' | sort -u))
[[ "${#sids[@]}" -eq 2 ]] || fail "expected 2 sessions, got ${#sids[@]}"
A="${sids[0]}"
B="${sids[1]}"
echo "session A=$A  B=$B"

# ── #251/#252: /health is open, everything else needs the token ─────────────
check_health "$url" "$version" 2
[[ "$(http_code "$url/")" == 401 ]] || fail "landing page served without the token"
[[ "$(http_code "$url/s/$A/state")" == 401 ]] || fail "/s/<id>/state served without the token"
[[ "$(http_code --max-time 2 "$url/s/$A/events")" == 401 ]] || fail "/s/<id>/events served without the token"
[[ "$(http_code -X POST "$url/s/$A/message?token=$token" -H "Origin: $url" -d '{"text":"query"}')" == 401 ]] ||
  fail "a POST authenticated by query"

# Unknown session → 404 (authenticated).
[[ "$(http_code "${auth[@]}" "$url/s/deadbeefdeadbeefdeadbeef/events")" == 404 ]] || fail "unknown session is not 404"

# The landing page: an honest multi-session page, not the single-session SPA.
root="$("${CURL[@]}" "${auth[@]}" "$url/")"
grep -q "multi-session" <<<"$root" || fail "GET / is not the multi-session landing page"
grep -q "$A" <<<"$root" || fail "landing page does not list session A"
grep -q "$B" <<<"$root" || fail "landing page does not list session B"
grep -q "/health" <<<"$root" || fail "landing page does not list /health"

# ── routing isolation ────────────────────────────────────────────────────────
ack="$("${CURL[@]}" "${auth[@]}" -X POST "$url/s/$A/message" -H "Origin: $url" -d '{"text":"hi-A"}')"
grep -q '"ok":true' <<<"$ack" || fail "/s/A/message not accepted: $ack"
evA="$(events_until '"run_done".*end_turn' "${auth[@]}" "$url/s/$A/events")" || fail "A has no run_done end_turn: $evA"
grep -q "DAEMON_OK" <<<"$evA" || fail "A's stream has no assistant text"
evB="$("${CURL[@]}" --max-time 1 "${auth[@]}" "$url/s/$B/events" 2>/dev/null || true)"
if grep -q "DAEMON_OK" <<<"$evB"; then fail "A's message reached B's journal"; fi
if grep -q '"run_done"' <<<"$evB"; then fail "B ran without a message"; fi

# S1: an idle /interrupt is refused by the generating gate and must not
# swallow the next message.
[[ "$(http_code "${auth[@]}" -X POST "$url/s/$B/interrupt" -H "Origin: $url")" == 409 ]] ||
  fail "idle /interrupt is not 409 (generating gate missing)"
ackB="$("${CURL[@]}" "${auth[@]}" -X POST "$url/s/$B/message" -H "Origin: $url" -d '{"text":"hi-B"}')"
grep -q '"ok":true' <<<"$ackB" || fail "/s/B/message not accepted: $ackB"
events_until "DAEMON_OK" "${auth[@]}" "$url/s/$B/events" >/dev/null || fail "B produced nothing after its message"

# ── per-session /state and /command ──────────────────────────────────────────
"${CURL[@]}" "${auth[@]}" "$url/s/$A/state" | grep -q "\"session_id\":\"$A\"" || fail "A's /state is not its own snapshot"
cackA="$("${CURL[@]}" "${auth[@]}" -X POST "$url/s/$A/command" -H "Origin: $url" -d '{"cmd":"/mode dont-ask"}')"
grep -q '"ok":true' <<<"$cackA" || fail "A's /command not queued: $cackA"
events_until 'permission mode → dont_ask' "${auth[@]}" "$url/s/$A/events" >/dev/null || fail "A has no command_result mode → dont_ask"
"${CURL[@]}" "${auth[@]}" "$url/s/$A/state" | grep -q '"permission_mode":"dont_ask"' || fail "A's /state does not show dont_ask"
if "${CURL[@]}" "${auth[@]}" "$url/s/$B/state" | grep -q '"permission_mode":"dont_ask"'; then
  fail "A's /mode changed B"
fi

# ── UDS + NDJSON: no token; the socket file's 0600 mode is the access control ─
[[ -S "$usock" ]] || fail "UDS socket not created: $usock"
mode="$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$usock")"
[[ "$mode" == 0o600 ]] || fail "UDS socket mode is $mode, not 0600"
# Written out first: bash 3.2 mis-parses a heredoc inside $(...) that has an apostrophe.
cat >"$TMP/uds_check.py" <<'PY'
import socket, sys, json, time
path, A, B = sys.argv[1], sys.argv[2], sys.argv[3]
def conn():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(path); return s
def req(obj):  # one request, one response line
    s = conn(); s.sendall((json.dumps(obj)+"\n").encode()); s.settimeout(3)
    try: data = s.recv(65536).decode()
    except socket.timeout: data = ""
    s.close(); return data
def attach_lines(sid, since, secs):  # the attach stream's NDJSON lines within secs seconds
    s = conn(); s.sendall((json.dumps({"op":"attach","session":sid,"since":since})+"\n").encode())
    s.settimeout(secs); buf=""
    try:
        while True:
            d = s.recv(65536)
            if not d: break
            buf += d.decode()
    except socket.timeout: pass
    s.close()
    return [ln for ln in buf.split("\n") if ln]

lst = req({"op":"list"}); assert A in lst and B in lst, "list lacks a session id: "+lst
unk = req({"op":"message","session":"deadbeefdeadbeefdeadbeef","text":"x"})
assert '"ok":false' in unk and "unknown session" in unk, "unknown session not refused: "+unk

# since / streaming / delivery / isolation.
base = attach_lines(A, 0, 2); n0 = len(base)
assert n0 > 0, "A's baseline journal is empty"
MARK = "uds-mark-A-7f3c9"
m = req({"op":"message","session":A,"text":MARK}); assert '"ok":true' in m, "UDS message not accepted: "+m
newl = attach_lines(A, n0, 3); joined = "\n".join(newl)
assert MARK in joined, "since=n0 did not stream the new UDS message echo: "+joined[:300]
far = attach_lines(A, n0+1000, 2)
assert MARK not in "\n".join(far), "since ignored: a far cursor replayed the old mark"
bl = attach_lines(B, 0, 2)
assert MARK not in "\n".join(bl), "UDS routing leak: A's message is in B's journal"

# interrupt: refused while idle, accepted while generating.
it = req({"op":"interrupt","session":B})
assert '"ok":false' in it and "not generating" in it, "idle interrupt gate (S1) broken: "+it
sg = req({"op":"message","session":B,"text":"SLOWGEN interrupt-me"}); assert '"ok":true' in sg
time.sleep(0.7)  # the driver is now inside the mock's 2 s hold: B is generating
it2 = req({"op":"interrupt","session":B})
assert '"ok":true' in it2, "interrupt while generating was refused: "+it2

# The interrupt really ends the run as aborted.
deadline = time.time() + 6; aborted_done = False
while time.time() < deadline:
    if any('"run_done"' in l and '"aborted"' in l for l in attach_lines(B, 0, 1)):
        aborted_done = True; break
    time.sleep(0.3)
assert aborted_done, "the SLOWGEN interrupt did not end B's run as aborted"

# Consecutive messages each run.
rd_before = sum(1 for l in attach_lines(A, 0, 1) if '"run_done"' in l)
assert '"ok":true' in req({"op":"message","session":A,"text":"multi-one-abc"})
time.sleep(0.5)
assert '"ok":true' in req({"op":"message","session":A,"text":"multi-two-def"})
time.sleep(1.0)
allA = attach_lines(A, 0, 2); joinedA = "\n".join(allA)
rd_after = sum(1 for l in allA if '"run_done"' in l)
assert rd_after >= rd_before + 2, "consecutive messages did not each run: %d→%d" % (rd_before, rd_after)
assert "multi-one-abc" in joinedA and "multi-two-def" in joinedA, "a consecutive message echo is missing"

print("UDS_OK")
PY
uds_out="$(python3 "$TMP/uds_check.py" "$usock" "$A" "$B" 2>&1)" || fail "UDS checks failed: $uds_out"
grep -q "UDS_OK" <<<"$uds_out" || fail "UDS checks did not finish: $uds_out"

stop_daemon "$TMP/multi.out"

echo "PASS: serve-multi e2e — /health, bearer token (HTTP) vs 0600 UDS, routing isolation, UDS list/message/attach/interrupt, per-session /state·/command, SIGINT shutdown"
