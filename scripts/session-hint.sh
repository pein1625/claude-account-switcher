#!/usr/bin/env bash
# SessionStart hook: one-line hint until the CLI shim exists, silent afterwards.
command -v claude-account >/dev/null 2>&1 && exit 0
[ -x "$HOME/.local/bin/claude-account" ] && exit 0
printf 'claude-account plugin: CLI not linked on this device yet. Run /claude-account:claude-account install (once).\n'
