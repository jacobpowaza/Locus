#!/usr/bin/env bash
# Linux (or macOS) + USB iPhone. Collects what you need to debug Locus on a
# physical device without Xcode, using libimobiledevice:
#   - live system log filtered to Locus     (idevicesyslog)
#   - crash reports                         (idevicecrashreport)
#   - a screenshot (needs the Developer Disk Image mounted; on iOS 17+ use
#     `pymobiledevice3 developer dvt screenshot` instead if this fails)
#
#   scripts/device-diagnostics.sh [seconds-of-log]   (default 120)
#
# Install on Debian/Ubuntu/Mint: sudo apt install libimobiledevice-utils usbmuxd
# Pair once: plug in, unlock, tap Trust, then `idevicepair pair`.
set -uo pipefail
cd "$(dirname "$0")/.."
SECS="${1:-120}"
OUT="outputs/device-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/crashes"

UDID=$(idevice_id -l | head -1)
[ -n "$UDID" ] || { echo "No iPhone found over USB (idevice_id -l is empty)." >&2; exit 1; }
echo "Device: $UDID"
ideviceinfo -u "$UDID" -k ProductVersion > "$OUT/ios-version.txt" 2>&1 || true

echo "Capturing ${SECS}s of Locus log → $OUT/locus.log (exercise the app now)"
timeout "$SECS" idevicesyslog -u "$UDID" --process Locus > "$OUT/locus.log" 2>&1 || true
grep -E "\[Locus\]" "$OUT/locus.log" > "$OUT/locus-tagged.log" || true

echo "Pulling crash reports"
TMP=$(mktemp -d)
idevicecrashreport -u "$UDID" -e -k "$TMP" >/dev/null 2>&1 || true
find "$TMP" -iname '*Locus*' -exec cp {} "$OUT/crashes/" \; 2>/dev/null
rm -rf "$TMP"
echo "Locus crash reports: $(ls "$OUT/crashes" | wc -l)"

idevicescreenshot -u "$UDID" "$OUT/screen.png" >/dev/null 2>&1 \
  && echo "Screenshot: $OUT/screen.png" \
  || echo "Screenshot skipped (mount the Developer Disk Image, or use pymobiledevice3)."

echo "Done → $OUT"
echo "Run lines: $(grep -c '\[Locus\]\[Run\]' "$OUT/locus.log" 2>/dev/null || echo 0)"
