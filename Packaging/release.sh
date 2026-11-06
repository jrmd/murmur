#!/bin/bash
# Build and notarize a release locally; pass --publish to upload it to R2.
# Overridable from the environment: DEVELOPMENT_TEAM, DEVELOPER_ID (signing identity),
# NOTARY_PROFILE, R2_BUCKET and RELEASE_BASE_URL. The defaults are the official release values.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUCKET="${R2_BUCKET:-murmur-releases}"
BASE_URL="${RELEASE_BASE_URL:-https://updates.murmur.bonusobjective.com}"
PROFILE="${NOTARY_PROFILE:-murmur}"
TEAM="${DEVELOPMENT_TEAM:-DQG6RVCCWV}"
IDENTITY="${DEVELOPER_ID:-Developer ID Application: Jerome Duncan (DQG6RVCCWV)}"
PUBLISH=false
if [[ ${1:-} == --publish ]]; then PUBLISH=true; shift; fi
if [[ $# -ne 0 ]]; then echo 'Usage: Packaging/release.sh [--publish]' >&2; exit 1; fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/project/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$ROOT/project/Info.plist")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || { echo 'Set a numeric version and build in project/Info.plist.' >&2; exit 1; }
OUT="$ROOT/build/releases/$VERSION-$BUILD"
[[ ! -e "$OUT" ]] || { echo "Release directory already exists: $OUT" >&2; exit 1; }
command -v xcodegen >/dev/null
command -v wrangler >/dev/null
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null
mkdir -p "$OUT"
ARCHIVE="$OUT/Murmur.xcarchive"
APP="$ARCHIVE/Products/Applications/Murmur.app"
ZIP="Murmur-$VERSION-$BUILD.zip"
xcodegen generate --spec "$ROOT/project.yml"
xcodebuild -project "$ROOT/Murmur.xcodeproj" -scheme Murmur -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$ROOT/build/DerivedData" \
    -archivePath "$ARCHIVE" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM" archive
# The archive contains Sparkle's ad-hoc signed helpers. Sign nested code inside-out
# before signing the framework and host app for notarization.
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/B"
for XPC in "$SPARKLE_VERSION"/XPCServices/*.xpc; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$XPC"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_VERSION/Updater.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_VERSION/Autoupdate"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_FRAMEWORK"
codesign --force --options runtime --timestamp --entitlements "$ROOT/Packaging/Murmur.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/notary.zip"
xcrun notarytool submit "$OUT/notary.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$OUT/notary-result.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("Notarization:", r.get("status"), "submission", r.get("id")); sys.exit(0 if r.get("status") == "Accepted" else 1)' "$OUT/notary-result.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
mkdir "$OUT/feed"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/feed/$ZIP"
rm "$OUT/notary.zip"
SPARKLE="$ROOT/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
# Fetch the existing feed when present, and fail on network/server errors.
HTTP_CODE=$(curl -sS -L -o "$OUT/existing-appcast.xml" -w '%{http_code}' "$BASE_URL/appcast.xml")
case "$HTTP_CODE" in
    200) cp "$OUT/existing-appcast.xml" "$OUT/feed/appcast.xml" ;;
    404) rm "$OUT/existing-appcast.xml" ;;
    *) echo "Cannot retrieve current appcast (HTTP $HTTP_CODE)" >&2; exit 1 ;;
esac
if [[ -f "$OUT/feed/appcast.xml" ]] && /usr/bin/grep -Eq "<sparkle:version>$BUILD</sparkle:version>" "$OUT/feed/appcast.xml"; then
    echo "Build $BUILD is already in the appcast; increment CFBundleVersion." >&2; exit 1
fi
"$SPARKLE" --account murmur --download-url-prefix "$BASE_URL/" --maximum-versions 0 --maximum-deltas 0 "$OUT/feed"
echo "Release prepared in $OUT/feed"
echo "Versioned archive: $BASE_URL/$ZIP"
if $PUBLISH; then
    # Use a separate cache key: checking a missing archive can otherwise cache
    # a 404 at the URL that Sparkle will subsequently use.
    HTTP_CODE=$(curl -sS -L -o /dev/null -w '%{http_code}' "$BASE_URL/$ZIP?preflight=$(date +%s)-$$")
    [[ "$HTTP_CODE" == 404 ]] || { echo "Refusing to overwrite release archive (HTTP $HTTP_CODE)." >&2; exit 1; }
    wrangler r2 object put "$BUCKET/$ZIP" --remote --file "$OUT/feed/$ZIP" --content-type application/zip --cache-control 'public, max-age=31536000, immutable'
    wrangler r2 object put "$BUCKET/Murmur-latest.zip" --remote --file "$OUT/feed/$ZIP" --content-type application/zip --cache-control 'no-cache, max-age=0, must-revalidate'
    wrangler r2 object put "$BUCKET/appcast.xml" --remote --file "$OUT/feed/appcast.xml" --content-type 'application/xml; charset=utf-8' --cache-control 'no-cache, max-age=0, must-revalidate'
    echo "Published $BASE_URL/appcast.xml"
fi
