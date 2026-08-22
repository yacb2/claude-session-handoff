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
#
# Ids are assigned HERE, never by the model. The model can only reference ids
# it has seen in the rendered block, and at a chain's first link there is no
# block yet — so letting it invent them is how two sessions both write `d1`.

set -u

LEDGER_MAX_ITEMS=24

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

  _body=$(awk -F'\t' -v now="$_n" -v cap="$LEDGER_MAX_ITEMS" '
    $3=="CHARTER" { charter=$6; charter_n=$2; next }
    $3=="OPEN"    { type[$4]=$5; text[$4]=$6; born[$4]=$2; if (!($4 in seen)) { order[++k]=$4; seen[$4]=1 } ; next }
    $3=="CLOSE"   { closed[$4]=1; next }
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
      if (n == 0 && charter == "") exit 1
    }
  ' "$_ledger" 2>/dev/null) || return 0

  [ -n "$_body" ] || return 0

  printf '=== CHAIN LEDGER ===\n'
  printf 'Carried by the mechanism across every link of this chain, including the ones\n'
  printf 'seeded without a model. An item leaves this list ONLY when a CLOSE delta\n'
  printf 'closes it — never by not being mentioned, which is exactly how the brief\n'
  printf 'loses things. Treat every line as still standing.\n\n'
  printf '%s\n' "$_body"
  printf '\nBefore handing off, write the deltas for what changed (SKILL.md Step 2):\n'
  printf 'close what this session settled, open what it discovered. Do not re-type\n'
  printf 'these items into the brief — they are already carried.\n'
  printf '=== END CHAIN LEDGER ===\n'
}

case "${1:-}" in
  apply)  shift; ledger_apply  "${1:-}" "${2:-}" "${3:-1}" ;;
  render) shift; ledger_render "${1:-}" "${2:-1}" ;;
  *) echo "usage: handoff-ledger.sh {apply <ledger> <delta> <n> | render <ledger> <n>}" >&2; exit 2 ;;
esac
