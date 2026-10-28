#!/bin/bash
# Installs the latest Cheese release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/maanit-gupta/Cheese/main/install.sh | bash
#
# To install somewhere else (for example without admin rights):
#   curl -fsSL https://raw.githubusercontent.com/maanit-gupta/Cheese/main/install.sh | CHEESE_INSTALL_DIR=~/Applications bash
#
# What it does, and nothing else:
#   1. downloads Cheese.zip from the latest GitHub release
#   2. checks it against the published SHA-256
#   3. quits a running Cheese, then replaces Cheese.app in /Applications
#   4. removes the quarantine flag (Cheese isn't notarized, so Gatekeeper would otherwise block it)
#   5. opens Cheese
set -euo pipefail

REPO="maanit-gupta/Cheese"
BASE="https://github.com/$REPO/releases/latest/download"
DEST="${CHEESE_INSTALL_DIR:-/Applications}"

say() { printf '\033[1;33m🧀 %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "Cheese runs on macOS only."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 15 )) || fail "Cheese needs macOS 15 or later (this Mac has $(sw_vers -productVersion))."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading the latest Cheese…"
curl -fL --progress-bar "$BASE/Cheese.zip" -o "$tmp/Cheese.zip"
curl -fsSL "$BASE/Cheese.zip.sha256" -o "$tmp/Cheese.zip.sha256"

say "Verifying checksum…"
(cd "$tmp" && shasum -a 256 -c Cheese.zip.sha256 >/dev/null) || fail "Checksum mismatch. The download may be corrupt; try again."

ditto -x -k "$tmp/Cheese.zip" "$tmp/unzipped"
mkdir -p "$DEST" 2>/dev/null || true
[[ -d "$tmp/unzipped/Cheese.app" ]] || fail "The download didn't contain Cheese.app."

if pgrep -x Cheese >/dev/null; then
    say "Quitting the running copy of Cheese…"
    osascript -e 'quit app "Cheese"' >/dev/null 2>&1 || pkill -x Cheese || true
    sleep 1
fi

SUDO=""
[[ -w "$DEST" ]] || SUDO="sudo"
[[ -n "$SUDO" ]] && say "Installing into $DEST needs your password."

say "Installing to $DEST/Cheese.app…"
$SUDO rm -rf "$DEST/Cheese.app"
$SUDO ditto "$tmp/unzipped/Cheese.app" "$DEST/Cheese.app"
$SUDO xattr -dr com.apple.quarantine "$DEST/Cheese.app" 2>/dev/null || true

say "Opening Cheese. Look for the cheese wedge in your menu bar."
open "$DEST/Cheese.app"
