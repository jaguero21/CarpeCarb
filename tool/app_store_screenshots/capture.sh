#!/bin/zsh
# App Store screenshots: capture, then composite.
#
# 1. Capture (per simulator; 6.9" iPhone 17 Pro Max and 13" iPad Pro):
#      tool/app_store_screenshots/capture.sh <simulator-udid> <raw-dir>
#    Runs integration_test/store_screenshots_test.dart, which seeds a sample
#    day and pauses on each screen; this script saves each one with
#    `xcrun simctl io` (status bar set to 9:41, full signal and battery).
# 2. Composite onto the background with the headline, at App Store sizes:
#      python3 compose.py <raw-dir> backgrounds/phone.png phone ../../screenshots
#      python3 compose.py <raw-dir> backgrounds/ipad.png  ipad  ../../screenshots
#    (needs Pillow; the headlines are in compose.py's HEADLINES).
# 3. The iOS 27 product page header and search results images, from the
#    iPhone captures:
#      python3 creative.py <raw-dir> backgrounds/header.png backgrounds/search.png \
#        ../../screenshots/creative
set -u
UDID=$1; OUT=$2; mkdir -p "$OUT"
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
LOG=$OUT/run.log; : > "$LOG"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged \
  --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
(cd "$REPO" && flutter test integration_test/store_screenshots_test.dart -d "$UDID") > "$LOG" 2>&1 &
PID=$!
TMP=""; captured=()
while kill -0 $PID 2>/dev/null; do
  [[ -z $TMP ]] && TMP=$(grep -o 'SHOT_TMP:.*' "$LOG" | head -1 | cut -d: -f2-)
  for n in $(grep -o 'SHOT_READY:[A-Za-z0-9_]*' "$LOG" | cut -d: -f2); do
    if [[ -z ${captured[(r)$n]} ]]; then
      sleep 0.5
      xcrun simctl io "$UDID" screenshot --type=png "$OUT/$n.png" >/dev/null 2>&1
      touch "$TMP/shot_$n.go"; captured+=($n); echo "captured $n"
    fi
  done
  sleep 0.5
done
wait $PID; status=$?
tail -3 "$LOG"; exit $status
