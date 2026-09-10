# claude-account

Switch between Claude Code subscription accounts in the terminal without logging out or opening the browser again.

Claude Code holds exactly one login at a time. `claude-account` snapshots each login once, then swaps the live one on demand. Switching takes under a second and works from any shell, iTerm2 profile, or script.

## Quick start

```
/plugin marketplace add git@gitlab.9prints.com:thunder/dls-ai-team.git   # 1. once per device (skip if added)
/plugin install claude-account@dls-ai-team
/claude-account:claude-account install                                   # 2. CLI shim + claude-as; then: source ~/.zshrc
```
```bash
claude-account save work                                # 3. snapshot the account you are logged in as now
claude-account login personal --email you@example.com   # 4. add the second account (browser opens once)
claude-as                                               # 5. start claude; hops to the other account when the 5h quota is gone
```

Step 5 needs a statusline (it is what reads the quota): `install` prints the one line to add to `~/.claude/settings.json` if you have none. Details for each step follow.

## Install (once per device)

```
/plugin marketplace add git@gitlab.9prints.com:thunder/dls-ai-team.git   # skip if already added
/plugin install claude-account@dls-ai-team
/claude-account:claude-account install
```

Then `source ~/.zshrc` (or open a new terminal tab). The last step writes two small shims to `~/.local/bin/` (`claude-account`, `claude-account-statusline`), appends a `claude-as` shell function plus tab completion to your shell rc, runs `claude-account doctor`, and prints what to do about the statusline. Set `BIN_DIR` or `RC` in the environment to change the targets. The shim looks up the plugin's current install path on every call, so `/plugin update` never breaks it.

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
claude-as                         # start claude as the live account, with quota hop armed (see below)
claude-as personal                # switch to "personal", then start claude; extra args pass through
claude-as personal --continue
claude-account use work           # switch only, prints the new email + plan
claude-account list               # saved accounts, * = live, 5H = last recorded 5-hour usage
claude-account current            # name, email, org of the live login
claude-account rename work job    # rename a snapshot; tokens and profile move, nothing is logged out
```

`claude-as` is a shell function: `claude-as [account] [claude args...]`. Without an account name it starts `claude` as whoever is logged in. It works in any terminal that loads your shell rc (Terminal, iTerm2, VS Code, Warp, tmux).

### Hopping when the 5-hour quota runs out

Claude Code has no built-in account fallback: at the limit it waits for the reset. A running session also keeps its OAuth token in memory, so the account can only change between two processes. `claude-as` makes that hop cheap:

1. The statusline (see below) calls `claude-account quota` on every render. It records the live account's 5-hour usage in `~/.claude/accounts/<name>.quota`; at the threshold (`CLAUDE_ACCOUNT_HOP_AT`, default 90%) it picks the next account and writes its name to `~/.claude/accounts/.hop`.
2. Next account = the saved account with the lowest recorded usage, where an account whose reset time has passed or that was never measured counts as 0%. If every other account is also above the threshold, nothing is flagged and the statusline shows the reset time instead.
3. When `claude` exits and `.hop` exists, `claude-as` runs `claude-account use <next>` (re-snapshotting the account you leave) and relaunches `claude --continue`: same conversation, other account. Your terminal shows `claude-as: resuming as <next>`.

Three levels of automation:

| Started with | At the threshold | You do |
|---|---|---|
| `claude` | statusline shows `5h 91% -> /exit; claude-as m19 --continue` | type both |
| `claude-as` | statusline shows `5h 91% -> /exit hops to m19`; Claude's reply ends with the same hint | type `/exit` |
| `claude-as` with `CLAUDE_ACCOUNT_AUTOHOP=1` | statusline shows `-> auto hop to m19 after this turn`; the plugin's `Stop` hook ends the process when Claude finishes the turn; `claude-as` relaunches on `m19` | nothing |

Turn `CLAUDE_ACCOUNT_AUTOHOP=1` on per shell (`export` in your rc) or per launch (`CLAUDE_ACCOUNT_AUTOHOP=1 claude-as`). It only ever acts inside `claude-as` (`CLAUDE_AS_LOOP=1`), only on the main agent's `Stop`, and only on the process that spawned the hook (`CLAUDE_PID`, verified to be an ancestor). Each hop is logged to `~/.claude/accounts/.autohop.log`; `CLAUDE_ACCOUNT_AUTOHOP_DRY_RUN=1` logs without killing.

What the automatic hop costs: anything you were typing when the turn ended is lost; a long autonomous turn is never cut, the hop waits for it to finish; if the quota runs out mid-turn that turn fails first (`StopFailure`), and the hop happens on the next completed turn. To quit for real while `.hop` is set, exit twice (the second session starts below the threshold and clears the flag) or run `command claude`.

`-p` / `--print` runs never loop.

### iTerm2

Create one profile per account and set **General > Command > Send text at start** to `claude-as work`. Opening that profile lands you in Claude Code as that account.

### Statusline (required for the hop, optional otherwise)

The statusline is the only place Claude Code exposes the 5-hour usage, so it is what arms the hop: every render feeds the reading to `claude-account quota`. Without it nothing records usage, `claude-as` never hops, and `list` shows `-` in the 5H column.

**No statusline yet** — add to `~/.claude/settings.json` (top level):

```json
"statusLine": { "type": "command", "command": "bash ~/.local/bin/claude-account-statusline" }
```

It shows `model | ctx % | 5h % ->reset @account` plus the hop hint. Restart `claude` to pick it up.

**Already have a statusline script** — source the snippet from it after your script has `OUT` (the line so far), `FIVE` (`.rate_limits.five_hour.used_percentage`) and `FIVE_AT` (`.rate_limits.five_hour.resets_at`):

```bash
. "$(jq -r '.plugins | to_entries[] | select(.key|startswith("claude-account@")) | .value[0].installPath' \
     ~/.claude/plugins/installed_plugins.json)/scripts/statusline-snippet.sh"
