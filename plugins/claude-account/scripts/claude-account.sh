#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(jq -r '.version // "dev"' "$HERE/../.claude-plugin/plugin.json" 2>/dev/null || printf dev)
LIVE_SERVICE="${CLAUDE_ACCOUNT_LIVE_SERVICE:-Claude Code-credentials}"
STORE_PREFIX="Claude Code-credentials-acct-"
ACCOUNTS_DIR="${CLAUDE_ACCOUNT_DIR:-$HOME/.claude/accounts}"
OS="$(uname -s)"

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  CONFIG_DIR="$CLAUDE_CONFIG_DIR"
  CONFIG_JSON="$CLAUDE_CONFIG_DIR/.claude.json"
else
  CONFIG_DIR="$HOME/.claude"
  CONFIG_JSON="$HOME/.claude.json"
fi
LINUX_CRED_FILE="$CONFIG_DIR/.credentials.json"
CURRENT_MARKER="$ACCOUNTS_DIR/.current"
HOP_FILE="$ACCOUNTS_DIR/.hop"
HOP_AT="${CLAUDE_ACCOUNT_HOP_AT:-90}"

usage() {
  cat <<EOF
claude-account $VERSION - switch Claude Code (claude.ai subscription) accounts without re-login

Usage:
  claude-account login <name> [--email <email>]
                                    sign in to ANOTHER account in a scratch config dir and snapshot it;
                                    the current login is not touched (opens the browser once)
  claude-account save [name]        snapshot the current login under <name> (default: its email)
  claude-account use <name> [--force]
                                    switch the live login to <name>
  claude-account list               saved accounts (* = live now)
  claude-account current            who is logged in now
  claude-account remove <name>      delete a saved snapshot (live login untouched)
  claude-account rename <old> <new> rename a saved snapshot (tokens and profile move; live login untouched)
  claude-account names              bare names, for shell completion
  claude-account next               name of the best account to hop to (lowest recorded 5h usage,
                                    reset windows count as 0; with the app: the app's ranking, 7d first
                                    when enabled); exit 1 when every other account is exhausted
  claude-account quota <pct> [resets_at]
                                    statusline entry point: record the live account's 5h usage; at or above
                                    the hop threshold write the next account's name to accounts/.hop and print it
  claude-account doctor             check dependencies and storage

Environment:
  CLAUDE_ACCOUNT_DIR                where snapshots live (default ~/.claude/accounts)
  CLAUDE_ACCOUNT_LIVE_SERVICE       macOS Keychain service Claude Code writes to
                                    (default "Claude Code-credentials"; required when CLAUDE_CONFIG_DIR is set)
  CLAUDE_ACCOUNT_HOP_AT             5h usage percent that flags a hop (default 90)
  CLAUDE_ACCOUNT_AUTOHOP            1 = inside claude-as, restart on the next account automatically at the end
                                    of the turn that crossed the threshold (default: only hint; /exit hops)
  CLAUDE_ACCOUNT_NO_APP             1 = never hand commands to Claude Switcher.app (see below)

With Claude Switcher.app installed (~/.local/bin/claude-switcher), save / use / login / remove / rename run
through the app's CLI: one implementation of the snapshot rules for both tools (the live token is filed under
the account it really belongs to, a dead snapshot is never switched to). Without the app, this script does
the work itself under the same lock file.
EOF
}

die()  { printf 'claude-account: %s\n' "$*" >&2; exit 1; }
warn() { printf 'claude-account: warning: %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

validate_name() {
  [ -n "${1:-}" ] || die "account name required"
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._@-]+$' || die "invalid name '$1' (allowed: letters, digits, . _ @ -)"
}

fmt_epoch_ms() {
  local sec=$(( $1 / 1000 ))
  date -r "$sec" +%Y-%m-%d 2>/dev/null || date -d "@$sec" +%Y-%m-%d 2>/dev/null || printf '%s' "$1"
}

json_get() { printf '%s' "$1" | jq -r "$2"; }

# Usable = both tokens present. Claude Switcher.app applies the same rule (OAuthBlob.isComplete): a blob only one
# tool accepts lets this CLI switch into a login the app calls unreadable.
is_oauth_blob() {
  printf '%s' "${1:-}" | jq -e '(.claudeAiOauth.accessToken // "") != "" and (.claudeAiOauth.refreshToken // "") != ""' >/dev/null 2>&1
}

