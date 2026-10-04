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
#   retro      links whose deltas were RECOVERED by a successor reading the
#              transcript, rather than written by the link itself
#   notes      links that recorded ONLY a hook-written pointer, i.e. ended
#              model-free and had nothing else said about them
#
# `wrote` and `retro` are the two halves the automation question turns on, and
# folding them together would destroy the number. The retro exists precisely to
# take the dying session off the write path, so once it ships every link it
# recovers would count as a session write and the rate would climb toward 100%
# by construction — the same defect as counting the pointers, one layer up, and
# this time it would look like the outcome everyone was hoping for.
#
# `wrote` counts links a SESSION wrote for, so a NOTE never counts toward it.
# That distinction is the whole point of the number: a hook pointer is emitted
# unconditionally on the bare-`handoff` paths, so counting it would drive this
# rate toward 100% by construction — and this rate is what the decision to
# automate the trigger is pinned to. It would have been the readout reporting
# its own instrumentation as the result.
#
# A chain with no ledger file reports wrote=0 — a real zero, not missing data,
# and the failure mode this exists to make visible. With one exception that has
# to be carved out or the number is wrong forever: a chain whose last link ran
# BEFORE the mechanism was installed never had a ledger to write to. Those are
# marked `pre` and excluded from the total. The cutoff is the ledger's first
# commit, fixed: it used to be the installed script's mtime, which every
# reinstall moved forward (`install.sh` copies without `-p`), and it had marked
# 92 chains `pre` that do have ledgers.
set -u

