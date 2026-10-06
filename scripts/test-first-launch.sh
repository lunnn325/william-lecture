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
tablet_type=$(xcrun simctl list devicetypes -j | python3 -c '
import json,sys
devices=[d for d in json.load(sys.stdin)["devicetypes"] if "iPad Pro" in d["name"] and "13" in d["name"] and "M4" in d["name"]]
if not devices: raise SystemExit("M4 iPad Pro simulator device type is required")
print(devices[0]["identifier"])
')
devices=()
cleanup() { for device in "${devices[@]}"; do xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; xcrun simctl delete "$device" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT
run_flow() {
  local label="$1" type="$2" device result status=0
  device=$(xcrun simctl create "WL-$label-${GITHUB_RUN_ID:-local}" "$type" "$runtime")
  devices+=("$device")
  xcrun simctl boot "$device"; xcrun simctl bootstatus "$device" -b
  result="build/$label.xcresult"
  local filter="-only-testing:WilliamLectureUITests"
  if [ "$label" = "TabletFlow" ]; then filter="-only-testing:WilliamLectureUITests/V1FlowTests"; fi
  xcodebuild -project WilliamLecture.xcodeproj -scheme WilliamLecture \
    -configuration Debug -destination "platform=iOS Simulator,id=$device" \
    -derivedDataPath build/simulator -resultBundlePath "$result" \
    "$filter" CODE_SIGNING_ALLOWED=NO test | tee "build/$label.log" || status=$?
  mkdir -p "build/screenshots/$label"
  xcrun xcresulttool export attachments --path "$result" --output-path "build/screenshots/$label" || true
  xcrun simctl shutdown "$device"
  return "$status"
}
run_flow FirstLaunch com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro
run_flow TabletFlow "$tablet_type"