keychain_read()   { security find-generic-password -s "$1" -w 2>/dev/null; }
keychain_write()  { security add-generic-password -U -a "$USER" -s "$1" -w "$2" >/dev/null; }
keychain_delete() { security delete-generic-password -s "$1" >/dev/null 2>&1 || true; }

saved_blob_file() { printf '%s/%s.credentials.json' "$ACCOUNTS_DIR" "$1"; }
profile_file()    { printf '%s/%s.json' "$ACCOUNTS_DIR" "$1"; }
quota_file()      { printf '%s/%s.quota' "$ACCOUNTS_DIR" "$1"; }

# Claude Switcher.app heartbeats here while it runs; it then owns .quota, .hop and every restart. Two hop
# policies at once (this one on the statusline's 5h reading, the app's on both accounts' weekly pace) fight.
switcher_alive() {
  local f="$ACCOUNTS_DIR/.switcher/alive" m
  [ -f "$f" ] || return 1
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - m )) -lt 120 ]
}

current_name() { name_for_uuid "$(json_get "$(live_profile)" '.accountUuid // empty' 2>/dev/null)"; }

# Effective 5h usage of a saved account from its last recorded statusline reading:
# no record or a reset window that already passed -> 0.
quota_score() {
  local f pct resets now
  f=$(quota_file "$1")
  [ -f "$f" ] || { printf '0'; return; }
  IFS=$'\t' read -r pct resets _ < "$f"
  now=$(date +%s)
  if [ -n "$resets" ] && [ "$resets" -gt 0 ] 2>/dev/null && [ "$now" -ge "$resets" ]; then printf '0'; return; fi
  printf '%s' "${pct:-0}"
}

read_live_blob() {
  case "$OS" in
    Darwin) keychain_read "$LIVE_SERVICE" ;;
    *)      [ -f "$LINUX_CRED_FILE" ] && cat "$LINUX_CRED_FILE" ;;
  esac
}

write_live_blob() {
  case "$OS" in
    Darwin) keychain_write "$LIVE_SERVICE" "$1" ;;
    *)      ( umask 077; printf '%s' "$1" > "$LINUX_CRED_FILE" ) ;;
  esac
}

read_saved_blob() {
  case "$OS" in
    Darwin) keychain_read "${STORE_PREFIX}$1" ;;
    *)      [ -f "$(saved_blob_file "$1")" ] && cat "$(saved_blob_file "$1")" ;;
  esac
}

write_saved_blob() {
  case "$OS" in
    Darwin) keychain_write "${STORE_PREFIX}$1" "$2" ;;
    *)      ( umask 077; printf '%s' "$2" > "$(saved_blob_file "$1")" ) ;;
  esac
}

delete_saved_blob() {
  case "$OS" in
    Darwin) keychain_delete "${STORE_PREFIX}$1" ;;
    *)      rm -f "$(saved_blob_file "$1")" ;;
  esac
}

live_profile() { jq -c '.oauthAccount // empty' "$CONFIG_JSON" 2>/dev/null || true; }

