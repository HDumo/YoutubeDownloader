#!/bin/sh
# Runs mobile/android/termux-setup.sh with stubbed Termux commands and checks the server comes up.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'pkill -f "[y]tdl_server.py --port 8792" 2>/dev/null || true; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/storage/downloads" /data/data/com.termux/files/usr/bin
ln -sf /bin/sh /data/data/com.termux/files/usr/bin/sh
for c in pkg termux-setup-storage termux-wake-lock; do printf '#!/bin/sh\necho "[stub] %s $@"\n' "$c" > "$T/bin/$c"; chmod +x "$T/bin/$c"; done
sh -n "$ROOT/mobile/android/termux-setup.sh" && echo "PASS  termux-setup.sh has valid shell syntax"
(HOME="$T/home" PATH="$T/bin:$PATH" YTDL_PORT=8792 YTDL_DATA="$T/data" timeout 12 sh "$ROOT/mobile/android/termux-setup.sh" > "$T/out.log" 2>&1 &)
for i in 1 2 3 4 5 6 7 8; do curl -sf http://127.0.0.1:8792/api/health >/dev/null 2>&1 && break; sleep 1; done
curl -sf http://127.0.0.1:8792/api/health | grep -q '"ok": true' && echo "PASS  setup script installs (stubbed) and starts the server" || { echo FAIL; cat "$T/out.log"; exit 1; }
grep -q 'storage/downloads/YouTubeDownloader' "$T/out.log" && echo "PASS  files go to the phone's Downloads/YouTubeDownloader folder"
[ -x "$T/home/ytdl-start.sh" ] && echo "PASS  ~/ytdl-start.sh was created for next time"
