#!/bin/bash
[ -n "$FAKE_ARGS_LOG" ] && printf "%s\n" "$@" > "$FAKE_ARGS_LOG"
url="${@: -1}"
echo "[youtube] Extracting URL: $url"
case "$url" in
  *fail*) echo "ERROR: [youtube] abc: Video unavailable" >&2; exit 1;;
  *slow*) echo "[download] Destination: /tmp/Slow One.webm"; for i in $(seq 1 60); do echo "[download]  $i.0% of 3MiB"; sleep 1; done; exit 0;;
  *mp4*)  echo "[download] Destination: /tmp/Video Title.f137.mp4"; echo "[download]  50.0% of 9MiB"; echo "[download] Destination: /tmp/Video Title.f140.m4a"; echo "[download] 100% of 1MiB"; echo '[Merger] Merging formats into "/tmp/Video Title.mp4"'; exit 0;;
  *)      echo "[download] Destination: /tmp/Nice Song.webm"; echo "[download]  10.0% of 3MiB"; echo "[download] 100% of 3MiB"; echo "[ExtractAudio] Destination: /tmp/Nice Song.mp3"; exit 0;;
esac
