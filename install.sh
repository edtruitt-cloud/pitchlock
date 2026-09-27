#!/bin/bash
# Install pitchlock: a sing-the-chord lock screen for Omarchy.
#
#   ./install.sh               full install (or upgrade)
#   ./install.sh --force       install even if Omarchy's lock has changed since this
#                              version of pitchlock was made (review the diff first)
#   ./install.sh --files-only  just copy the game files into an existing install
#                              (development; restart the shell yourself while unlocked)
#
# Pitchlock replaces the lock screen, so it's installed as a clone of Omarchy's own lock
# plugin (`omarchy plugin clone omarchy.lock`): that keeps it trusted for password checks,
# and `./uninstall.sh` (or `omarchy plugin remove <user>.lock`) hands the lock back.

set -euo pipefail

src="$(dirname "$(readlink -f "$0")")"
user="${USER:-$(id -un)}"
id="$user.lock"
plugins="$HOME/.config/omarchy/plugins"
dst="$plugins/$id"
stock="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins/lock"
data="$HOME/.local/share/pitchlock"

force=0
files_only=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --files-only) files_only=1 ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf 'pitchlock: %s\n' "$*" >&2; exit 1; }

# Build the pitch detector if it's missing or older than its source.
build_pitchd() {
  if ! [ "$src/pitchd" -nt "$src/pitchd.c" ]; then
    command -v gcc >/dev/null || fail "gcc is needed to build the pitch detector (omarchy pkg add gcc)"
    gcc -O2 -Wall -o "$src/pitchd" "$src/pitchd.c" -lm
  fi
}

# Copy the game into the plugin, with the plugin id set for this user.
copy_files() {
  cp "$src"/Pitch*.qml "$src/pitchstats.js" "$src/pitchcrypto.js" "$src/shell.qml" "$src/pitchlock" "$dst/"
  cp "$src/lock-Service.qml" "$dst/Service.qml"
  sed -i "s/ertiv\.lock/$id/g" "$dst/Service.qml" "$dst/PitchBarWidget.qml"
  # The detector may be running (the lock's mic), so swap it in by rename.
  if ! cmp -s "$src/pitchd" "$dst/pitchd"; then
    cp "$src/pitchd" "$dst/.pitchd.new" && mv -f "$dst/.pitchd.new" "$dst/pitchd"
  fi
  chmod +x "$dst/pitchlock" "$dst/pitchd"
}

build_pitchd

if (( files_only )); then
  [ -f "$dst/Service.qml" ] || fail "$dst isn't installed yet: run ./install.sh"
  copy_files
  echo "installed files into $dst"
  exit 0
fi

# ── checks ─────────────────────────────────────────────────────────────────
command -v omarchy >/dev/null || fail "this is for Omarchy (omarchy command not found)"
for cmd in qs jq pw-record pw-cat; do
  command -v "$cmd" >/dev/null || fail "missing $cmd"
done
[ -d "$stock" ] || fail "Omarchy's lock plugin wasn't found at $stock"
if [ "$(omarchy-shell lock isLocked 2>/dev/null)" = "true" ]; then
  fail "the screen is locked; run this from an unlocked session"
fi

# Pitchlock's Service.qml is Omarchy's lock service plus the game. If Omarchy's lock
# has changed since, installing would silently undo those changes.
if ! diff -rq "$src/stock-lock-baseline" "$stock" >/dev/null 2>&1; then
  if (( force )); then
    say "Warning: Omarchy's lock differs from the one pitchlock was built on (installing anyway)."
  else
    echo "Omarchy's lock screen has changed since this version of pitchlock was made:"
    diff -rq "$src/stock-lock-baseline" "$stock" || true
    fail "installing would undo those changes. Review with: diff -r $src/stock-lock-baseline $stock  (then use --force)"
  fi
fi

# ── install ────────────────────────────────────────────────────────────────
mkdir -p "$data"
if [ -d "$dst" ]; then
  if grep -q "pickPitchRoot" "$dst/Service.qml" 2>/dev/null; then
    say "Upgrading pitchlock in $dst"
  else
    backup="$data/backup-$id-$(date +%Y%m%d%H%M%S)"
    cp -a "$dst" "$backup"
    say "Your existing lock clone was backed up to $backup"
  fi
else
  say "Cloning Omarchy's lock plugin as $id"
  omarchy plugin clone omarchy.lock >/dev/null
  [ -d "$dst" ] || fail "cloning omarchy.lock didn't create $dst"
fi

copy_files

# Register the settings panel as the plugin's bar widget.
jq '.kinds = (((.kinds // []) + ["service", "bar-widget"]) | unique)
    | .entryPoints.barWidget = "PitchBarWidget.qml"
    | .name = "Pitchlock"
    | .description = "Sing-a-chord lock screen (a clone of the Omarchy lock) with a settings panel."
    | .barWidget = {displayName: "Pitchlock", description: "Pitchlock lock screen settings",
                    category: "System", defaultSection: "right", allowMultiple: false}' \
  "$dst/manifest.json" > "$dst/manifest.json.tmp"
mv "$dst/manifest.json.tmp" "$dst/manifest.json"
omarchy plugin validate "$dst" >/dev/null || fail "the installed plugin didn't validate"

# Put the ♪ settings icon on the right of the bar.
shell_json="$HOME/.config/omarchy/shell.json"
if [ -f "$shell_json" ] && jq -e '.bar.layout.right | type == "array"' "$shell_json" >/dev/null 2>&1; then
  if ! jq -e --arg id "$id" '.bar.layout | tostring | contains("\"" + $id + "\"")' "$shell_json" >/dev/null; then
    cp "$shell_json" "$shell_json.bak.$(date +%s)"
    jq --arg id "$id" '.bar.layout.right = [{"id": $id}] + .bar.layout.right' "$shell_json" > "$shell_json.tmp"
    mv "$shell_json.tmp" "$shell_json"
    say "Added the ♪ pitchlock icon to your bar"
  fi
else
  echo "Add the settings icon to your bar with: omarchy bar put $id"
fi

# After each Omarchy update, warn if the stock lock changed (pitchlock is built on it).
rm -rf "$data/stock-lock-baseline"
cp -r "$src/stock-lock-baseline" "$data/stock-lock-baseline"
mkdir -p "$HOME/.config/omarchy/hooks/post-update.d"
install -m 755 "$src/stock-lock-check" "$HOME/.config/omarchy/hooks/post-update.d/pitchlock-stock-lock-check"

say "Restarting the Omarchy shell"
omarchy restart shell >/dev/null 2>&1 || true
sleep 3
if omarchy-shell lock status >/dev/null 2>&1; then
  say "Pitchlock is installed."
  cat <<EOF

Next:
  • Click the ♪ icon on the bar → "Measure my voice" to fit the chords to your range.
  • Press "Preview" there to see the lock without locking.
  • Your password always unlocks it. Set a bypass word in the panel if you want one.
  • Undo everything with: $src/uninstall.sh
EOF
else
  fail "the lock service didn't come back after the restart. Check: qs log -i \$(qs list --all | awk '/^Instance/{print \$2}' | tr -d :) | grep -i lock"
fi
