#!/bin/sh
# What fraction of handoffs actually wrote ledger deltas?
#
# This is the number the whole automation question turns on, and it is the one
# thing no test can produce: the tests prove the mechanism carries what it is
# given, not that a live session gives it anything useful. Measured over 21 real
# links before the ledger existed, obligations that WERE declared survived one
# hop 17% of the time; what nobody has measured is how often they get declared.
#
# Read-only. Reports per chain and in total:
#
#   links      the chain's length
#   handoffs   links that could have written deltas (every link but the last)
#   wrote      how many of those actually did
#   turns      course corrections recorded, which is the half that is easy to skip
#
# A chain with no ledger file reports wrote=0 — a real zero, not missing data,
# and the failure mode this exists to make visible. With one exception that has
# to be carved out or the number is wrong forever: a chain whose last link ran
# BEFORE the mechanism was installed never had a ledger to write to. Those are
# marked `pre` and excluded from the total. The install moment is read off the
# mtime of the installed script rather than hardcoded, so this keeps working
# after a reinstall instead of silently re-including old chains.
set -u

STORE="${HOME}/.claude/handoff-chains"
[ -d "$STORE" ] || { echo "no chain store at $STORE"; exit 0; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

INSTALLED_AT=""
for C in "${HOME}/.claude/scripts/handoff-ledger.sh" "${CLAUDE_DIR:-}/scripts/handoff-ledger.sh"; do
  [ -f "$C" ] || continue
  INSTALLED_AT=$(date -u -r "$C" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) && break
done

TOT_H=0; TOT_W=0; TOT_T=0; TOT_C=0; TOT_PRE=0

printf '%-34s %6s %9s %6s %6s\n' 'chain' 'links' 'handoffs' 'wrote' 'turns'
printf '%-34s %6s %9s %6s %6s\n' '----------------------------------' '------' '---------' '------' '------'

for F in "$STORE"/*.jsonl; do
  [ -f "$F" ] || continue
  PROJ=$(basename "$F" .jsonl)
  # Longest recorded ordinal per chain id.
  jq -r '"\(.chain)\t\(.n)"' "$F" 2>/dev/null | sort -u | awk -F'\t' '
    { if ($2+0 > m[$1]) m[$1]=$2+0 } END { for (c in m) print c "\t" m[c] }' |
  while IFS="$(printf '\t')" read -r CHAIN LINKS; do
    [ -n "$CHAIN" ] || continue
    LEDGER="$STORE/$PROJ.$CHAIN.ledger"
    HANDOFFS=$((LINKS - 1))
    [ "$HANDOFFS" -ge 1 ] || continue
    if [ -f "$LEDGER" ]; then
      WROTE=$(awk -F'\t' '{print $2}' "$LEDGER" 2>/dev/null | sort -u | wc -l | tr -d ' ')
      TURNS=$(awk -F'\t' '$3=="TURN"' "$LEDGER" 2>/dev/null | wc -l | tr -d ' ')
    else
      WROTE=0; TURNS=0
    fi
    LAST=$(jq -r --arg c "$CHAIN" 'select(.chain == $c) | .at' "$F" 2>/dev/null | sort | tail -1)
    MARK=""
    if [ -n "$INSTALLED_AT" ] && [ -n "$LAST" ] && [ "$LAST" \< "$INSTALLED_AT" ]; then MARK=" pre"; fi
    printf '%-34s %6s %9s %6s %6s%s\n' "$(printf '%s' "$PROJ" | tail -c 18).$(printf '%s' "$CHAIN" | cut -c1-6)" \
      "$LINKS" "$HANDOFFS" "$WROTE" "$TURNS" "$MARK"
    # Subshell: the pipeline above means these cannot escape, so the totals are
    # recomputed below rather than carried out of here. Saying so beats a total
    # that is silently always zero.
  done
done

echo
# Recomputed outside the pipeline, for the same reason named above.
for F in "$STORE"/*.jsonl; do
  [ -f "$F" ] || continue
  PROJ=$(basename "$F" .jsonl)
  for CHAIN in $(jq -r '.chain' "$F" 2>/dev/null | sort -u); do
    LINKS=$(jq -r --arg c "$CHAIN" 'select(.chain == $c) | .n' "$F" 2>/dev/null | sort -n | tail -1)
    [ -n "$LINKS" ] || continue
    H=$((LINKS - 1)); [ "$H" -ge 1 ] || continue
    L="$STORE/$PROJ.$CHAIN.ledger"
    LAST=$(jq -r --arg c "$CHAIN" 'select(.chain == $c) | .at' "$F" 2>/dev/null | sort | tail -1)
    if [ -n "$INSTALLED_AT" ] && [ -n "$LAST" ] && [ "$LAST" \< "$INSTALLED_AT" ]; then
      TOT_PRE=$((TOT_PRE + 1)); continue
    fi
    if [ -f "$L" ]; then
      W=$(awk -F'\t' '{print $2}' "$L" | sort -u | wc -l | tr -d ' ')
      T=$(awk -F'\t' '$3=="TURN"' "$L" | wc -l | tr -d ' ')
    else W=0; T=0; fi
    TOT_H=$((TOT_H + H)); TOT_W=$((TOT_W + W)); TOT_T=$((TOT_T + T)); TOT_C=$((TOT_C + 1))
  done
done

if [ "$TOT_H" -gt 0 ]; then
  printf 'TOTAL: %s chains, %s handoffs, %s wrote deltas (%s%%), %s turns recorded\n' \
    "$TOT_C" "$TOT_H" "$TOT_W" "$(( TOT_W * 100 / TOT_H ))" "$TOT_T"
  echo
  echo 'The rate is the write side. Automating the trigger is only defensible once'
  echo 'it is high enough that a handoff fired at an arbitrary moment still records'
  echo 'what the next session needs. Baseline before the ledger: not measurable.'
else
  printf 'Nothing to read out yet: %s chain(s) predate the mechanism and no chain has\n' "$TOT_PRE"
  echo 'reached a second link since it was installed. Run this again after a few handoffs.'
fi
[ "$TOT_PRE" -gt 0 ] && [ "$TOT_H" -gt 0 ] && printf '(%s chain(s) marked `pre` were excluded: they ran before the mechanism existed.)\n' "$TOT_PRE"
exit 0
