#!/bin/bash
# Builds build/Hangar.app and signs it. With --install it copies the app to /Applications and
# opens it. Set HANGAR_SIGN_IDENTITY to a codesigning identity to sign with it; the default is
# an ad-hoc signature, which is enough to run the app on the machine that built it.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${HANGAR_SIGN_IDENTITY:--}"
swift build -c release --product Hangar
OUT="$(swift build -c release --show-bin-path)"
BIN="$OUT/Hangar"
APP=build/Hangar.app

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/Hangar"
# The app's strings go in the app's own Resources, where SwiftUI looks for them; HangarCore finds its
# bundle there by name, and the app crashes at launch without it.
cp -R "$OUT/Hangar_Hangar.bundle/Contents/Resources/"*.lproj "$APP/Contents/Resources/"
cp -R "$OUT/Hangar_HangarCore.bundle" "$APP/Contents/Resources/"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "ok: $APP"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app "Hangar"' 2>/dev/null || true
    rm -rf /Applications/Hangar.app
    cp -R "$APP" /Applications/
    open /Applications/Hangar.app
    echo "installed and opened"
fi
