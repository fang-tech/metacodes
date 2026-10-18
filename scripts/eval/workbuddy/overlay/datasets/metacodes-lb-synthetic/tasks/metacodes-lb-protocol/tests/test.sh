#!/bin/bash
set -euo pipefail
mkdir -p /logs/verifier
expected="$(mktemp)"
printf 'metacodes workbuddy leaderboard protocol ok\n' > "$expected"
if cmp -s "$expected" /workspace/result.txt; then
  printf '1\n' > /logs/verifier/reward.txt
else
  printf '0\n' > /logs/verifier/reward.txt
fi
