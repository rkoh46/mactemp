#!/bin/bash
# Build MacTemp.app and package it as dist/MacTemp.dmg for the GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(grep -o '<string>[0-9.]*</string>' Info.plist | head -1 | tr -dc '0-9.')"
./build.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE"
cp -R MacTemp.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -rf dist && mkdir -p dist
DMG="dist/MacTemp.dmg"
hdiutil create -volname "MacTemp" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force -s - "$DMG" 2>/dev/null || true
echo ">> built $DMG (v$VERSION)"
shasum -a 256 "$DMG"
