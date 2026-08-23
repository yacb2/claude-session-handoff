#!/bin/sh
# Chain ledger for claude-session-handoff.
#
# The brief is re-drafted from scratch at every hop, so anything the outgoing
# session did not happen to re-type is gone. Measured over 21 real links: a
# fact survives one hop 33% of the time, and the mechanism does not distinguish
# what is ALLOWED to expire from what is not — items owed to the user survived
# 17%, the worst of every class. 6 of those 21 links carried no drafted brief
# at all (bare `handoff` seeds the transcript tail, no model in the loop), so
# no amount of drafting discipline can reach them.
#
# This file is the other half: a per-chain, append-only log of the things that
# must NOT decay. An item leaves it only when a CLOSE event closes it, never by
# not being mentioned. Rendering it needs no model, which is what makes the
# tail path work too.
#
# Two subcommands, both used by handoff-session-start.sh:
#
#   apply  <ledger> <delta-file> <n>   append the outgoing session's deltas
#   render <ledger> <n>                print the block to inject, or nothing
#
# Storage is one tab-separated event per line:
#
#   <iso8601>\t<link>\t<verb>\t<id>\t<type>\t<text>
#
# Deltas are written by the model in the outgoing session (SKILL.md Step 2) in
# a deliberately forgiving line syntax:
#
#   CHARTER <what this chain exists to do>
#   OPEN OWED <a decision only the user can make>
#   OPEN RULE <a standing constraint of theirs>
#   CLOSE d1 <how it was settled>
#   TURN <a course correction this session took>
#
# TURN is the one that is not an obligation. It records that the work CHANGED
# direction — an approach abandoned because something else worked better, a
# problem found mid-execution, a decision taken on the fly. It never appears in
# the open list and nothing closes it; it is history, and it renders in a
# bounded trajectory below the open items.
#
# Correcting an earlier item is expressed the same way, without rewriting
# anything: CLOSE it with what actually turned out, and OPEN the corrected one.
# The file is append-only, so the original line and its correction both stay on
# the record, in order, with the link each happened at.
#
# Ids are assigned HERE, never by the model. The model can only reference ids
# it has seen in the rendered block, and at a chain's first link there is no
# block yet — so letting it invent them is how two sessions both write `d1`.

set -u

LEDGER_MAX_ITEMS=24

# How many trajectory entries render per link. Six is two-to-three sessions of
# real turns — enough to see the direction of travel, short enough that a long
# chain does not re-inject its whole history at every hop.
LEDGER_TRAIL=6

# Model-written text joined into a rendered block: one line, no control
# characters, bounded. Same treatment the slug already gets in the sibling hook,
# plus one this text needs and the slug does not.
#
# The block it lands in is delimited by `=== CHAIN LEDGER ===` lines, so an item
# whose text carries that shape closes the block early and everything after it
# reads as instructions to the arriving session rather than as quoted content.
# The sibling hook meets the same problem on the transcript tail and answers it
# by prefixing every quoted line; here the item is a single field on a line the
# renderer owns, so collapsing runs of `=` is the smaller answer and it is
# total — no run of three survives, so no delimiter can be spelled.
sanitize() {
  printf '%s' "$1" \
    | tr -d '\000-\010\013\014\016-\037' \
    | tr '\t' ' ' \
    | sed 's/===*/=/g' \
    | cut -c1-400
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- apply -------------------------------------------------------------------

ledger_apply() {
  _ledger="$1"; _delta="$2"; _n="$3"
  [ -f "$_delta" ] || return 0

  # Ids continue from the highest one the ledger already carries, so a CLOSE
  # written against `d2` keeps meaning the same item forever. Reading the max
  # rather than counting OPENs matters: counting would reuse an id after the
  # file is hand-edited, which is the one thing a durable record must not do.
  _next=1
  if [ -f "$_ledger" ]; then
    _max=$(awk -F'\t' '$3=="OPEN" {sub(/^d/,"",$4); if ($4+0 > m) m=$4+0} END {print m+0}' "$_ledger" 2>/dev/null)
    [ -n "$_max" ] && _next=$((_max + 1))
  fi

  _at=$(now_iso)
  _out=""
  while IFS= read -r _line || [ -n "$_line" ]; do
    _verb=$(printf '%s' "$_line" | awk '{print $1}')
    case "$_verb" in
      CHARTER)
        _text=$(sanitize "$(printf '%s' "$_line" | cut -d' ' -f2-)")
        [ -n "$_text" ] || continue
        _out="${_out}${_at}	${_n}	CHARTER	-	-	${_text}
"
        ;;
      OPEN)
        _type=$(printf '%s' "$_line" | awk '{print $2}')
        case "$_type" in
          OWED|RULE) ;;
          *) continue ;;
        esac
        _text=$(sanitize "$(printf '%s' "$_line" | cut -d' ' -f3-)")
        [ -n "$_text" ] || continue
        _out="${_out}${_at}	${_n}	OPEN	d${_next}	${_type}	${_text}
"
        _next=$((_next + 1))
        ;;
      TURN)
        _text=$(sanitize "$(printf '%s' "$_line" | cut -d' ' -f2-)")
        [ -n "$_text" ] || continue
        _out="${_out}${_at}	${_n}	TURN	-	-	${_text}
