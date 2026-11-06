#!/bin/bash
# Release build: Developer ID signed (cloud-managed certificate), notarized and stapled.
#
#   VERSION=0.1.0 ./scripts/release.sh
#
# Needs:
#   - Xcode signed in (Settings → Apple Accounts) with an account that has
#     "Access to Cloud Managed Developer ID Certificate". Team API keys don't get it.
#   - An App Store Connect API key for notarytool, in these variables:
#     APPSTORECONNECT_PRIVATE_KEY_PATH, APPSTORECONNECT_KEY_ID, APPSTORECONNECT_ISSUER_ID
#
# Output: build/release/$VERSION/Mando.app (stapled) and Mando.zip; other versions are left alone
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
: "${APPSTORECONNECT_PRIVATE_KEY_PATH:?set the App Store Connect API key variables (see header)}"
: "${APPSTORECONNECT_KEY_ID:?}" "${APPSTORECONNECT_ISSUER_ID:?}"

OUT="build/release/$VERSION"
ARCHIVE="$OUT/Mando.xcarchive"
rm -rf "$OUT"

VERSION="$VERSION" ./scripts/build.sh

# No Xcode project: wrap the build in an .xcarchive so -exportArchive can sign it
# with the cloud-managed Developer ID (codesign can't reach that private key).
echo "==> Archive"
mkdir -p "$ARCHIVE/Products/Applications"
cp -R build/Mando.app "$ARCHIVE/Products/Applications/"
cat > "$ARCHIVE/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ApplicationProperties</key>
	<dict>
		<key>ApplicationPath</key><string>Applications/Mando.app</string>
		<key>Architectures</key><array><string>arm64</string><string>x86_64</string></array>
		<key>CFBundleIdentifier</key><string>com.aliasviejo.mando</string>
		<key>CFBundleShortVersionString</key><string>$VERSION</string>
		<key>CFBundleVersion</key><string>$VERSION</string>
	</dict>
	<key>ArchiveVersion</key><integer>2</integer>
	<key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
	<key>Name</key><string>Mando</string>
	<key>SchemeName</key><string>Mando</string>
</dict>
</plist>
EOF

echo "==> Export (Developer ID)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates -quiet

echo "==> Notarize"
ZIP="$OUT/Mando.zip"   # fixed name: releases/latest/download/Mando.zip always works
ditto -c -k --keepParent "$OUT/Mando.app" "$ZIP"
xcrun notarytool submit "$ZIP" --wait \
  --key "$APPSTORECONNECT_PRIVATE_KEY_PATH" \
  --key-id "$APPSTORECONNECT_KEY_ID" \
  --issuer "$APPSTORECONNECT_ISSUER_ID" | tee "$OUT/notary.log"
grep -q "status: Accepted" "$OUT/notary.log" || {
  echo "Notarization failed. Details: xcrun notarytool log <id> --key … --key-id … --issuer …" >&2
  exit 1
}

echo "==> Staple and verify"
xcrun stapler staple "$OUT/Mando.app"
codesign --verify --deep --strict "$OUT/Mando.app"
spctl -a -t exec -vv "$OUT/Mando.app" 2>&1 | tee /dev/stderr | grep -q "source=Notarized Developer ID"
rm "$ZIP" && ditto -c -k --keepParent "$OUT/Mando.app" "$ZIP"   # zip again, now with the ticket

echo "==> Done: $ZIP"
