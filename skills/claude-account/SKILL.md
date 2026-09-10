---
name: claude-account
description: Manage saved Claude Code subscription accounts from inside a session - list them, see who is logged in, snapshot the current login, run the one-time CLI install, or get the exact command to hop to another account when the 5-hour quota is gone. Trigger on "/claude-account", "switch account", "đổi account", "account nào đang login", "hết quota", "claude-as".
argument-hint: "[install | list | current | next | save <name> | use <name> | login <name> | doctor]"
allowed-tools:
  - Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/claude-account.sh" *)
  - Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" *)
  - AskUserQuestion
---

# claude-account

The tool is `${CLAUDE_PLUGIN_ROOT}/scripts/claude-account.sh`. Run every subcommand as

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/claude-account.sh" <subcommand> [args]
```

It never prints tokens. Show its output to the user verbatim, then stop; no summary needed.

## Dispatch on `$ARGUMENTS`

| Argument | Do |
|---|---|
| (none) | run `current`, then `list`. If 2 or more accounts are saved, end with the hop block below. |
| `install` | run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh"`. Then tell the user to `source ~/.zshrc` (or open a new terminal tab) so `claude-as` exists, and repeat the script's statusline line: without a statusline the quota hop never arms. Once per device. |
| `list`, `current`, `names`, `doctor`, `next` | run it. `list` shows each account's last recorded 5h usage; `next` names the account a hop would go to. |
| `save [name]` | run it. Snapshots the live login; safe while this session is running. |
| `rename <old> <new>` | run it. |
| `remove <name>` | ask first with AskUserQuestion (it deletes that account's Keychain item; getting it back means logging in again), then run it. |
| `use <name>` | do NOT run it. Run `names` to confirm `<name>` exists, then print the hop block. |
| `login <name> [--email x]` | do NOT run it (opens a browser, needs a real terminal). Print the command for the user to run in a normal terminal tab: `claude-account login <name> --email <email>` |
| anything else | run `--help` and show it. |

## Hop block (answer to `use`)

This session keeps its OAuth token in memory. If the live store is switched underneath it, the running session may later write its refreshed token back over the new account and leave the Keychain and `~/.claude.json` disagreeing. So the switch happens after exit:

```
/exit
claude-as <name> --continue
```

If the session was started with `claude-as` (env `CLAUDE_AS_LOOP=1`), `/exit` alone is enough: the launcher switches to the flagged account and resumes with `--continue` by itself. With `CLAUDE_ACCOUNT_AUTOHOP=1` not even that; the session restarts on its own at the end of the turn in which the statusline crossed the threshold.

`--continue` resumes this conversation as the other account. The prompt cache is per organization, so the first turn after the hop costs full price.

## Never

- Run `use` or `login` from inside a session.
- Run or suggest `claude auth logout`. It revokes the token and that account's snapshot stops working.
- Print, log, or paste a credentials blob.
