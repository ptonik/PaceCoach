#!/bin/bash
# Builds the zip to hand to someone: the installer, PaceCoach and PaceCheck.
#   tools/make_release.sh            # writes dist/PaceCoach-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(sed -n "s/^VERSION = //p" manifest.ini | tr -d '\r')"
OUT="dist/PaceCoach-$VERSION"
rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT/PaceCoach"
cp manifest.ini icon.png PaceCoach.lua PaceCoach-main.lua README.md LICENSE "$OUT/PaceCoach/"
cp -R src sounds "$OUT/PaceCoach/"
cp -R extras/PaceCheck "$OUT/PaceCheck"
cp install/install.ps1 install/*.bat "$OUT/"
printf '%s\r\n' \
  "PaceCoach $VERSION for Assetto Corsa (needs Content Manager and Custom Shaders Patch)" \
  "" \
  "EASY WAY" \
  "  1. Close the game." \
  "  2. Double-click  Install PaceCoach.bat" \
  "     It finds Assetto Corsa, moves older PaceCoach folders out of the way and copies this one in." \
  "" \
  "BY HAND" \
  "  1. Delete any PaceCoach folders already in  assettocorsa\\apps\\lua" \
  "  2. Copy the PaceCoach folder and the PaceCheck folder from here into  assettocorsa\\apps\\lua" \
  "     You must end up with  assettocorsa\\apps\\lua\\PaceCoach\\manifest.ini" \
  "" \
  "THEN" \
  "  Start a session, move the mouse to the right edge of the screen, click PaceCoach." \
  "  If its window stays empty, open PaceCheck from the same bar and send a screenshot of it." \
  "  PaceCoach\\README.md explains everything else." \
  > "$OUT/READ ME FIRST.txt"
find "$OUT" -name '.DS_Store' -delete
(cd dist && zip -qr -X "PaceCoach-$VERSION.zip" "PaceCoach-$VERSION")
echo "dist/PaceCoach-$VERSION.zip: $(du -h "dist/PaceCoach-$VERSION.zip" | cut -f1)"
