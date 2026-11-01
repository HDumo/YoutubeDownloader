#!/bin/sh
# Runs every automated test and prints one summary. Needs: python3, pwsh (PowerShell 7), playwright + Chromium,
# yt-dlp, ffmpeg+ffprobe, Go 1.22+, aapt/apksigner (for the APK check).    Usage: sh tests/run-all.sh [screenshot_dir]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; SHOTS="${1:-$ROOT/docs/screenshots}"
FAIL=0; SUMMARY=""
run() {  # name, command...
  NAME="$1"; shift; echo; echo "=== $NAME ==="
  OUT="$("$@" 2>&1)"; CODE=$?
  echo "$OUT" | tail -n "${TAIL:-40}"
  if [ $CODE -ne 0 ] || echo "$OUT" | grep -q "^FAIL\|^--- FAIL"; then FAIL=1; SUMMARY="$SUMMARY\nFAIL  $NAME"; else
    N=$(echo "$OUT" | grep -c "^PASS\|\.\.\. ok$\|^--- PASS"); SUMMARY="$SUMMARY\nPASS  $NAME ($N checks)"; fi
}
cd "$ROOT"
run "PowerShell scripts parse (Windows app, phone launcher, helper)" sh -c 'for f in YouTubeMP3.ps1 PhoneServer.ps1 stop-app.ps1; do pwsh -NoProfile -File tests/windows/parse.ps1 -Path $f; done | sed "s/^PARSE OK/PASS  parse OK/"'
run "Windows app logic (queue, limits, pauses, units, MP3/MP4 args)" pwsh -NoProfile -File tests/windows/harness.ps1
run "Windows app remove / cancel / retry" pwsh -NoProfile -File tests/windows/harness2.ps1
run "Phone server (Python, in-process): API, security, queue, limits, pauses" python3 -I -W ignore mobile/tests/test_server.py
run "Go server: build for Linux (tests) + both Macs, go vet" sh -c 'sh mobile/server-go/build.sh all >/dev/null && (cd mobile/server-go && go vet ./... && GOOS=windows go vet ./... && echo "PASS  go vet (linux, windows)" && for a in arm64 amd64; do file build/ytdl-server-darwin-$a | grep -q "Mach-O 64-bit" && echo "PASS  darwin/$a binary is Mach-O"; done)'
run "Go server: unit tests (limits, units, args, parsing, plist)" sh -c 'cd mobile/server-go && go test -v ./...'
TAIL=60 run "BOTH servers, identical API: auth, queue, limits, pauses, files, persistence; Go: first-run download, local sign-in, start at login, quit, Wi-Fi switch, folder, menu bar" python3 -I -W ignore mobile/tests/contract_test.py
run "BOTH servers with the REAL yt-dlp + ffmpeg (ffmpeg only, no ffprobe)" python3 -I -W ignore mobile/tests/test_real_ytdlp.py
TAIL=300 run "Web app in iPhone / Pixel / desktop / dark-mode browsers (both servers) + Mac-style first-run and settings" python3 -I -W ignore mobile/tests/ui_test.py "$SHOTS"
run "Windows phone-server launcher (PhoneServer.ps1 under PowerShell)" sh tests/phoneserver_sim.sh
run "Android Termux setup script (stubbed Termux)" sh tests/termux_sim.sh
run "Android APK structure and signature" sh tests/apk_check.sh
run "macOS app: bundle structure, Mach-O binaries, plist, icon + the launcher script run for real" python3 -I -W ignore mobile/tests/test_macos_app.py
echo; echo "================ SUMMARY ================"; printf "$SUMMARY\n"
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