STORE="${HOME}/.claude/handoff-chains"
[ -d "$STORE" ] || { echo "no chain store at $STORE"; exit 0; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

# First commit of scripts/handoff-ledger.sh (88931e3), in UTC.
LEDGER_SINCE="2026-08-22T20:29:15Z"

TOT_H=0; TOT_W=0; TOT_T=0; TOT_C=0; TOT_PRE=0; TOT_N=0; TOT_R=0

# ledger_counts <ledger> <handoffs> -> "wrote retros turns notes" (all 0 when
# absent). Rows past the last handoff are skipped: the last link is not in the
# denominator, so counting its rows let wrote exceed handoffs.
#   wrote : links with a session-written entry
#   retros: links whose ONLY entries are recovered — where both exist the
#           session wrote, and the retro merely added
#   notes : links whose ONLY event is a pointer; reported rather than merely
#           excluded, since a link that ended model-free would otherwise read
#           exactly like a link nothing was ever recorded for
ledger_counts() {
  [ -f "$1" ] || { printf '0 0 0 0'; return; }
  awk -F'\t' -v h="$2" '
    $2+0 > h+0 { next }
    $3!="NOTE" && $7!="retro" { w[$2]=1 }
    $3!="NOTE" && $7=="retro" { r[$2]=1 }
    $3=="NOTE" { n[$2]=1 }
    $3=="TURN" { t++ }
    END {
      wc=0; for (k in w) wc++
      rc=0; for (k in r) if (!(k in w)) rc++
      nc=0; for (k in n) if (!(k in w) && !(k in r)) nc++
      printf "%d %d %d %d", wc, rc, t+0, nc
    }' "$1" 2>/dev/null
}
chain_last() { jq -r --arg c "$2" 'select(.chain == $c) | .at' "$1" 2>/dev/null | sort | tail -1; }

# --owed [project]: the open OWED items of chains whose last link is 7+ days
# old, one tab-separated line each (project, chain, link, id, text). A chain
# nobody continues injects them into no session, so this is where they surface.
# Open means what render means: no CLOSE row for the id. [project] is a
# substring of the store's path-derived file name.
if [ "${1:-}" = "--owed" ]; then
  IDLE_SINCE=$(jq -rn 'now - 604800 | todate')
  for F in "$STORE"/*.jsonl; do
    [ -f "$F" ] || continue
    PROJ=$(basename "$F" .jsonl)
    case "$PROJ" in *"${2:-}"*) ;; *) continue ;; esac
    for CHAIN in $(jq -r '.chain' "$F" 2>/dev/null | sort -u); do
      L="$STORE/$PROJ.$CHAIN.ledger"
      [ -f "$L" ] || continue
      LAST=$(chain_last "$F" "$CHAIN")
      [ -n "$LAST" ] && [ "$LAST" \< "$IDLE_SINCE" ] || continue
      awk -F'\t' -v p="$PROJ" -v c="$CHAIN" '
        $3=="CLOSE" { closed[$4]=1 }
        $3=="OPEN" && $5=="OWED" && !($4 in link) { o[++k]=$4; link[$4]=$2; text[$4]=$6 }
        END { for (i=1; i<=k; i++) if (!(o[i] in closed)) printf "%s\t%s\t%s\t%s\t%s\n", p, c, link[o[i]], o[i], text[o[i]] }' "$L"
    done
  done
  exit 0
fi

printf '%-34s %6s %9s %6s %6s %6s %6s\n' 'chain' 'links' 'handoffs' 'wrote' 'retro' 'turns' 'notes'
printf '%-34s %6s %9s %6s %6s %6s %6s\n' '----------------------------------' '------' '---------' '------' '------' '------' '------'

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
    set -- $(ledger_counts "$LEDGER" "$HANDOFFS"); WROTE=$1; RETROS=$2; TURNS=$3; NOTES=$4
    LAST=$(chain_last "$F" "$CHAIN")
    MARK=""
    if [ -n "$LAST" ] && [ "$LAST" \< "$LEDGER_SINCE" ]; then MARK=" pre"; fi
    printf '%-34s %6s %9s %6s %6s %6s %6s%s\n' "$(printf '%s' "$PROJ" | tail -c 18).$(printf '%s' "$CHAIN" | cut -c1-6)" \
      "$LINKS" "$HANDOFFS" "$WROTE" "$RETROS" "$TURNS" "$NOTES" "$MARK"
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
    LAST=$(chain_last "$F" "$CHAIN")
    if [ -n "$LAST" ] && [ "$LAST" \< "$LEDGER_SINCE" ]; then
      TOT_PRE=$((TOT_PRE + 1)); continue
    fi
    set -- $(ledger_counts "$L" "$H"); W=$1; R=$2; T=$3; NT=$4
    TOT_H=$((TOT_H + H)); TOT_W=$((TOT_W + W)); TOT_T=$((TOT_T + T)); TOT_C=$((TOT_C + 1))
    TOT_N=$((TOT_N + NT)); TOT_R=$((TOT_R + R))
  done
done

if [ "$TOT_H" -gt 0 ]; then
  printf 'TOTAL: %s chains, %s handoffs, %s wrote deltas (%s%%), %s recovered by retro, %s turns, %s links model-free\n' \
    "$TOT_C" "$TOT_H" "$TOT_W" "$(( TOT_W * 100 / TOT_H ))" "$TOT_R" "$TOT_T" "$TOT_N"
  echo
  echo 'The rate is the write side, and it counts SESSION writes only. Automating the'
  echo 'trigger is only defensible once it is high enough that a handoff fired at an'
  echo 'arbitrary moment still records what the next session needs. Baseline before'
  echo 'the ledger: not measurable.'
  echo
  echo 'The `retro` column is a different regime, not more of the same number: those'
  echo 'links were recovered afterwards by a successor reading the transcript. Do not'
  echo 'add the two columns and do not compare a total spanning the retro to one from'
  echo 'before it — compare like windows.'
else
  printf 'Nothing to read out yet: %s chain(s) predate the mechanism and no chain has\n' "$TOT_PRE"
  echo 'reached a second link since it was installed. Run this again after a few handoffs.'
fi
[ "$TOT_PRE" -gt 0 ] && [ "$TOT_H" -gt 0 ] && printf '(%s chain(s) marked `pre` were excluded: they ran before the mechanism existed.)\n' "$TOT_PRE"
exit 0
