#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"

xcodegen generate --spec "$ROOT/project.yml"
xcodebuild \
    -project "$ROOT/Murmur.xcodeproj" \
    -scheme Murmur \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM=DQG6RVCCWV \
    clean \
    build

mkdir -p "$ROOT/build"
python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$ROOT/build/Murmur.app"
ditto "$DERIVED/Build/Products/Release/Murmur.app" "$ROOT/build/Murmur.app"
echo "Created signed app: $ROOT/build/Murmur.app"
