#!/data/data/com.termux/files/usr/bin/sh
# YouTube Downloader - run the whole thing ON this Android phone (inside the free Termux app).
#
#   pkg install -y git
#   git clone https://github.com/HDumo/YoutubeDownloader
#   sh YoutubeDownloader/mobile/android/termux-setup.sh
#
# Install Termux from F-Droid (https://f-droid.org/packages/com.termux/) - the Play Store copy is outdated.
set -e

REPO_DIR="${YTDL_DIR:-$HOME/YoutubeDownloader}"
PORT="${YTDL_PORT:-8765}"

echo "== Updating Termux and installing Python, ffmpeg and yt-dlp =="
pkg update -y
pkg install -y python ffmpeg git
if ! pkg install -y yt-dlp; then
  echo "yt-dlp is not in this Termux repository - installing it with pip instead."
  pip install -U yt-dlp
fi

echo "== Letting Termux save into your phone's Downloads folder (tap Allow) =="
if [ ! -d "$HOME/storage/downloads" ]; then
  termux-setup-storage || true
  sleep 3
fi

# When this script was started from inside the cloned repo, use that copy.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/../server/ytdl_server.py" ]; then
  REPO_DIR="$(cd "$HERE/../.." && pwd)"
fi

OUT="$HOME/storage/downloads/YouTubeDownloader"
[ -d "$HOME/storage/downloads" ] || OUT="$HOME/YouTubeDownloader"

START="$HOME/ytdl-start.sh"
cat > "$START" <<EOS
#!/data/data/com.termux/files/usr/bin/sh
# Starts the downloader. Keep Termux open (or its notification running) while you use the app.
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
exec python "$REPO_DIR/mobile/server/ytdl_server.py" --port "$PORT" --out "$OUT"
EOS
chmod +x "$START"

echo
echo "============================================================"
echo " Done. Start the downloader any time with:   ~/ytdl-start.sh"
echo " Then open  http://127.0.0.1:$PORT  in Chrome, or use the YouTube Downloader app"
echo " (choose 'This phone (Termux)'). Files are saved to: $OUT"
echo "============================================================"
echo
echo "Starting it now (press Ctrl+C to stop)..."
exec "$START"
