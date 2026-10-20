#!/usr/bin/env bash
# Build, sign, notarize, staple, and package MarinaUI for distribution.
# Produces MarinaUI.zip and MarinaUI.dmg next to the bundled .app.
set -euo pipefail

IDENTITY="${MARINA_SIGN_IDENTITY:-Developer ID Application: Baptiste Collard (PZARL6555S)}"
NOTARY_PROFILE="${MARINA_NOTARY_PROFILE:-marina-notary}"

cd "$(dirname "$0")/.."
OUT_DIR=".build/bundler/apps/MarinaUI"
APP="$OUT_DIR/MarinaUI.app"
ZIP="$OUT_DIR/MarinaUI.zip"
DMG="$OUT_DIR/MarinaUI.dmg"

step() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }

step "Bundle (release) with swift-bundler"
swift-bundler bundle -c release --codesign --identity "$IDENTITY"

step "Re-sign with hardened runtime + secure timestamp"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

step "Package zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

step "Notarize app (zip)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

step "Staple ticket to .app"
xcrun stapler staple "$APP"

step "Refresh zip with stapled .app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

step "Build DMG"
rm -f "$DMG"
create-dmg \
  --volname "Marina" \
  --window-size 540 360 \
  --icon-size 96 \
  --icon "MarinaUI.app" 140 180 \
  --app-drop-link 400 180 \
  --hide-extension "MarinaUI.app" \
  --no-internet-enable \
  "$DMG" \
  "$APP"

step "Sign DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

step "Notarize DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

step "Staple ticket to DMG"
xcrun stapler staple "$DMG"

step "Gatekeeper verification"
spctl -a -vv "$APP"
spctl -a -t open --context context:primary-signature -vv "$DMG"

step "Done"
ls -lh "$ZIP" "$DMG"
shasum -a 256 "$ZIP" "$DMG"

VERSION="$(awk -F'"' '/^version[[:space:]]*=/ { print $2; exit }' Bundler.toml)"
DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

cat <<EOF

──────────── cask block (paste into bcollard/homebrew-marina/Casks/marina-ui.rb) ────────────
cask "marina-ui" do
  version "${VERSION}"
  sha256 "${DMG_SHA}"

  url "https://github.com/bcollard/marina-ui/releases/download/v#{version}/MarinaUI.dmg"
  name "Marina"
  desc "macOS companion app for the marina CLI and the kind clusters it manages"
  homepage "https://github.com/bcollard/marina-ui"

  depends_on macos: :sonoma

  app "MarinaUI.app"

  zap trash: [
    "~/Library/Preferences/dev.bcollard.MarinaUI.plist",
  ]
end
─────────────────────────────────────────────────────────────────────────────────────────────
EOF
