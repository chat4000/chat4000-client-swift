#!/usr/bin/env bash
#
# Build a signed, notarized chat4000.dmg for public distribution.
#
# One-time prerequisites:
#
#   1. Developer ID Application cert in your login keychain.
#      Generate at developer.apple.com → Certificates → "+" → "Developer ID Application"
#      under team H45JD827CU. Verify with:
#        security find-identity -v -p codesigning | grep "Developer ID Application"
#
#   2. App-specific password for notarization, stored in the keychain:
#        xcrun notarytool store-credentials chat4000-notary \
#          --apple-id "you@chat4000.com" \
#          --team-id  H45JD827CU \
#          --password "xxxx-xxxx-xxxx-xxxx"
#      (Generate the app-specific password at appleid.apple.com → Sign-in & Security.)
#
#   3. create-dmg from Homebrew:
#        brew install create-dmg
#
# Usage:
#   chat4000/scripts/build-dmg.sh                 # full pipeline (sign + notarize + staple)
#   chat4000/scripts/build-dmg.sh --no-notarize   # skip Apple notarization (fast local test)
#
# Builds the PROD macOS flavor (chat4000macprod → bundle com.neonnode.chat94app,
# the App-Store-free Developer-ID distribution build). Override SCHEME for a
# different flavor.
#
# Environment overrides (rarely needed):
#   TEAM_ID         Apple Developer team. Default: H45JD827CU
#   SCHEME          Xcode scheme.        Default: chat4000macprod
#   NOTARY_PROFILE  Keychain profile.    Default: chat4000-notary

set -euo pipefail

TEAM_ID="${TEAM_ID:-H45JD827CU}"
SCHEME="${SCHEME:-chat4000macprod}"
NOTARY_PROFILE="${NOTARY_PROFILE:-chat4000-notary}"
SKIP_NOTARIZE=0

for arg in "$@"; do
    case "$arg" in
        --no-notarize) SKIP_NOTARIZE=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
PROJECT_PATH="$PROJECT_ROOT/chat4000.xcodeproj"
BUILD_DIR="$PROJECT_ROOT/build/dist"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS_PATH="$BUILD_DIR/ExportOptions.plist"

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "ERROR: create-dmg not found. Install it: brew install create-dmg" >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application.*$TEAM_ID"; then
    echo "ERROR: No 'Developer ID Application' cert for team $TEAM_ID in your keychain." >&2
    echo "Generate one at developer.apple.com under that team and import to login keychain." >&2
    exit 1
fi

if [ "$SKIP_NOTARIZE" -ne 1 ]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "ERROR: Keychain profile '$NOTARY_PROFILE' is missing or invalid." >&2
        echo "Set it up with: xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
        echo "  --apple-id <email> --team-id $TEAM_ID --password <app-specific-password>" >&2
        exit 1
    fi
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :MARKETING_VERSION' /dev/stdin <<<"$(/usr/bin/xcodebuild -showBuildSettings -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration Release 2>/dev/null | awk '/MARKETING_VERSION = / { print $3; exit }' | xargs -I{} echo '<plist version="1.0"><dict><key>MARKETING_VERSION</key><string>{}</string></dict></plist>')" 2>/dev/null || true)"
if [ -z "${VERSION:-}" ]; then
    VERSION="$(xcodebuild -showBuildSettings -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration Release 2>/dev/null | awk -F'= ' '/MARKETING_VERSION / { print $2; exit }')"
fi
VERSION="${VERSION:-0.0.0}"

# Optional: build a specific version without editing project.yml (e.g. cutting a
# 1.1.1 update DMG while the project baseline stays 1.1.0). Forces the archived
# app's MARKETING_VERSION too, so the DMG, its name, and CFBundleShortVersionString
# all agree.
if [ -n "${VERSION_OVERRIDE:-}" ]; then
    VERSION="$VERSION_OVERRIDE"
fi

echo "==> Archiving $SCHEME ($VERSION) for Release..."
xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    MARKETING_VERSION="$VERSION" \
    | xcbeautify 2>/dev/null || true

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "ERROR: Archive failed — $ARCHIVE_PATH not found." >&2
    exit 1
fi

cat > "$EXPORT_OPTIONS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
EOF

echo "==> Exporting Developer ID-signed .app..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH" \
    -allowProvisioningUpdates

APP_PATH="$EXPORT_DIR/chat4000.app"
if [ ! -d "$APP_PATH" ]; then
    APP_PATH="$(find "$EXPORT_DIR" -maxdepth 2 -name '*.app' -type d | head -1)"
fi
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Couldn't find exported .app under $EXPORT_DIR" >&2
    exit 1
fi

DMG_NAME="chat4000-$VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "==> Building $DMG_NAME..."
DMG_STAGING="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGING"' EXIT
cp -R "$APP_PATH" "$DMG_STAGING/"

create-dmg \
    --volname "chat4000 $VERSION" \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$(basename "$APP_PATH")" 150 200 \
    --hide-extension "$(basename "$APP_PATH")" \
    --app-drop-link 450 200 \
    "$DMG_PATH" \
    "$DMG_STAGING"

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo ""
    echo "✅ Built (UNSIGNED for distribution): $DMG_PATH"
    echo "   Run without --no-notarize for a notarized DMG you can ship."
    exit 0
fi

echo "==> Submitting to Apple notary service (this can take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo ""
echo "✅ Notarized DMG ready to ship: $DMG_PATH"
