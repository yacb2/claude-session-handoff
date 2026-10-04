#!/bin/sh
# On-demand, read-only chain-health readout. Not installed by install.sh and not
# run per CLI bump; measure-chain-cost.py is the other, separate instrument.
#
# Defects of this family (BL-031-style splits, sdk-cli prevs, an idle hook that
# never woke) were invisible until mined by hand. Usage: chain-health.sh [project]
# where [project] is a substring of the store's path-derived file name, as in
# `ledger-readout.sh --owed`. Honours HOME, like ledger-readout.sh.
#
# Per project:
#   records   chain records, and distinct chains
#   splits    n=1 records that are neither `clean` nor `new_chain` (handoff --new:).
#             A skill-driven handoff always has
#             a predecessor and a clean one is marked, so an unmarked first link
#             means the lineage failed to attach: the marker was missing or the
#             chain restarted (BL-031). A heuristic: it cannot see a deliberate
#             restart made by other means, and it counts every such record ever
#             written, including those before the BL-031 fix.
#   sdk prevs records whose `prev` session's transcript says entrypoint sdk*
#             (a headless `claude -p` that overwrote the marker, BL-036).
#             Prevs with no transcript on disk are counted as unknown, not clean.
# Global (the files carry no project):
#   idle arm  arm files older than IDLE_S+POLL_S (3300 s) with no woke file for
#             the same session: the hook armed and never woke it. Younger arms
#             may still be waiting, so they are not counted.
#   stale handoff files  handoff-payload-/handoff-title- files older than 60 min.
#             The session-start hook deletes them on consumption, so a lingering
#             one is a handoff attempt that no successor consumed (and so no
#             record). Cannot say whether it was cancelled or failed.
# Left out: attempts that never wrote any file, and retro-with-session rows
# (needs ledger semantics this readout does not own).
set -u

STORE="${HOME}/.claude/handoff-chains"
TMPD="${HOME}/.claude/tmp"
PROJECTS="${HOME}/.claude/projects"
[ -d "$STORE" ] || { echo "no chain store at $STORE"; exit 0; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
FILTER="${1:-}"

# show <label> <count> <ids...>: one line, the first three ids.
show() {
  _l=$1; _c=$2; shift 2
  _ids=$(printf '%s\n' "$@" | grep . | head -3 | cut -c1-8 | tr '\n' ' ')
  printf '  %-22s %4s' "$_l" "$_c"
  [ -n "$_ids" ] && printf '   e.g. %s' "$_ids"
  printf '\n'
}

transcript_of() {
  for _t in "$PROJECTS"/*/"$1".jsonl; do
    [ -f "$_t" ] && { printf '%s' "$_t"; return 0; }
  done
  return 1
}

for F in "$STORE"/*.jsonl; do
  [ -f "$F" ] || continue
  PROJ=$(basename "$F" .jsonl)
  case "$PROJ" in *"$FILTER"*) ;; *) continue ;; esac
  echo "$PROJ"
  RECS=$(jq -s 'length' "$F" 2>/dev/null)
  CHAINS=$(jq -r '.chain' "$F" 2>/dev/null | sort -u | grep -c .)
  printf '  %-22s %4s   (%s chains)\n' 'records' "${RECS:-0}" "$CHAINS"

  SPLITS=$(jq -r 'select(.n == 1 and (.clean | not) and (.new_chain | not)) | .session' "$F" 2>/dev/null)
  show 'splits (n=1, not clean)' "$(printf '%s\n' "$SPLITS" | grep -c .)" $SPLITS

  SDK=""; UNK=0
  for P in $(jq -r '.prev // empty' "$F" 2>/dev/null | sort -u); do
    T=$(transcript_of "$P") || { UNK=$((UNK + 1)); continue; }
    E=$(head -40 "$T" | jq -r '.entrypoint // empty' 2>/dev/null | head -1)
    case "$E" in sdk*) SDK="$SDK $P" ;; esac
  done
  show 'sdk-cli prevs' "$(printf '%s\n' $SDK | grep -c .)" $SDK
  printf '  %-22s %4s   (prev transcript not on disk)\n' 'prevs unknown' "$UNK"
done

echo
echo 'all projects'
ARMS=""
for A in "$TMPD"/handoff-idle-arm-*; do
  [ -f "$A" ] || continue
  [ -n "$(find "$A" -mmin +55 2>/dev/null)" ] || continue
  S=${A##*/handoff-idle-arm-}
  [ -f "$TMPD/handoff-idle-woke-$S" ] || ARMS="$ARMS $S"
done
show 'idle armed, not woken' "$(printf '%s\n' $ARMS | grep -c .)" $ARMS

STALE=$(find "$TMPD" -maxdepth 1 \( -name 'handoff-payload-*' -o -name 'handoff-title-*' \) -mmin +60 2>/dev/null)
show 'stale handoff files' "$(printf '%s\n' "$STALE" | grep -c .)" $(printf '%s\n' "$STALE" | sed 's/.*handoff-[a-z]*-//')
exit 0
