#!/bin/sh
# Runs every automated test and prints one summary. Needs: python3, pwsh (PowerShell 7), playwright + Chromium,
# yt-dlp, ffmpeg, aapt/apksigner (for the APK check).    Usage: sh tests/run-all.sh [screenshot_dir]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; SHOTS="${1:-$ROOT/docs/screenshots}"
FAIL=0; SUMMARY=""
run() {  # name, command...
  NAME="$1"; shift; echo; echo "=== $NAME ==="
  OUT="$("$@" 2>&1)"; CODE=$?
  echo "$OUT" | tail -n "${TAIL:-40}"
  if [ $CODE -ne 0 ] || echo "$OUT" | grep -q "^FAIL"; then FAIL=1; SUMMARY="$SUMMARY\nFAIL  $NAME"; else
    N=$(echo "$OUT" | grep -c "^PASS\|\.\.\. ok$"); SUMMARY="$SUMMARY\nPASS  $NAME ($N checks)"; fi
}
cd "$ROOT"
run "PowerShell scripts parse (Windows app, phone launcher, helper)" sh -c 'for f in YouTubeMP3.ps1 PhoneServer.ps1 stop-app.ps1; do pwsh -NoProfile -File tests/windows/parse.ps1 -Path $f; done | sed "s/^PARSE OK/PASS  parse OK/"'
run "Windows app logic (queue, limits, pauses, units, MP3/MP4 args)" pwsh -NoProfile -File tests/windows/harness.ps1
run "Windows app remove / cancel / retry" pwsh -NoProfile -File tests/windows/harness2.ps1
run "Phone server: API, security, queue, limits, pauses (fake yt-dlp)" python3 -I mobile/tests/test_server.py
run "Phone server with the REAL yt-dlp + ffmpeg (local video)" python3 -I mobile/tests/test_real_ytdlp.py
TAIL=200 run "Mobile web app in iPhone / Pixel / desktop / dark-mode browsers" python3 -I mobile/tests/ui_test.py "$SHOTS"
run "Windows phone-server launcher (PhoneServer.ps1 under PowerShell)" sh tests/phoneserver_sim.sh
run "Android Termux setup script (stubbed Termux)" sh tests/termux_sim.sh
run "Android APK structure and signature" sh tests/apk_check.sh
echo; echo "================ SUMMARY ================"; printf "$SUMMARY\n"
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
