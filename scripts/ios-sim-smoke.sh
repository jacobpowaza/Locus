#!/usr/bin/env bash
# macOS only. Builds Locus for the iOS Simulator, installs it, launches it
# with the DEBUG-only `-LocusDemoRun` argument (starts a short Scheduled Run),
# and collects screenshots, the app's log, and crash reports into outputs/sim.
#
# In the Simulator, spoofing goes through the stub in LocationEngine.swift
# (libidevice_ffi.a has no simulator slice and there is no device tunnel), so
# this proves the app + Scheduled Runs engine run on iOS — not that locationd
# accepted coordinates. That needs a physical iPhone (docs/TESTING.md).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${OUT:-outputs/sim}"
DERIVED="${DERIVED:-build/DerivedData}"
BUNDLE_ID="com.chrismack.locus"
mkdir -p "$OUT"

[ -d Locus.xcodeproj ] || xcodegen generate

DEVICE_ID="${DEVICE_ID:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
ios = sorted((k for k in d if "iOS" in k), key=lambda k: [int(x) for x in k.split("iOS-")[-1].split("-")])
for k in reversed(ios):
    for dev in d[k]:
        if dev["name"].startswith("iPhone"):
            print(dev["udid"]); sys.exit(0)
sys.exit("no iPhone simulator found")
')}"
echo "Simulator: $DEVICE_ID"

echo "== Build"
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Debug \
  -sdk iphonesimulator -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$OUT/build.xcresult" \
  ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build > "$OUT/xcodebuild.log" 2>&1 \
  || { tail -80 "$OUT/xcodebuild.log"; exit 1; }
grep -E "warning: |error: " "$OUT/xcodebuild.log" | sort -u > "$OUT/diagnostics.txt" || true
echo "$(grep -c 'warning: ' "$OUT/diagnostics.txt" || true) unique compiler warnings (see diagnostics.txt)"

APP="$DERIVED/Build/Products/Debug-iphonesimulator/Locus.app"
# Universal (arm64 + x86_64) Simulator build, zipped for Appetize.io or
# `xcrun simctl install` on any Mac.
lipo -info "$APP/Locus" || true
ditto -c -k --sequesterRsrc --keepParent "$APP" outputs/Locus-simulator.zip
echo "Simulator app: outputs/Locus-simulator.zip"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" "$APP"
xcrun simctl privacy "$DEVICE_ID" grant location-always "$BUNDLE_ID" 2>/dev/null \
  || xcrun simctl privacy "$DEVICE_ID" grant location "$BUNDLE_ID" || true
xcrun simctl privacy "$DEVICE_ID" grant notifications "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl location "$DEVICE_ID" set 37.3349,-122.0090 || true
# Skip the first-run walkthrough so the map (and Scheduled Runs) appear.
xcrun simctl spawn "$DEVICE_ID" defaults write "$BUNDLE_ID" locus.setupComplete -bool YES

xcrun simctl spawn "$DEVICE_ID" log stream --style compact --level debug \
  --predicate 'process == "Locus"' > "$OUT/app.log" 2>&1 &
LOG_PID=$!
trap 'kill $LOG_PID 2>/dev/null || true' EXIT

echo "== Launch (cold)"
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" -LocusDemoRun
# CI simulators can be slow to launch, so wait for log lines, not fixed sleeps.
wait_for() { # pattern timeout-seconds
  local t=0
  until grep -q "$1" "$OUT/app.log"; do
    sleep 2; t=$((t + 2))
    [ "$t" -ge "$2" ] && { echo "timed out after ${2}s waiting for: $1"; return 1; }
  done
}
wait_for "\[Locus\]\[Run\]\[info\] Driving to Demo End" 180 || true
sleep 4
xcrun simctl io "$DEVICE_ID" screenshot "$OUT/01-active-run.png"
sleep 15
xcrun simctl io "$DEVICE_ID" screenshot "$OUT/02-driving.png"

echo "== Restart mid-run (recovery path)"
xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" || true
sleep 3
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" -LocusShowRuns
wait_for "\[Locus\]\[Run\]\[warning\] Recovered" 120 || true
sleep 6
xcrun simctl io "$DEVICE_ID" screenshot "$OUT/03-dashboard-after-restart.png"
# locus://runs is not exercised: iOS shows an "Open in Locus?" confirmation for
# simctl openurl that this script can't tap. Check the deep link by hand.

sleep 2
kill $LOG_PID 2>/dev/null || true

echo "== Crash reports"
mkdir -p "$OUT/crashes"
find ~/Library/Logs/DiagnosticReports -name 'Locus*' -newer "$OUT/xcodebuild.log" -exec cp {} "$OUT/crashes/" \; 2>/dev/null || true

echo "== Checks"
fail=0
check() { if grep -q "$1" "$OUT/app.log"; then echo "PASS  $2"; else echo "FAIL  $2"; fail=1; fi; }
check "\[Locus\]\[Run\]\[info\] Started manual run" "demo run started"
check "\[Locus\]\[SimStub\] set" "executor pushed coordinates to the location engine"
check "\[Locus\]\[Run\]\[info\] Driving to Demo End" "drive leg began (MapKit route OK)"
check "\[Locus\]\[Run\]\[warning\] Recovered" "run recovered after restart"
if ls "$OUT/crashes"/* >/dev/null 2>&1; then echo "FAIL  crash reports found"; fail=1; else echo "PASS  no crash reports"; fi
exit $fail
