# Drop-in for a Claude Code statusline script: sets $ACCT to the live account's
# claude-account name (when the snapshot marker matches) or the email local-part.
ACCT=$(jq -r '.oauthAccount.emailAddress // empty' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null)
ACCT="${ACCT%%@*}"
ACCT_MARKER="${CLAUDE_ACCOUNT_DIR:-$HOME/.claude/accounts}/.current"
if [ -f "$ACCT_MARKER" ]; then
  IFS=$'\t' read -r ACCT_NAME ACCT_UUID < "$ACCT_MARKER"
  LIVE_UUID=$(jq -r '.oauthAccount.accountUuid // empty' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null)
  [ -n "$ACCT_UUID" ] && [ "$ACCT_UUID" = "$LIVE_UUID" ] && ACCT="$ACCT_NAME"
fi
# Then append to your output line, e.g.:  OUT="$OUT${ACCT:+ @$ACCT}"

# Optional: when the 5-hour quota is (almost) gone, point at the next saved account.
# FIVE = .rate_limits.five_hour.used_percentage from the statusline JSON input.
if [ -n "${FIVE:-}" ] && [ "$FIVE" -ge 95 ] 2>/dev/null; then
  NEXT=$(for f in "${CLAUDE_ACCOUNT_DIR:-$HOME/.claude/accounts}"/*.json; do
    case "$f" in *.credentials.json) continue ;; esac
    [ -f "$f" ] || continue
    n=$(basename "$f" .json); [ "$n" != "$ACCT" ] && { printf '%s' "$n"; break; }
  done)
  OUT="$OUT  5h quota gone -> /exit; claude-as ${NEXT:-<account>} --continue"
fi
