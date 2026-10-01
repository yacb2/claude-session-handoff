#!/bin/sh
# Re-attach to the newest abduco Claude session of a directory and force a repaint:
# abduco keeps no screen, and re-attaching at the same size sends no SIGWINCH; Node only
# redraws when the size really changes, so shrink the pty one row and restore it.
# -f: only sessions nobody is attached to; exits 3, silently, when there is none (zshrc hook).
free=; [ "$1" = -f ] && { free=1; shift; }
d=${1:-$(basename "$PWD")}
# -f: terminals a GUI reopens together would all pick the same free session before any
# shows as attached. Pick under a lock held until abduco lists the pick as attached (5 s
# at most, so a stale lock never blocks a shell for good).
lock="$HOME/.claude/tmp/claude-attach.lock"
if [ -n "$free" ]; then
  i=0; until mkdir "$lock" 2>/dev/null || [ $i -ge 50 ]; do i=$((i + 1)); sleep 0.1; done
fi
n=$(abduco | awk -v p="claude-$d-" -v f="$free" 'index($NF, p) == 1 && !(f && $1 == "*") { n = $NF } END { print n }')
[ -n "$n" ] || { [ -n "$free" ] && { rmdir "$lock" 2>/dev/null; exit 3; }; echo "no abduco session for $d" >&2; exit 1; }
[ -n "$free" ] && (
  i=0
  until abduco | awk -v n="$n" '$NF == n && $1 == "*" { f = 1 } END { exit !f }' || [ $i -ge 50 ]; do
    i=$((i + 1)); sleep 0.1
  done
  rmdir "$lock" 2>/dev/null
) &
srv=$(pgrep -f "abduco -[cn] $n" | head -1)
(
  sleep 0.5
  for c in $(pgrep -P "$srv"); do
    for g in $(pgrep -P "$c"); do
      t=$(ps -o tty= -p "$g" | tr -d ' ')
      case $t in tty*) ;; *) continue ;; esac
      set -- $(stty -f "/dev/$t" size)
      stty -f "/dev/$t" rows $(($1 - 1)) cols "$2"; sleep 0.3
      stty -f "/dev/$t" rows "$1" cols "$2"
      exit
    done
  done
) &
exec abduco -a "$n"
