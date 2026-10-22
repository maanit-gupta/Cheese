#!/bin/zsh
# Fails if the Release Cheese.app grows more than 2 MB past the recorded baseline, so new features
# can't quietly bloat the app. Run by `make test`.
#
#   scripts/check-size.sh
#
# The baseline (scripts/size-baseline.txt) is the Release bundle of v3.5 (commit ca96744), in bytes.
# It was the v2.5 bundle (commit 5976986, 10653602 bytes) until v3 and v3.5 used up that budget.
# Raise it only on purpose, with a note in the commit message.
set -euo pipefail

cd "${0:A:h}/.."

DERIVED=build/SizeCheck
APP="$DERIVED/Build/Products/Release/Cheese.app"
BUDGET=$((2 * 1024 * 1024))
BASELINE=$(tr -dc '0-9' < scripts/size-baseline.txt)

xcodebuild -project Cheese.xcodeproj -scheme Cheese -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" build > "$DERIVED.log" 2>&1 \
    || { tail -30 "$DERIVED.log"; echo "Release build for the size check failed (log: $DERIVED.log)"; exit 1; }

SIZE=$(find "$APP" -type f -print0 | xargs -0 stat -f%z | awk '{s+=$1} END {print s}')
LIMIT=$((BASELINE + BUDGET))
GROWTH=$((SIZE - BASELINE))

printf 'App size: %d bytes (baseline %d, %+d bytes, limit %d)\n' "$SIZE" "$BASELINE" "$GROWTH" "$LIMIT"
if (( SIZE > LIMIT )); then
    echo "error: Cheese.app is over its size budget by $((SIZE - LIMIT)) bytes."
    exit 1
fi
