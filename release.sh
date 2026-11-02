#!/bin/bash
# Build a DMG you can send to someone.
#
#   ./release.sh
#
# With a "Developer ID Application" certificate in your keychain, the app is signed,
# notarized and stapled: it opens with a double-click on any Mac.
# Without one, you still get a DMG, but the first open needs:
#   System Settings → Privacy & Security → "Open Anyway".
#
# One-time notarization setup (needs an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials hearth-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE="${NOTARY_PROFILE:-hearth-notary}"
command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen"; exit 1; }
xcodegen generate --quiet

VERSION=$(grep -E '^\s+MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
OUT=".build/release"
rm -rf "$OUT" && mkdir -p "$OUT"

IDENTITY_LINE=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
if [[ -n "$IDENTITY_LINE" ]]; then
  IDENTITY=$(echo "$IDENTITY_LINE" | sed -E 's/.*"(.*)"/\1/')
  TEAM=$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')
  echo "🔏 Signing with: $IDENTITY"
  SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" OTHER_CODE_SIGN_FLAGS="--timestamp")
else
  echo "⚠️  No Developer ID certificate found. Building an ad-hoc signed DMG."
  SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="")
fi

echo "🛠  Building Hearth $VERSION (Release)…"
set +e
xcodebuild -project Hearth.xcodeproj -scheme Hearth -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath .build/DerivedData \
  -archivePath "$OUT/Hearth.xcarchive" "${SIGN[@]}" archive > "$OUT/build.log" 2>&1
status=$?
set -e
if [[ $status -ne 0 ]]; then
  grep -E "error:" "$OUT/build.log" | sort -u | head -40
  echo "❌ Build failed (full log: $OUT/build.log)"
  exit $status
fi

APP="$OUT/Hearth.xcarchive/Products/Applications/Hearth.app"
codesign --verify --deep --strict "$APP" && echo "✅ Signature OK"

STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Hearth-$VERSION.dmg"
hdiutil create -volname "Hearth" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
echo "📦 $DMG"

if [[ -n "$IDENTITY_LINE" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1; then
    echo "📮 Notarizing (usually 1–5 minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG" && echo "✅ Notarized. Send $DMG to anyone."
  else
    echo "ℹ️  Signed but not notarized. Set up once with:"
    echo "   xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOU@EXAMPLE.COM --team-id $TEAM"
    echo "   then run ./release.sh again."
  fi
else
  echo "ℹ️  Ad-hoc build. On the other Mac: open the DMG, drag Hearth to Applications, open it once,"
  echo "   then System Settings → Privacy & Security → Open Anyway."
fi

# Copy to a visible folder and show it in Finder.
mkdir -p dist
FINAL="dist/Hearth-$VERSION.dmg"
cp "$DMG" "$FINAL"
echo "📂 $(pwd)/$FINAL"
open -R "$FINAL" 2>/dev/null || open dist
