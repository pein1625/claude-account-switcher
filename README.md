# claude-account

Switch between Claude Code subscription accounts in the terminal without logging out or opening the browser again.

Claude Code holds exactly one login at a time. `claude-account` snapshots each login once, then swaps the live one on demand. Switching takes under a second and works from any shell, iTerm2 profile, or script.

## Install (once per device)

```
/plugin marketplace add git@gitlab.9prints.com:thunder/dls-ai-team.git   # skip if already added
/plugin install claude-account@dls-ai-team
/claude-account:claude-account install
```

Then `source ~/.zshrc` (or open a new terminal tab). The last step writes a small shim to `~/.local/bin/claude-account`, appends a `claude-as` shell function plus tab completion to your shell rc, and runs `claude-account doctor`. Set `BIN_DIR` or `RC` in the environment to change the targets. The shim looks up the plugin's current install path on every call, so `/plugin update` never breaks it.

Without Claude Code plugins: `git clone git@gitlab.9prints.com:thunder/dls-ai-team.git` and run `plugins/claude-account/scripts/install.sh` from the clone.

## How it works

Claude Code keeps a login in two places:

| What | Where (macOS) | Where (Linux, untested) |
|---|---|---|
| OAuth tokens (`accessToken`, `refreshToken`, expiry) | Keychain item, service `Claude Code-credentials` | `~/.claude/.credentials.json` |
| Account profile (`oauthAccount`: email, org, plan) | `~/.claude.json` | `~/.claude.json` |

`claude-account save <name>` copies both into a per-account snapshot:

- tokens go to a second Keychain item `Claude Code-credentials-acct-<name>` (never to a plain file on macOS)
- the profile goes to `~/.claude/accounts/<name>.json` (no secrets inside)

`claude-account use <name>` first re-snapshots the account you are leaving (so its rotated refresh token stays current), then writes the target's tokens and profile back into the live locations. Nothing is ever logged out, so no token is revoked.

Everything else in `~/.claude` (settings, hooks, agents, memory, projects) is shared across accounts and untouched.

## Requirements

- macOS (Keychain via the `security` CLI). Linux falls back to the credentials file but has not been tested.
- `jq`
- Claude Code 2.1.x or newer with `claude auth login`
- Accounts signed in through claude.ai (Pro / Max / Team). API-key logins have nothing to snapshot.

## First-time setup (once per account, per device)

Tokens are per device. Do not copy snapshots between machines; sign in once on each.

```bash
claude-account save work                              # 1. snapshot the account you are logged in as now
claude-account login personal --email you@example.com # 2. sign in to the second account (browser opens once)
claude-account list                                   # both listed, * marks the live one
```

`login` signs in inside a scratch config dir (`CLAUDE_CONFIG_DIR`), snapshots the result, then deletes the scratch storage. Your current login, and any `claude` session already running, are untouched. Run it from a normal terminal tab, not from inside a Claude session.

Without `login` the manual route also works: `claude auth login` replaces the live login in place (no logout needed), then `claude-account save <name>` snapshots it. Do that only when no `claude` session is running, or the running session may later write its own refreshed token over the new one (see Caveats).

## Daily use

```bash
claude-account use work           # switch, prints the new email + plan
claude-account current            # name, email, org of the live login
claude-account rename work job    # rename a snapshot; tokens and profile move, nothing is logged out
claude-as personal                # switch and start claude in one go; extra args pass through
claude-as personal --continue
```

### Inside a Claude session

`/claude-account:claude-account` (no args) shows who is logged in and what is saved. `save`, `list`, `current`, `doctor`, `rename`, `remove` run in place. `use` and `login` are deliberately not run from inside a session (see the next section); the skill prints the command to run after `/exit` instead. Plain language works too: "đổi account", "hết quota rồi".

### Switching in the middle of a conversation

A running session keeps its token in memory, so switching from another tab does not affect it. To carry the conversation over to another account, exit and resume:

```bash
/exit                             # or Ctrl+C twice
claude-as personal --continue     # same conversation, other account
```

