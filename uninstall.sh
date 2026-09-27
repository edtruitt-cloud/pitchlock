#!/bin/bash
# Remove pitchlock and give the lock screen back to Omarchy.
# Your settings (~/.config/pitchlock) and unlock history (~/.local/state/pitchlock.json)
# are left in place; delete them yourself if you won't reinstall.
set -euo pipefail

user="${USER:-$(id -un)}"
id="$user.lock"
fail() { printf 'pitchlock: %s\n' "$*" >&2; exit 1; }

[ "$(omarchy-shell lock isLocked 2>/dev/null)" = "true" ] && fail "the screen is locked; run this from an unlocked session"
[ -d "$HOME/.config/omarchy/plugins/$id" ] || fail "$id isn't installed"

# Take the ♪ icon off the bar.
shell_json="$HOME/.config/omarchy/shell.json"
if [ -f "$shell_json" ]; then
  cp "$shell_json" "$shell_json.bak.$(date +%s)"
  jq --arg id "$id" '.bar.layout |= walk(if type == "array" then map(select(. != $id and (type != "object" or .id != $id))) else . end)' \
    "$shell_json" > "$shell_json.tmp" && mv "$shell_json.tmp" "$shell_json"
fi

# Omarchy backs the plugin folder up and restores its own lock (the clone's source).
omarchy plugin remove "$id" --yes
# `plugin remove` leaves the entry in shell.json's plugin list; drop it.
if [ -f "$shell_json" ]; then
  jq --arg id "$id" '.plugins |= map(select(.id != $id))' "$shell_json" > "$shell_json.tmp" && mv "$shell_json.tmp" "$shell_json"
fi
rm -f "$HOME/.config/omarchy/hooks/post-update.d/pitchlock-stock-lock-check"

omarchy restart shell >/dev/null 2>&1 || true
sleep 3
omarchy-shell lock status >/dev/null 2>&1 && echo "Pitchlock removed; Omarchy's lock screen is back." \
  || echo "Removed. If locking doesn't work, run: omarchy plugin enable omarchy.lock"
