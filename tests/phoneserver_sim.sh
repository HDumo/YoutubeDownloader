#!/bin/sh
# Runs PhoneServer.ps1 (the Windows launcher) under PowerShell with stand-in tools, then drives the server.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'pkill -f "$T/mobile/server/[y]tdl_server.py" 2>/dev/null || true; rm -rf "$T"' EXIT
mkdir -p "$T/tools/python" "$T/mobile"
cp "$ROOT/PhoneServer.ps1" "$ROOT/YouTubeMP3.ps1" "$T/"; cp -r "$ROOT/mobile/server" "$T/mobile/"
printf '#!/bin/sh\nexec python3 -I "$@"\n' > "$T/tools/python/python.exe"; chmod +x "$T/tools/python/python.exe"
cp "$ROOT/mobile/tests/fake_ytdlp.py" "$T/tools/yt-dlp.exe"; chmod +x "$T/tools/yt-dlp.exe"; : > "$T/tools/ffmpeg.exe"
PORT=8791
(cd "$T" && LOCALAPPDATA="$T/appdata" pwsh -NoProfile -File PhoneServer.ps1 -Port $PORT -Out "$T/out" > "$T/server.log" 2>&1 &)
for i in 1 2 3 4 5 6 7 8 9 10; do curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 1; done
PIN=$(grep -o 'PIN: [0-9]*' "$T/server.log" | cut -d' ' -f2)
[ -n "$PIN" ] && echo "PASS  launcher started the server and printed a PIN" || { echo "FAIL  no PIN"; cat "$T/server.log"; exit 1; }
curl -sf -X POST -H 'Content-Type: application/json' -H "X-PIN: $PIN" -d '{"urls":["https://youtu.be/boot1"],"kinds":["mp3","mp4"]}' "http://127.0.0.1:$PORT/api/add" >/dev/null
sleep 4
OK=$(curl -sf -H "X-PIN: $PIN" "http://127.0.0.1:$PORT/api/state" | python3 -c "import sys,json; s=json.load(sys.stdin); print(all(j['status']=='done' for j in s['jobs']) and len(s['jobs'])==2)")
[ "$OK" = "True" ] && echo "PASS  launcher -> server -> MP3 + MP4 queue ran to completion" || { echo "FAIL  queue"; exit 1; }
[ -f "$T/out/Fake Title boot1.mp3" ] && [ -f "$T/out/Fake Title boot1.mp4" ] && echo "PASS  files saved in the folder passed with -Out" || { echo "FAIL  files"; exit 1; }