Transcripts live locally under `~/.claude/projects/` and are not tied to an account. The prompt cache does not carry over (it is per organization), so the first turn after the hop costs full price.

`<name>` is any label you chose at `save` time (letters, digits, `. _ @ -`). Tab completion on `claude-as` lists them.

### iTerm2

Create one profile per account and set **General > Command > Send text at start** to `claude-as work`. Opening that profile lands you in Claude Code as that account.

### Statusline (optional)

`use` and `save` write the live account's name to `~/.claude/accounts/.current`. A statusline command can show it and, when the 5-hour quota is almost gone, hint the hop command; `scripts/statusline-snippet.sh` is a drop-in block for your statusline script. The snippet only reads; it never switches accounts by itself.

## Caveats

- **Always switch with this tool, never `claude auth logout`.** Logout deletes the live credentials and may revoke the token; the snapshot for that account then stops working and you must log in again.
- **Refresh-token rotation.** Claude Code rotates the refresh token when it renews the access token. `use` re-snapshots the account you leave so the stored copy stays valid. If you switch by other means (`claude auth login` directly), run `claude-account save <name>` afterwards or the old snapshot will be stale.
- **Running sessions.** A `claude` session keeps its tokens in memory. Switching while one is still running is untested: when that session next refreshes its token it may either pick up the new account or write its own refreshed token back over the live store, leaving the Keychain and `~/.claude.json` disagreeing. Exit sessions of the old account before switching; if it happened anyway, run `claude-account use <name>` again to realign.
- **No automatic failover.** Claude Code has no built-in account fallback; when the 5-hour quota is exhausted it waits for the reset. This tool only makes the manual hop cheap.
- **`CLAUDE_CONFIG_DIR`.** With a custom config dir Claude Code uses a hashed Keychain service name. Find it with `security dump-keychain | grep 'Claude Code-credentials'` and export it as `CLAUDE_ACCOUNT_LIVE_SERVICE` before using this tool.
- **Snapshots hold live tokens.** On macOS they sit in your login Keychain, like Claude Code's own entry. On Linux they are `0600` files under `~/.claude/accounts/`; keep that directory out of version control and backups you share.

## Troubleshooting

| Symptom | Fix |
|---|---|
| macOS asks whether `security` may access the Keychain item | Click **Always Allow**. Claude Code itself uses the same CLI. |
| `no OAuth credentials in the live store` | You are logged in with an API key or not at all. Run `claude auth login` first. |
| `cannot locate the new credentials in the Keychain` | `login` expected exactly one new `Claude Code-credentials-*` item. Rerun; if it repeats, sign in the manual way and `save`. |
| `current login (...) was never saved and would be lost` | Run `claude-account save <name>` for it, or pass `--force` to discard it. |
| `warning: refresh token for '<name>' expired` | Claude will prompt for login when the access token runs out. Log in, then `claude-account save <name>`. |
| `claude auth status` still shows the old email | The store was not switched. Run `claude-account doctor`; check `CLAUDE_CONFIG_DIR`. |
| `claude-account: tool not found under ...` | The plugin was uninstalled or moved. `/plugin install claude-account@dls-ai-team` again, or rerun `install.sh` from a clone. |
| Every session prints "CLI not linked on this device yet" | Run `/claude-account:claude-account install` once. The hint stops as soon as `~/.local/bin/claude-account` exists. |

## Uninstall

```bash
claude-account remove work          # per saved account; deletes its Keychain item + profile
rm ~/.local/bin/claude-account
# delete the block between "# >>> claude-account >>>" and "# <<< claude-account <<<" in ~/.zshrc
rm -rf ~/.claude/accounts
```

then `/plugin uninstall claude-account@dls-ai-team`. The live login is never touched by uninstalling.

## Files

```
.claude-plugin/plugin.json        plugin manifest
skills/claude-account/SKILL.md    in-session skill (/claude-account:claude-account)
hooks/hooks.json                  SessionStart hint until the CLI is installed
scripts/claude-account.sh         the tool
scripts/install.sh                shim + shell snippet + doctor
scripts/session-hint.sh           the hook body
scripts/statusline-snippet.sh     optional statusline block
```
