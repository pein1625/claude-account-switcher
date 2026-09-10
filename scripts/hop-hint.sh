#!/usr/bin/env bash
# UserPromptSubmit hook. While accounts/.hop exists, add one line of context so Claude tells the
# user how the hop will happen. Silent otherwise.
dir="${CLAUDE_ACCOUNT_DIR:-$HOME/.claude/accounts}"
[ -s "$dir/.hop" ] || exit 0
next=$(cat "$dir/.hop")
if [ "${CLAUDE_AS_LOOP:-}" = 1 ] && [ "${CLAUDE_ACCOUNT_AUTOHOP:-}" = 1 ]; then
  printf 'claude-account: the 5h quota of the current account crossed the hop threshold. At the end of this turn the session restarts as account "%s" and resumes this conversation (--continue). Finish your reply with one short line saying so.\n' "$next"
elif [ "${CLAUDE_AS_LOOP:-}" = 1 ]; then
  printf 'claude-account: the 5h quota of the current account crossed the hop threshold. Finish your reply with one short line telling the user: type /exit - claude-as switches to "%s" and resumes this conversation automatically.\n' "$next"
else
  printf 'claude-account: the 5h quota of the current account crossed the hop threshold. Finish your reply with one short line telling the user: /exit, then run: claude-as %s --continue\n' "$next"
fi
