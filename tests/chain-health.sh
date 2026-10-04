#!/bin/sh
# scripts/chain-health.sh: one fixture per signal, in an isolated HOME. Each
# case plants the defect and its near-miss (the shape that must NOT be counted),
# because a readout that over-counts is as wrong as one that misses.
# Layer: shell script suite, the repo's only layer; the readout is the contract.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/scripts/chain-health.sh"
PASS=0; FAIL=0
H=$(mktemp -d); trap 'rm -rf "$H"' EXIT
S="$H/.claude/handoff-chains"; T="$H/.claude/tmp"; P="$H/.claude/projects/-p"
mkdir -p "$S" "$T" "$P"

rec() { printf '{"chain":"%s","n":%s,"slug":"x","session":"%s","prev":"%s","wrapper":"1","at":"2026-10-01T00:00:00Z"%s}\n' "$1" "$2" "$3" "$4" "${5:-}"; }
{
  rec c1aaaaaa 1 c1aaaaaa ""                          # unmarked first link: split
  rec c2bbbbbb 1 c2bbbbbb "" ',"clean":true'          # deliberate clean start: not a split
  rec c1aaaaaa 2 s2cccccc c1aaaaaa                    # prev is a cli session
  rec c1aaaaaa 3 s3dddddd s2cccccc                    # prev is an sdk-cli session
  rec c1aaaaaa 4 s4eeeeee s3dddddd                    # prev is s3 (sdk)
  rec c1aaaaaa 5 s5gggggg s4eeeeee                    # prev transcript missing
} > "$S/-proj-a.jsonl"
rec o1ffffff 1 o1ffffff "" ',"clean":true' > "$S/-proj-b.jsonl"
rec o2ffffff 1 o2ffffff "" ',"new_chain":true' >> "$S/-proj-b.jsonl"     # deliberate --new: not a split
printf '{"entrypoint":"cli"}\n' > "$P/c1aaaaaa.jsonl"
printf '{"entrypoint":"cli"}\n' > "$P/s2cccccc.jsonl"
printf '{"type":"x"}\n{"entrypoint":"sdk-cli"}\n' > "$P/s3dddddd.jsonl"

OLD=202601010000
echo 1 > "$T/handoff-idle-arm-old11111"; touch -t $OLD "$T/handoff-idle-arm-old11111"   # armed, never woken
echo 1 > "$T/handoff-idle-arm-old22222"; touch -t $OLD "$T/handoff-idle-arm-old22222"   # woken
echo 1 > "$T/handoff-idle-woke-old22222"
echo 1 > "$T/handoff-idle-arm-new33333"                                                # 30 min: too young to judge
perl -e 'utime time-1800, time-1800, $ARGV[0]' "$T/handoff-idle-arm-new33333"
echo x > "$T/handoff-payload-9001"; touch -t $OLD "$T/handoff-payload-9001"            # nobody consumed it
echo x > "$T/handoff-title-9002"                                                       # in flight

OUT=$(HOME="$H" sh "$SCRIPT")
OUTB=$(HOME="$H" sh "$SCRIPT" proj-b)

check() { # <name> <pattern> <text>
  if printf '%s\n' "$3" | grep -Eq "$2"; then PASS=$((PASS+1)); echo "PASS $1"
  else FAIL=$((FAIL+1)); echo "FAIL $1"; printf '%s\n' "$3" | sed 's/^/   | /'; fi
}
block() { printf '%s\n' "$OUT" | awk -v p="$1" '$0==p{f=1;next} /^$/{f=0} /^-/{f=0} f'; }
check "records counted"            'records +6 +\(2 chains\)'           "$(block -proj-a)"
check "only the unmarked n=1 is a split" 'splits.* 1 +e.g. c1aaaaaa'      "$(block -proj-a)"
check "sdk prev counted once"      'sdk-cli prevs +1 +e.g. s3dddddd'    "$(block -proj-a)"
check "missing transcript is unknown, not clean" 'prevs unknown +1'     "$(block -proj-a)"
check "clean-only project has no split" 'splits.* 0$'                   "$(block -proj-b)"
check "armed-never-woken: old arm only" 'idle armed, not woken +1 +e.g. old11111' "$OUT"
check "stale handoff files: old payload only" 'stale handoff files +1 +e.g. 9001' "$OUT"
check "project filter keeps proj-b" 'proj-b' "$OUTB"
if printf '%s\n' "$OUTB" | grep -q 'proj-a'; then FAIL=$((FAIL+1)); echo "FAIL filter leaks proj-a"; else PASS=$((PASS+1)); echo "PASS filter excludes proj-a"; fi

echo "chain-health: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
