# Drop-in for an existing Claude Code statusline script (statusline.sh next to this file is the standalone
# version). Needs: FIVE = .rate_limits.five_hour.used_percentage, FIVE_AT = .rate_limits.five_hour.resets_at
# (both may be empty), and OUT = the line being built. Appends " @account" and, at the hop threshold, the hint.
#
# 1. $ACCT = the live account's claude-account name (falls back to the email local-part).
ACCT=$(jq -r '.oauthAccount.emailAddress // empty' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null)
ACCT="${ACCT%%@*}"
ACCT_DIR="${CLAUDE_ACCOUNT_DIR:-$HOME/.claude/accounts}"
if [ -f "$ACCT_DIR/.current" ]; then
  IFS=$'\t' read -r ACCT_NAME ACCT_UUID < "$ACCT_DIR/.current"
  LIVE_UUID=$(jq -r '.oauthAccount.accountUuid // empty' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null)
  [ -n "$ACCT_UUID" ] && [ "$ACCT_UUID" = "$LIVE_UUID" ] && ACCT="$ACCT_NAME"
fi
OUT="$OUT${ACCT:+ @$ACCT}"

# 2. Record the 5h reading; at the hop threshold (default 90%) `quota` writes accounts/.hop and prints
#    the next account. The hint changes with how the session was started.
HOP_NEXT=""
if [ -n "${FIVE:-}" ] && command -v claude-account >/dev/null 2>&1; then
  HOP_NEXT=$(claude-account quota "$FIVE" "${FIVE_AT:-0}" 2>/dev/null)
fi
if [ -n "$HOP_NEXT" ]; then
  if [ "${CLAUDE_AS_LOOP:-}" = 1 ] && [ "${CLAUDE_ACCOUNT_AUTOHOP:-}" = 1 ]; then
    OUT="$OUT -> auto hop to $HOP_NEXT after this turn"
  elif [ "${CLAUDE_AS_LOOP:-}" = 1 ]; then
    OUT="$OUT -> /exit hops to $HOP_NEXT"
  else
    OUT="$OUT -> /exit; claude-as $HOP_NEXT --continue"
  fi
fi
