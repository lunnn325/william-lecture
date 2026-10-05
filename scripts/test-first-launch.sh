#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
runtime=$(xcrun simctl list runtimes available -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-26-")]
if not runtimes:
    raise SystemExit("An available iOS 26 simulator runtime is required")
print(max(runtimes, key=lambda r: tuple(int(p) for p in r["version"].split(".")))["identifier"])
')
device=$(xcrun simctl create "WL-FreshInstall-${GITHUB_RUN_ID:-local}" com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro "$runtime")
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; xcrun simctl delete "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcodebuild -project WilliamLecture.xcodeproj -scheme WilliamLecture \
  -configuration Debug -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath build/simulator -resultBundlePath build/FirstLaunch.xcresult \
  -only-testing:WilliamLectureUITests CODE_SIGNING_ALLOWED=NO test | tee build/first-launch.log
