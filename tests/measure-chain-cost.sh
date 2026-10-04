#!/bin/sh
# Regression test for scripts/measure-chain-cost.py (the chain-cost readout).
#
# Subagent transcripts (<proj>/<session-uuid>/subagents/agent-*.jsonl) carry
# isSidechain=true on EVERY record. The readout once skipped sidechain records
# there too, so subagent_calls / subagent_cost came out 0 for every session.
# The fixture holds one session with one main call and one subagent call whose
# records are all sidechain, and asserts the subagent cost is counted and the
# four CSVs land in the requested output dir.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOL="$REPO/scripts/measure-chain-cost.py"

command -v python3 >/dev/null || { echo "python3 not in PATH"; exit 1; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SESS=11111111-2222-3333-4444-555555555555
PROJ="$T/projects/-fixture"
mkdir -p "$PROJ/$SESS/subagents" "$T/chains"

# cost = 1.0*input + 0.1*cache_read + 1.25*cache_creation + 5*output (no breakdown)
printf '%s\n' '{"type":"assistant","isSidechain":false,"timestamp":"2026-09-01T10:00:00Z","message":{"id":"m1","model":"x","usage":{"input_tokens":100,"output_tokens":10}}}' > "$PROJ/$SESS.jsonl"
printf '%s\n' '{"type":"assistant","isSidechain":true,"timestamp":"2026-09-01T10:01:00Z","message":{"id":"s1","model":"x","usage":{"input_tokens":200,"output_tokens":20}}}' > "$PROJ/$SESS/subagents/agent-x.jsonl"
printf '%s\n' "{\"chain\":\"c1\",\"n\":1,\"slug\":\"fx\",\"session\":\"$SESS\"}" > "$T/chains/-fixture.jsonl"

OUT="$T/out/nested"
python3 "$TOOL" "$T/projects" "$T/chains" "$OUT" >"$T/log" 2>&1 || { bad "tool exits 0"; cat "$T/log"; }

for f in calls sessions chains chain_counterfactual; do
  [ -f "$OUT/$f.csv" ] && ok "$f.csv written to the given output dir" || bad "$f.csv written to the given output dir"
done

# sessions.csv: subagent_calls=1, subagent_cost=300 (200 + 5*20)
ROW=$(python3 -c '
import csv, sys
r = list(csv.DictReader(open(sys.argv[1])))
print(r[0]["subagent_calls"], r[0]["subagent_cost"]) if r else print("none")
' "$OUT/sessions.csv" 2>/dev/null)
[ "$ROW" = "1 300.0" ] && ok "all-sidechain subagent records are costed" || bad "all-sidechain subagent records are costed (got: $ROW, want: 1 300.0)"

python3 "$TOOL" >/dev/null 2>&1 && bad "no args is a usage error" || ok "no args is a usage error"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
