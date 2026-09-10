#!/usr/bin/env bash
# Stop hook. When the statusline flagged a hop (accounts/.hop) and this session runs inside
# `claude-as` with CLAUDE_ACCOUNT_AUTOHOP=1, end the claude process at the turn boundary;
# the claude-as loop then switches account and relaunches with --continue.
[ "${CLAUDE_AS_LOOP:-}" = 1 ] || exit 0
[ "${CLAUDE_ACCOUNT_AUTOHOP:-}" = 1 ] || exit 0
dir="${CLAUDE_ACCOUNT_DIR:-$HOME/.claude/accounts}"
[ -s "$dir/.hop" ] || exit 0

input=$(cat 2>/dev/null || true)
if printf '%s' "$input" | jq -e '.agent_id // empty' >/dev/null 2>&1; then exit 0; fi

# Collect the ancestor chain of this hook process (child of the claude process, via sh -c).
chain=""; p=$PPID
while [ "${p:-0}" -gt 1 ]; do
  chain="$chain $p"
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done

# Target: CLAUDE_PID (exported by Claude Code to its children) when it is one of our ancestors;
# otherwise the nearest ancestor whose command line is claude itself. Never anything else.
pid=""
case " $chain " in *" ${CLAUDE_PID:-x} "*) pid="$CLAUDE_PID" ;; esac
if [ -z "$pid" ]; then
  for p in $chain; do
    cmd=$(ps -o command= -p "$p" 2>/dev/null) || continue
    case "$cmd" in
      *autohop-stop.sh*) ;;
      *claude*) pid="$p"; break ;;
    esac
  done
fi
[ -n "$pid" ] || exit 0
cmd=$(ps -o command= -p "$pid" 2>/dev/null) || exit 0

printf '%s\thop=%s\tpid=%s\tvia=%s\t%s\n' "$(date +%FT%T)" "$(cat "$dir/.hop")" "$pid" "$([ "$pid" = "${CLAUDE_PID:-}" ] && echo env || echo walk)" "$cmd" >> "$dir/.autohop.log"
[ -n "${CLAUDE_ACCOUNT_AUTOHOP_DRY_RUN:-}" ] && exit 0
kill -TERM "$pid"
