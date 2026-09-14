#!/usr/bin/env bash
# Uninstall Claude Switcher: the app bundle, its Stop/StopFailure hook, the claude-switcher shim, its
# claude-as block in the shell rc, its files under ~/.claude/accounts/.switcher, preferences and login item.
# The account store (snapshots, profiles, .quota, live login) is left untouched.
#
# From a downloaded .dmg run it as:  bash "/Volumes/Claude Switcher <version>/Uninstall.command"
# (double-clicking a quarantined .command is blocked by Gatekeeper the same way the app is).
set -u
APP="/Applications/ClaudeSwitcher.app"
[ -d "$APP" ] || { [ -d "$HOME/Applications/ClaudeSwitcher.app" ] && APP="$HOME/Applications/ClaudeSwitcher.app"; }

pkill -x ClaudeSwitcher 2>/dev/null && sleep 1

if [ -x "$APP/Contents/MacOS/ClaudeSwitcher" ]; then
  # the binary knows every path and can unregister the login item; it keeps the bundle for us to delete
  "$APP/Contents/MacOS/ClaudeSwitcher" uninstall --keep-app
else
  echo "app binary not found - removing files directly"
  dir="${CLAUDE_ACCOUNT_DIR:-$HOME/.claude/accounts}"
  rm -rf "$dir/.switcher" "$HOME/.local/bin/claude-switcher" "$HOME/.local/bin/claude-switcher-hook"
  s="$HOME/.claude/settings.json"
  if [ -f "$s" ] && command -v jq >/dev/null 2>&1 && grep -q claude-switcher "$s"; then
    cp "$s" "$s.bak-$(date +%s)"
    # keep in sync with HookInstaller.jqRemove
    jq 'def strip: if type == "array" then map(select(any(.hooks[]?; (.command // "") | contains("claude-switcher")) | not)) else . end;
        if .hooks then .hooks |= with_entries(.value |= strip) else . end' "$s" > "$s.tmp" && mv "$s.tmp" "$s"
  fi
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$rc" ] || continue
    if grep -q '# >>> claude-account >>>' "$rc" && awk '/# >>> claude-account >>>/{f=1} f&&/claude-switcher/{found=1} /# <<< claude-account <<</{f=0} END{exit !found}' "$rc"; then
      cp "$rc" "$rc.bak-$(date +%s)"
      awk '/# >>> claude-account >>>/{skip=1} !skip{print} /# <<< claude-account <<</{skip=0}' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"
      echo "removed claude-as block from $rc"
    fi
  done
  defaults delete com.hapk.claude-switcher >/dev/null 2>&1
  echo "if 'ClaudeSwitcher' is still listed under System Settings > General > Login Items, remove it there"
fi

[ -d "$APP" ] && rm -rf "$APP" && echo "removed $APP"
echo "Claude Switcher uninstalled. Account snapshots, .quota files and the live login were not touched."
