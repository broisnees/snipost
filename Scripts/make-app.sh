#!/bin/bash
# Builds Snipost in release mode and assembles dist/Snipost.app (ad-hoc signed).
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="dist/Snipost.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Snipost "$APP/Contents/MacOS/Snipost"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Embedded Google OAuth client (developer-created, gitignored) — with it in
# place, users only ever see the "Connect Google Drive" button.
[ -f Resources/DriveClient.plist ] && cp Resources/DriveClient.plist "$APP/Contents/Resources/DriveClient.plist"

# Prefer a real signing identity: it stays stable across rebuilds, so macOS
# keeps the Screen Recording permission. Ad-hoc (-) changes every build and
# resets TCC each time.
# Order: $SNIPOST_SIGN_IDENTITY, an Apple Development cert, then any valid
# local code-signing identity (a self-signed cert is stable enough for TCC).
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
IDENTITY="${SNIPOST_SIGN_IDENTITY:-}"
[ -z "$IDENTITY" ] && IDENTITY=$(echo "$IDENTITIES" | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)
[ -z "$IDENTITY" ] && IDENTITY=$(echo "$IDENTITIES" | grep -o '"[^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "No Apple Development identity found; ad-hoc signing"
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
echo "Run with: open $APP"
