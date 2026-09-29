#!/usr/bin/env bash
# Stop / StopFailure(rate_limit) hook.
#  - Stop: acts only when the statusline already flagged a hop (accounts/.hop).
#  - StopFailure rate_limit: the live account just hit its limit; flag the hop here (next account,
#    live account recorded as 100%) so /exit or the auto-hop can proceed even if the statusline
#    never got to render the crossing.
# Then, only inside `claude-as` (CLAUDE_AS_LOOP=1) with CLAUDE_ACCOUNT_AUTOHOP=1, end the claude
# process at this turn boundary; the claude-as loop switches account and relaunches --continue.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="${CLAUDE_ACCOUNT_DIR:-$HOME/.claude/accounts}"

input=$(cat 2>/dev/null || true)
if printf '%s' "$input" | jq -e '.agent_id // empty' >/dev/null 2>&1; then exit 0; fi
# Claude Switcher.app running (heartbeat < 120 s): its own Stop hook decides which session restarts where
alive="$dir/.switcher/alive"
if [ -f "$alive" ]; then
  m=$(stat -f %m "$alive" 2>/dev/null || stat -c %Y "$alive" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - m )) -lt 120 ] && exit 0
fi
event=$(printf '%s' "$input" | jq -r '.hook_event_name // "Stop"' 2>/dev/null || echo Stop)

if [ "$event" = StopFailure ]; then
  cur=$(bash "$HERE/claude-account.sh" current 2>/dev/null | cut -f1 || true)
  now=$(date +%s); resets=$((now + 18000))
  if [ -n "$cur" ] && [ -f "$dir/$cur.quota" ]; then
    IFS=$'\t' read -r _ prev _ < "$dir/$cur.quota"
    [ "${prev:-0}" -gt "$now" ] 2>/dev/null && resets="$prev"
  fi
  bash "$HERE/claude-account.sh" quota 100 "$resets" >/dev/null 2>&1 || true
fi
[ -s "$dir/.hop" ] || exit 0

[ "${CLAUDE_AS_LOOP:-}" = 1 ] || exit 0
[ "${CLAUDE_ACCOUNT_AUTOHOP:-}" = 1 ] || exit 0

# Ancestor chain of this hook process (child of the claude process, via sh -c).
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

printf '%s\t%s\thop=%s\tpid=%s\tvia=%s\t%s\n' "$(date +%FT%T)" "$event" "$(cat "$dir/.hop")" "$pid" \
  "$([ "$pid" = "${CLAUDE_PID:-}" ] && echo env || echo walk)" "$cmd" >> "$dir/.autohop.log"
[ -n "${CLAUDE_ACCOUNT_AUTOHOP_DRY_RUN:-}" ] && exit 0
kill -TERM "$pid"