```

(That resolves the plugin's current install path the same way the shim does, so `/plugin update` does not break it.) The snippet appends ` @account` and the hint to `OUT`. Both files only read and write under `~/.claude/accounts/`; neither switches accounts itself.

## Caveats

- **Always switch with this tool, never `claude auth logout`.** Logout deletes the live credentials and may revoke the token; the snapshot for that account then stops working and you must log in again.
- **Refresh-token rotation.** Claude Code rotates the refresh token when it renews the access token. `use` re-snapshots the account you leave so the stored copy stays valid. If you switch by other means (`claude auth login` directly), run `claude-account save <name>` afterwards or the old snapshot will be stale.
- **Running sessions.** A `claude` session keeps its tokens in memory. Switching while one is still running is untested: when that session next refreshes its token it may either pick up the new account or write its own refreshed token back over the live store, leaving the Keychain and `~/.claude.json` disagreeing. Exit sessions of the old account before switching; if it happened anyway, run `claude-account use <name>` again to realign.
- **The hop is a process restart.** Only `claude-as` (or you) can restart the process; a session started with plain `claude` can only be hinted. 7-day usage is not tracked; only the 5-hour window drives the hop.
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
| `claude-account list` shows `-` under 5H, no hop ever happens | The statusline is not feeding `claude-account quota`. Add `scripts/statusline-snippet.sh` to your statusline script. |
| Auto hop did not fire although the statusline showed it | Check `~/.claude/accounts/.autohop.log`. Empty: the session was not started with `claude-as` or `CLAUDE_ACCOUNT_AUTOHOP` is unset. A line with `via=walk` and a wrong pid: report it, and use the one-key mode meanwhile. |

## Uninstall

```bash
claude-account remove work          # per saved account; deletes its Keychain item + profile
rm ~/.local/bin/claude-account
# delete the block between "# >>> claude-account >>>" and "# <<< claude-account <<<" in ~/.zshrc
rm -rf ~/.claude/accounts           # profiles, .quota readings, .hop, .autohop.log
```

then `/plugin uninstall claude-account@dls-ai-team`. The live login is never touched by uninstalling.

## Files

```
.claude-plugin/plugin.json        plugin manifest
skills/claude-account/SKILL.md    in-session skill (/claude-account:claude-account)
hooks/hooks.json                  SessionStart install hint, UserPromptSubmit hop hint, Stop auto-hop
scripts/claude-account.sh         the tool (save/use/list/login/next/quota/...)
scripts/install.sh                shim + claude-as shell function + completion + doctor
scripts/session-hint.sh           SessionStart hook body
scripts/hop-hint.sh               UserPromptSubmit hook body
scripts/autohop-stop.sh           Stop hook body (opt-in, CLAUDE_ACCOUNT_AUTOHOP=1)
scripts/statusline.sh             standalone statusline (shim: ~/.local/bin/claude-account-statusline)
scripts/statusline-snippet.sh     block to source from an existing statusline: account name, quota recording, hop hint
```
