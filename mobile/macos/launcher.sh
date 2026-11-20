#!/bin/sh
# YouTube Downloader (macOS) - starts the background server if it is not running, then opens the app in your browser.
# The server keeps running after this launcher exits (menu bar icon -> Quit to stop it).
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/../Resources"
DATA="$HOME/Library/Application Support/YouTube Downloader"
mkdir -p "$DATA/bin"

if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
  SRC="$RES/bin/ytdl-server-arm64"      # Apple Silicon
else
  SRC="$RES/bin/ytdl-server-amd64"      # Intel
fi

# Run from a fixed place, not from the (possibly temporary) spot the app was opened from.
# That keeps "Start when I log in" working after you move the app or restart.
BIN="$DATA/bin/ytdl-server"
if ! cmp -s "$SRC" "$BIN" 2>/dev/null; then
  cp "$SRC" "$BIN.new" && mv -f "$BIN.new" "$BIN"
fi
cp "$RES/menubar.js" "$DATA/menubar.js" 2>/dev/null
chmod +x "$BIN" 2>/dev/null
# Files from the internet are "quarantined"; clear that flag on our own copies so macOS does not block them.
xattr -d com.apple.quarantine "$BIN" "$DATA/menubar.js" 2>/dev/null

# --open: show the app (signed in) once the server is up - or, if it is already running, just show that one.
( nohup "$BIN" --open --menubar "$DATA/menubar.js" </dev/null >>"$DATA/server.log" 2>&1 & )
exit 0
