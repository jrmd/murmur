#!/bin/bash
# Quick local signed build: generates the Xcode project, does a plain Release build with
# automatic signing and copies Murmur.app to build/. Nothing is archived, notarized, stapled
# or zipped, and no appcast is generated; use Packaging/release.sh for a real release.
# Set DEVELOPMENT_TEAM=<your team id> to sign with a different team.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
TEAM="${DEVELOPMENT_TEAM:-DQG6RVCCWV}"

xcodegen generate --spec "$ROOT/project.yml"
xcodebuild \
    -project "$ROOT/Murmur.xcodeproj" \
    -scheme Murmur \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM" \
    clean \
    build

mkdir -p "$ROOT/build"
python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$ROOT/build/Murmur.app"
ditto "$DERIVED/Build/Products/Release/Murmur.app" "$ROOT/build/Murmur.app"
echo "Created signed app: $ROOT/build/Murmur.app"