each_profile_file() {
  local f
  for f in "$ACCOUNTS_DIR"/*.json; do
    [ -f "$f" ] || continue
    case "$f" in *.credentials.json) continue ;; esac
    printf '%s\n' "$f"
  done
}

name_for_uuid() {
  local f
  [ -n "${1:-}" ] || return 1
  for f in $(each_profile_file); do
    if [ "$(jq -r '.oauthAccount.accountUuid // empty' "$f")" = "$1" ]; then
      jq -r '.name' "$f"
      return 0
    fi
  done
  return 1
}

set_current_marker() {
  mkdir -p "$ACCOUNTS_DIR"
  printf '%s\t%s\n' "$1" "$2" > "$CURRENT_MARKER"
}

list_claude_services() {
  security dump-keychain 2>/dev/null \
    | grep -o '"svce"<blob>="Claude Code-credentials[^"]*"' \
    | sed -E 's/^"svce"<blob>="//; s/"$//' \
    | sort -u
}

write_profile_file() {
  mkdir -p "$ACCOUNTS_DIR"
  chmod 700 "$ACCOUNTS_DIR"
  jq -n --arg name "$1" \
        --arg saved_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg sub "$(json_get "$3" '.claudeAiOauth.subscriptionType // "?"')" \
        --argjson profile "$2" \
        '{name: $name, saved_at: $saved_at, subscriptionType: $sub, oauthAccount: $profile}' \
        > "$(profile_file "$1")"
  chmod 600 "$(profile_file "$1")"
}

patch_config_profile() {
  local tmp
  tmp=$(mktemp "${CONFIG_JSON}.XXXXXX")
  if jq --argjson p "$1" '.oauthAccount = $p' "$CONFIG_JSON" > "$tmp"; then
    chmod 600 "$tmp"
    mv "$tmp" "$CONFIG_JSON"
  else
    rm -f "$tmp"
    die "failed to update $CONFIG_JSON"
  fi
}

warn_if_refresh_expired() {
  local exp now
  exp=$(json_get "$1" '.claudeAiOauth.refreshTokenExpiresAt // empty')
  now=$(( $(date +%s) * 1000 ))
  if [ -n "$exp" ] && [ "$exp" -lt "$now" ] 2>/dev/null; then
    warn "refresh token for '$2' expired on $(fmt_epoch_ms "$exp"). If Claude asks you to log in, do so and run 'claude-account save $2'."
  fi
}

guard_config_dir() {
  if [ "$OS" = Darwin ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -z "${CLAUDE_ACCOUNT_LIVE_SERVICE:-}" ]; then
    die "CLAUDE_CONFIG_DIR is set; Claude Code then uses a hashed Keychain service name. Find it with: security dump-keychain | grep 'Claude Code-credentials'  and export CLAUDE_ACCOUNT_LIVE_SERVICE=<that name>"
  fi
}

cmd_save() {
  local name="${1:-}" profile blob email uuid other
  profile=$(live_profile)
  [ -n "$profile" ] || die "no claude.ai login in $CONFIG_JSON - run 'claude auth login' first"
  blob=$(read_live_blob || true)
  is_oauth_blob "$blob" || die "no OAuth credentials in the live store - API-key logins cannot be snapshotted"
  email=$(json_get "$profile" '.emailAddress // "unknown"')
  uuid=$(json_get "$profile" '.accountUuid // empty')
  [ -n "$name" ] || name="$email"
  validate_name "$name"
  other=$(name_for_uuid "$uuid" || true)
  [ -n "$other" ] && [ "$other" != "$name" ] && warn "this account is already saved as '$other'; saving again as '$name'"
  write_saved_blob "$name" "$blob"
  write_profile_file "$name" "$profile" "$blob"
  set_current_marker "$name" "$uuid"
  printf "Saved '%s'  (%s, %s)\n" "$name" "$email" "$(json_get "$profile" '.organizationName // "-"')"
}

cmd_login() {
  local name="" email=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --email) email="${2:-}"; shift ;;
      -*)      die "unknown option '$1'" ;;
      *)       name="$1" ;;
    esac
    shift
  done
  validate_name "$name"
  [ -f "$(profile_file "$name")" ] && die "'$name' already exists - remove it first or pick another name"
  need claude

  local scratch live_before live_profile_before before="" after new_services profile blob svc=""
  scratch=$(mktemp -d "$HOME/.claude-login.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT
  live_before=$(read_live_blob || true)
  live_profile_before=$(live_profile)
  [ "$OS" = Darwin ] && before=$(list_claude_services)

  printf 'Signing in inside a scratch config dir; the current login (%s) is not touched.\n' \
    "$(json_get "${live_profile_before:-{\}}" '.emailAddress // "none"')"
  if [ -n "$email" ]; then
    CLAUDE_CONFIG_DIR="$scratch" claude auth login --email "$email" || die "claude auth login failed"
  else
    CLAUDE_CONFIG_DIR="$scratch" claude auth login || die "claude auth login failed"
  fi

  profile=$(jq -c '.oauthAccount // empty' "$scratch/.claude.json" 2>/dev/null || true)
  [ -n "$profile" ] || die "login finished but $scratch/.claude.json holds no oauthAccount"

  if [ "$OS" = Darwin ]; then
    after=$(list_claude_services)
    new_services=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v -- '-acct-' || true)
    if [ "$(printf '%s\n' "$new_services" | grep -c .)" -eq 1 ]; then
      svc="$new_services"
      blob=$(keychain_read "$svc" || true)
    elif [ "$(read_live_blob || true)" != "$live_before" ]; then
      svc="$LIVE_SERVICE"
      blob=$(read_live_blob || true)
    else
      die "cannot locate the new credentials in the Keychain (new entries: $(printf '%s' "$new_services" | tr '\n' ' '))"
    fi
  else
    blob=$(cat "$scratch/.credentials.json" 2>/dev/null || true)
  fi
  is_oauth_blob "$blob" || die "new credentials are not an OAuth blob (API-key login?)"

  write_saved_blob "$name" "$blob"
  write_profile_file "$name" "$profile" "$blob"

  if [ "$svc" = "$LIVE_SERVICE" ]; then
    warn "claude wrote into the live store despite CLAUDE_CONFIG_DIR - restoring the previous login"
    [ -n "$live_before" ] && write_live_blob "$live_before"
    [ -n "$live_profile_before" ] && [ "$(live_profile)" != "$live_profile_before" ] && patch_config_profile "$live_profile_before"
  elif [ -n "$svc" ]; then
    keychain_delete "$svc"
  fi

  printf "Saved '%s'  (%s, %s). Live login unchanged. Switch with: claude-account use %s\n" "$name" \
    "$(json_get "$profile" '.emailAddress // "?"')" \
    "$(json_get "$profile" '.organizationName // "-"')" "$name"
}

cmd_use() {
  local force=0 name="" arg
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      -*)      die "unknown option '$arg'" ;;
      *)       name="$arg" ;;
    esac
  done
  validate_name "$name"
  [ -f "$(profile_file "$name")" ] || die "no saved account '$name' - see 'claude-account list'"

  local target_blob target_profile
  target_blob=$(read_saved_blob "$name" || true)
  is_oauth_blob "$target_blob" || die "saved credentials for '$name' are missing or unreadable - log in as that account and run 'claude-account save $name'"
  target_profile=$(jq -c '.oauthAccount' "$(profile_file "$name")")

  local cur_profile cur_uuid cur_name="" cur_email
  cur_profile=$(live_profile)
  if [ -n "$cur_profile" ]; then
    cur_uuid=$(json_get "$cur_profile" '.accountUuid // empty')
    cur_email=$(json_get "$cur_profile" '.emailAddress // "unknown"')
    cur_name=$(name_for_uuid "$cur_uuid" || true)
    if [ -z "$cur_name" ] && [ "$force" -ne 1 ]; then
      die "current login ($cur_email) was never saved and would be lost. Run 'claude-account save <name>' first, or 'use $name --force' to discard it."
    fi
    if [ "$cur_name" = "$name" ]; then
      cmd_save "$name" >/dev/null
      printf "Already on '%s' (%s) - snapshot refreshed\n" "$name" "$cur_email"
      return 0
    fi
    if [ -n "$cur_name" ] && is_oauth_blob "$(read_live_blob || true)"; then
      cmd_save "$cur_name" >/dev/null
    fi
  fi

  warn_if_refresh_expired "$target_blob" "$name"
  rm -f "$HOP_FILE"
  write_live_blob "$target_blob"
  patch_config_profile "$target_profile"
  set_current_marker "$name" "$(json_get "$target_profile" '.accountUuid // empty')"
  printf "Switched to '%s'  (%s, %s)\n" "$name" \
    "$(json_get "$target_profile" '.emailAddress // "?"')" \
    "$(json_get "$target_profile" '.organizationName // "-"')"
  if command -v claude >/dev/null 2>&1; then
    claude auth status 2>/dev/null \
      | jq -r '"claude auth status: \(.email // "?") / \(.subscriptionType // "?")"' 2>/dev/null || true
  fi
}

cmd_list() {
  local live f name email org sub saved uuid mark q found=0
  live=$(json_get "$(live_profile)" '.accountUuid // empty' 2>/dev/null || true)
  printf '%-1s %-14s %-32s %-22s %-8s %-6s %s\n' '' NAME EMAIL ORG PLAN 5H SAVED
  for f in $(each_profile_file); do
    found=1
    IFS=$'\t' read -r name email org sub saved uuid <<<"$(jq -r '[
      .name, (.oauthAccount.emailAddress // "-"), (.oauthAccount.organizationName // "-"),
      (.subscriptionType // "-"), (.saved_at // "-"), (.oauthAccount.accountUuid // "-")
    ] | @tsv' "$f")"
    mark=" "; [ -n "$live" ] && [ "$uuid" = "$live" ] && mark="*"
    q="-"; [ -f "$(quota_file "$name")" ] && q="$(quota_score "$name")%"
    printf '%-1s %-14s %-32s %-22s %-8s %-6s %s\n' "$mark" "$name" "$email" "$org" "$sub" "$q" "${saved%%T*}"
  done
  [ "$found" -eq 1 ] || printf '(none saved yet - run: claude-account save <name>)\n'
}

cmd_current() {
  local profile name
  profile=$(live_profile)
  [ -n "$profile" ] || { printf 'not logged in (no oauthAccount in %s)\n' "$CONFIG_JSON"; return 1; }
  name=$(name_for_uuid "$(json_get "$profile" '.accountUuid // empty')" || printf '(unsaved)')
  printf '%s\t%s\t%s\n' "$name" \
    "$(json_get "$profile" '.emailAddress // "?"')" \
    "$(json_get "$profile" '.organizationName // "-"')"
}

cmd_remove() {
  validate_name "${1:-}"
  [ -f "$(profile_file "$1")" ] || die "no saved account '$1'"
  delete_saved_blob "$1"
  rm -f "$(profile_file "$1")" "$(quota_file "$1")"
  if [ -f "$CURRENT_MARKER" ] && [ "$(cut -f1 "$CURRENT_MARKER")" = "$1" ]; then
    rm -f "$CURRENT_MARKER"
  fi
  printf "Removed '%s' (the live login is untouched)\n" "$1"
}

cmd_rename() {
  local old="${1:-}" new="${2:-}" blob profile
  validate_name "$old"
  validate_name "$new"
  [ "$old" != "$new" ] || die "old and new name are the same"
  [ -f "$(profile_file "$old")" ] || die "no saved account '$old'"
  [ -f "$(profile_file "$new")" ] && die "'$new' already exists - remove it first or pick another name"
  blob=$(read_saved_blob "$old" || true)
  is_oauth_blob "$blob" || die "saved credentials for '$old' are missing or not an OAuth blob"

  write_saved_blob "$new" "$blob"
  profile=$(jq -c --arg name "$new" '.name = $name' "$(profile_file "$old")")
  ( umask 077; printf '%s\n' "$profile" > "$(profile_file "$new")" )
  delete_saved_blob "$old"
  rm -f "$(profile_file "$old")"
  [ -f "$(quota_file "$old")" ] && mv "$(quota_file "$old")" "$(quota_file "$new")"
  if [ -f "$CURRENT_MARKER" ] && [ "$(cut -f1 "$CURRENT_MARKER")" = "$old" ]; then
    set_current_marker "$new" "$(cut -f2 "$CURRENT_MARKER")"
  fi
  printf "Renamed '%s' -> '%s' (the live login is untouched)\n" "$old" "$new"
}

cmd_names() {
  local f
  for f in $(each_profile_file); do jq -r '.name' "$f"; done
}

cmd_next() {
  local skip="${1:-}" f name score best="" best_score=101 cs
  # the app ranks with live 5h + 7d readings (7d first when "ưu tiên 7d thấp" is on) and skips dead snapshots;
  # .quota only carries the 5h number
  if cs=$(app_cli); then "$cs" next; return; fi
  [ -n "$skip" ] || skip=$(current_name || true)
  for f in $(each_profile_file); do
    name=$(jq -r '.name' "$f")
    [ "$name" = "$skip" ] && continue
    score=$(quota_score "$name")
    [ "$score" -lt "$HOP_AT" ] 2>/dev/null || continue
    is_oauth_blob "$(read_saved_blob "$name" || true)" || continue
    if [ "$score" -lt "$best_score" ]; then best="$name"; best_score="$score"; fi
  done
  [ -n "$best" ] || { printf 'claude-account: no other usable account below %s%% 5h usage\n' "$HOP_AT" >&2; return 1; }
  printf '%s\n' "$best"
}

cmd_quota() {
  local pct="${1:-}" resets="${2:-0}" name next
  [ -n "$pct" ] || return 0
  # the app measures every account from the API and plans per-session restarts; a statusline reading here would
  # be filed under whatever account ~/.claude.json names (wrong once sessions of two accounts overlap)
  if switcher_alive; then
    [ -s "$HOP_FILE" ] && cat "$HOP_FILE"
    return 0
  fi
  pct=${pct%%.*}
  [ "$pct" -ge 0 ] 2>/dev/null || return 0
  name=$(current_name) || return 0
  mkdir -p "$ACCOUNTS_DIR"
  ( umask 077; printf '%s\t%s\t%s\n' "$pct" "${resets:-0}" "$(date +%s)" > "$(quota_file "$name")" )
  if [ "$pct" -ge "$HOP_AT" ]; then
    if next=$(cmd_next "$name" 2>/dev/null); then
      ( umask 077; printf '%s\n' "$next" > "$HOP_FILE" )
      printf '%s\n' "$next"
    else
      rm -f "$HOP_FILE"
    fi
  else
    rm -f "$HOP_FILE"
  fi
}

cmd_doctor() {
  local ok=1 n
  report() { if [ "$1" = ok ]; then printf 'ok    %s\n' "$2"; else printf 'FAIL  %s\n' "$2"; ok=0; fi; }
  command -v jq >/dev/null 2>&1     && report ok "jq: $(command -v jq)"           || report fail "jq not found"
  command -v claude >/dev/null 2>&1 && report ok "claude: $(claude --version 2>/dev/null | head -1)" || report fail "claude not found"
  if [ "$OS" = Darwin ]; then
    command -v security >/dev/null 2>&1 && report ok "security (Keychain CLI)" || report fail "security not found"
    if is_oauth_blob "$(read_live_blob || true)"; then report ok "live Keychain entry '$LIVE_SERVICE' holds OAuth credentials"
    else report fail "no OAuth credentials under Keychain service '$LIVE_SERVICE'"; fi
  else
    if is_oauth_blob "$(read_live_blob || true)"; then report ok "live credentials file $LINUX_CRED_FILE"
    else report fail "no OAuth credentials in $LINUX_CRED_FILE (Linux path is untested)"; fi
  fi
  [ -f "$CONFIG_JSON" ] && report ok "config $CONFIG_JSON" || report fail "config $CONFIG_JSON missing"
  [ -n "$(live_profile)" ] && report ok "oauthAccount present ($(json_get "$(live_profile)" '.emailAddress // "?"'))" || report fail "no oauthAccount in config (not logged in via claude.ai?)"
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    [ -n "${CLAUDE_ACCOUNT_LIVE_SERVICE:-}" ] && report ok "CLAUDE_CONFIG_DIR set, live service overridden" || report fail "CLAUDE_CONFIG_DIR set but CLAUDE_ACCOUNT_LIVE_SERVICE not - see usage"
  fi
  n=$(cmd_names | wc -l | tr -d ' ')
  report ok "$n saved account(s) in $ACCOUNTS_DIR"
  [ "$ok" -eq 1 ]
}

# The app's CLI, when Claude Switcher.app is installed and answers.
app_cli() {
  [ "${CLAUDE_ACCOUNT_NO_APP:-}" = 1 ] && return 1
  local cs="${CLAUDE_SWITCHER_BIN:-$HOME/.local/bin/claude-switcher}"
  [ -x "$cs" ] && "$cs" --version >/dev/null 2>&1 || return 1
  printf '%s' "$cs"
}

# Re-run this command holding .switcher/lock, the flock(2) the app takes around every store write, so a
# switch here never interleaves with one there (or with a second copy of this script).
relock() {
  [ -n "${CLAUDE_ACCOUNT_LOCKED:-}" ] && return 0
  local lock="$ACCOUNTS_DIR/.switcher/lock"
  mkdir -p "$ACCOUNTS_DIR/.switcher"
  if command -v lockf >/dev/null 2>&1; then
    CLAUDE_ACCOUNT_LOCKED=1 exec lockf -k -t 30 "$lock" bash "${BASH_SOURCE[0]}" "$@"
  elif command -v flock >/dev/null 2>&1; then
    CLAUDE_ACCOUNT_LOCKED=1 exec flock -w 30 "$lock" bash "${BASH_SOURCE[0]}" "$@"
  fi
}

main() {
  need jq
  local cmd="${1:-}" cs
  [ $# -gt 0 ] && shift
  case "$cmd" in
    save|use|login|remove|rm|rename|mv)
      if cs=$(app_cli); then exec "$cs" "$cmd" "$@"; fi ;;
  esac
  case "$cmd" in
    save|use|remove|rm|rename|mv) relock "$cmd" "$@" ;;
  esac
  case "$cmd" in
    save|use|list|current|remove|rename|names|login|next|quota) guard_config_dir ;;
  esac
  case "$cmd" in
    login)    cmd_login "$@" ;;
    save)     cmd_save "$@" ;;
    use)      cmd_use "$@" ;;
    list|ls)  cmd_list ;;
    current)  cmd_current ;;
    remove|rm) cmd_remove "$@" ;;
    rename|mv) cmd_rename "$@" ;;
    names)    cmd_names ;;
    next)     cmd_next "$@" ;;
    quota)    cmd_quota "$@" ;;
    doctor)   cmd_doctor ;;
    -v|--version|version) printf '%s\n' "$VERSION" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command '$cmd' (try --help)" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