"
        ;;
      CLOSE)
        _id=$(printf '%s' "$_line" | awk '{print $2}')
        case "$_id" in
          d[0-9]*) ;;
          *) continue ;;
        esac
        _text=$(sanitize "$(printf '%s' "$_line" | cut -d' ' -f3-)")
        [ -n "$_text" ] || _text="closed"
        _out="${_out}${_at}	${_n}	CLOSE	${_id}	-	${_text}
"
        ;;
      *) continue ;;
    esac
  done < "$_delta"

  [ -n "$_out" ] || return 0
  # `${x%/*}` returns x unchanged when x has no slash, so an unqualified path
  # would have mkdir create a DIRECTORY with the ledger's own name and every
  # append fail afterwards. Only a path with a directory part gets one made.
  case "$_ledger" in
    */*) (umask 077; mkdir -p "${_ledger%/*}") || return 0 ;;
  esac
  (umask 077; printf '%s' "$_out" >> "$_ledger")
}

# --- render ------------------------------------------------------------------

ledger_render() {
  _ledger="$1"; _n="$2"
  [ -f "$_ledger" ] || return 0
  [ -s "$_ledger" ] || return 0

  _body=$(awk -F'\t' -v now="$_n" -v cap="$LEDGER_MAX_ITEMS" -v trail="$LEDGER_TRAIL" '
    { if ($2+0 > lastwrite) lastwrite=$2+0 }
    $3=="CHARTER" { charter=$6; charter_n=$2; next }
    $3=="OPEN"    { type[$4]=$5; text[$4]=$6; born[$4]=$2; if (!($4 in seen)) { order[++k]=$4; seen[$4]=1 } ; next }
    $3=="CLOSE"   { closed[$4]=1; ev[++e]=sprintf("link %s  closed %s — %s", $2, $4, $6); next }
    $3=="TURN"    { ev[++e]=sprintf("link %s  turn — %s", $2, $6); next }
    END {
      if (charter != "") printf "CHARTER (set at link %s): %s\n\n", charter_n, charter
      n=0
      for (i=1; i<=k; i++) {
        id=order[i]
        if (id in closed) continue
        n++
        if (n > cap) { extra++; continue }
        age = now - born[id]
        if (age <= 0) label=sprintf("opened at link %s", born[id])
        else if (age == 1) label=sprintf("opened at link %s, carried 1 link", born[id])
        else label=sprintf("opened at link %s, carried %d links", born[id], age)
        printf "  %-4s %-4s [%s]  %s\n", id, type[id], label, text[id]
      }
      if (extra > 0) printf "  ... and %d more open items, not shown (cap %d). The list is too long: close what is settled.\n", extra, cap
      if (n == 0 && charter == "" && e == 0) exit 1

      # The trajectory. Bounded on purpose: a long chain would otherwise inject
      # its whole history every link, which is the accumulate-everything design
      # this mechanism exists instead of. The full file is named below it, so
      # anything older is one `cat` away rather than lost.
      if (e > 0) {
        printf "\nHOW THIS CHAIN GOT HERE — most recent first, older entries are in the file:\n"
        shown=0
        for (i=e; i>=1 && shown<trail; i--) { printf "  %s\n", ev[i]; shown++ }
        if (e > shown) printf "  ... %d earlier entries, in the ledger file.\n", e - shown
      }

      # Links that passed with nobody writing a delta. The bare-`handoff` path
      # seeds the transcript tail with no model in the loop, so it carries this
      # list forward and updates none of it. Without this line a ledger frozen
      # three links ago reads exactly like one confirmed this link.
      idle = (now - 1) - lastwrite
      if (idle >= 1) printf "\nSTALE: %d link(s) have passed with no delta written — nothing here has been\nreconfirmed or closed since link %s. Re-check before repeating any of it as current.\n", idle, lastwrite
    }
  ' "$_ledger" 2>/dev/null) || return 0

  [ -n "$_body" ] || return 0

  printf '=== CHAIN LEDGER ===\n'
  printf 'Carried by the mechanism across every link of this chain, including the ones\n'
  printf 'seeded without a model. An item leaves this list ONLY when a CLOSE delta\n'
  printf 'closes it — never by not being mentioned, which is exactly how the brief\n'
  printf 'loses things. Treat every line as still standing.\n\n'
  printf '%s\n' "$_body"
  printf '\nFull ledger, for anything older than the trajectory above:\n  %s\n' "$_ledger"
  printf '\nBefore handing off, write the deltas for what changed (SKILL.md Step 2):\n'
  printf 'close what this session settled, open what it discovered, and record a TURN\n'
  printf 'for anything that changed direction. Do not re-type these items into the\n'
  printf 'brief — they are already carried.\n'
  printf '=== END CHAIN LEDGER ===\n'
}

case "${1:-}" in
  apply)  shift; ledger_apply  "${1:-}" "${2:-}" "${3:-1}" ;;
  render) shift; ledger_render "${1:-}" "${2:-1}" ;;
  *) echo "usage: handoff-ledger.sh {apply <ledger> <delta> <n> | render <ledger> <n>}" >&2; exit 2 ;;
esac
