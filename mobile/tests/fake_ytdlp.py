#!/usr/bin/env python3
"""Stand-in for yt-dlp used by the tests: prints yt-dlp style output and writes real files.

URL keywords:  fail -> ERROR, exit 1 | slow -> ~40 s | wait -> ~3 s | otherwise ~0.3 s
"""
import os, re, sys, time

args = sys.argv[1:]
if args[:1] == ["--version"]:
    print("2099.01.01-fake"); sys.exit(0)
if args[:1] == ["-U"]:
    print("yt-dlp is up to date (2099.01.01-fake)"); sys.exit(0)

url = args[-1]
tmpl = args[args.index("-o") + 1]
is_mp4 = "--merge-output-format" in args
ext = "mp4" if is_mp4 else "mp3"
vid = re.sub(r"\W+", "", url.split("/")[-1].split("=")[-1])[:20] or "video"
title = "Fake Title " + vid
print("[youtube] Extracting URL: " + url, flush=True)
if "fail" in url:
    print("ERROR: [youtube] %s: Video unavailable" % vid, file=sys.stderr, flush=True); sys.exit(1)

final = tmpl.replace("%(title)s", title).replace("%(ext)s", ext).replace("%%", "%")
folder = os.path.dirname(final)
os.makedirs(folder, exist_ok=True)
base = os.path.splitext(final)[0]
steps = 60 if "slow" in url else (6 if "wait" in url else 3)
pause = 0.6 if "slow" in url else (0.5 if "wait" in url else 0.1)
if is_mp4:
    print("[download] Destination: %s.f137.mp4" % base, flush=True)
else:
    print("[download] Destination: %s.webm" % base, flush=True)
for i in range(1, steps + 1):
    print("[download]  %.1f%% of 3.00MiB at 1.00MiB/s ETA 00:01" % (100.0 * i / steps), flush=True)
    time.sleep(pause)
if is_mp4:
    print('[Merger] Merging formats into "%s"' % final, flush=True)
else:
    print("[ExtractAudio] Destination: %s" % final, flush=True)
with open(final, "wb") as f:
    f.write((b"FAKEMEDIA-" + vid.encode()) * 50000)      # ~0.5-1 MB
sys.exit(0)
