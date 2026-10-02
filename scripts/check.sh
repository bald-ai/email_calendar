#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
swift test --parallel
if [[ "${OSTYPE:-}" == darwin* ]]; then
    xcodebuild -project EmailCalendar.xcodeproj -scheme EmailCalendar \
        -configuration Debug -destination 'platform=macOS' \
        CODE_SIGNING_ALLOWED=NO build
fi
