#!/bin/bash
# Build the Debug app and launch it. It runs as "Murmur (dev)" (com.bonusobjective.murmur.dev),
# separate from the released Murmur: its own permissions, settings and dictionary, and no auto-updates.
# Signs with the team in project.yml by default. Set DEVELOPMENT_TEAM=<your team id> to use yours,
# or MURMUR_ADHOC=1 to sign ad hoc (no developer account; permissions must be re-granted after each rebuild).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData-dev"
SIGNING=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then SIGNING=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
elif [[ "${MURMUR_ADHOC:-}" == 1 ]]; then SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=); fi
mkdir -p "$ROOT/build"
xcodegen generate --spec "$ROOT/project.yml" >/dev/null
xcodebuild -project "$ROOT/Murmur.xcodeproj" -scheme Murmur -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" ${SIGNING[@]+"${SIGNING[@]}"} build >"$ROOT/build/dev-build.log" 2>&1 \
    || { tail -30 "$ROOT/build/dev-build.log"; exit 1; }
APP="$DERIVED/Build/Products/Debug/Murmur (dev).app"
# Quit a running dev build first; the released Murmur has a different process name and is left alone.
pkill -x 'Murmur \(dev\)' 2>/dev/null || true
open "$APP"
echo "Launched $APP"
