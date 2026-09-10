#!/usr/bin/env bash
# Standalone statusline for Claude Code: model · @account · ctx % · 5h % (reset time) · hop hint.
# Wire it in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "bash ~/.local/bin/claude-account-statusline" }
# Already have a statusline script? Source statusline-snippet.sh from it instead (see README).
INPUT=$(cat)
IFS=$'\t' read -r MODEL CTX FIVE FIVE_AT <<<"$(printf '%s' "$INPUT" | jq -r '[
  (.model.display_name // "Claude"),
  ((.context_window.used_percentage // "-") | tostring | split(".")[0]),
  ((.rate_limits.five_hour.used_percentage // "-") | tostring | split(".")[0]),
  (.rate_limits.five_hour.resets_at // "-")
] | join("\t")' 2>/dev/null)"

OUT="$MODEL"
if [ -n "${CTX:-}" ] && [ "$CTX" != "-" ]; then OUT="$OUT | ctx ${CTX}%"; fi
if [ -n "${FIVE:-}" ] && [ "$FIVE" != "-" ]; then
  AT=""; [ "$FIVE_AT" != "-" ] && [ "$FIVE_AT" -gt 0 ] 2>/dev/null && AT=$(date -r "$FIVE_AT" +%H:%M 2>/dev/null || date -d "@$FIVE_AT" +%H:%M 2>/dev/null || true)
  OUT="$OUT | 5h ${FIVE}%${AT:+ ->$AT}"
else
  FIVE=""
fi
case "${FIVE_AT:-}" in -|0) FIVE_AT="" ;; esac

# shellcheck source=statusline-snippet.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statusline-snippet.sh"
printf '%s' "$OUT"
