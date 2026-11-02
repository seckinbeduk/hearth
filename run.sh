#!/bin/bash
# Build and run Hearth without opening Xcode.
#   ./run.sh         build (Debug) and launch
#   ./run.sh test    run the unit tests (full log in .build/test.log)
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
mkdir -p .build

# Ad-hoc signing is enough to run locally; release.sh does the real signing.
SIGN=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="")
COMMON=(-project Hearth.xcodeproj -scheme Hearth -destination "platform=macOS,arch=arm64" -derivedDataPath .build/DerivedData)

if [[ "${1:-run}" == "test" ]]; then
  set +e
  xcodebuild "${COMMON[@]}" "${SIGN[@]}" test > .build/test.log 2>&1
  status=$?
  set -e
  grep -E "error:|warning: .*Hearth/|Test .*(passed|failed)|Executed|✔|✘" .build/test.log | tail -60 || true
  [[ $status -eq 0 ]] && echo "✅ Tests passed" || echo "❌ Tests failed (see .build/test.log)"
  exit $status
fi

set +e
xcodebuild "${COMMON[@]}" "${SIGN[@]}" -configuration Debug build > .build/build.log 2>&1
status=$?
set -e
if [[ $status -ne 0 ]]; then
  grep -E "error:" .build/build.log | sort -u | head -40
  echo "❌ Build failed (full log: .build/build.log)"
  exit $status
fi

APP=".build/DerivedData/Build/Products/Debug/Hearth.app"
# Quit the running copy and wait until it's really gone; opening too early fails with -609.
if pkill -x Hearth 2>/dev/null; then
  for _ in $(seq 1 50); do pgrep -x Hearth >/dev/null || break; sleep 0.1; done
  sleep 0.3
fi
open "$APP" || { sleep 1; open "$APP"; }
echo "✅ Hearth is running. Look for the flame in the menu bar."
