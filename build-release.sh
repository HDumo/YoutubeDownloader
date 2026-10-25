#!/bin/sh
# Builds everything in dist/:  YouTubeDownloader-Setup.exe, YouTubeDownloader.apk, YouTubeDownloader-PhoneServer.zip
set -e
cd "$(dirname "$0")"
sh installer/build.sh
sh mobile/android/build-apk.sh
python3 - <<'PY'
import os, zipfile
files = ["PhoneServer.ps1", "Start Phone Server.bat", "YouTubeMP3.ps1", "README.md",
         "mobile/server/ytdl_server.py", "mobile/android/termux-setup.sh",
         "docs/WINDOWS.md", "docs/ANDROID.md", "docs/IOS.md"]
files += ["mobile/server/web/" + f for f in sorted(os.listdir("mobile/server/web"))]
files = [f for f in files if os.path.exists(f)]
with zipfile.ZipFile("dist/YouTubeDownloader-PhoneServer.zip", "w", zipfile.ZIP_DEFLATED) as z:
    for f in files:
        info = zipfile.ZipInfo("YouTubeDownloader-PhoneServer/" + f, (2026, 1, 1, 0, 0, 0))
        info.external_attr = (0o755 if f.endswith((".sh", ".py")) else 0o644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, open(f, "rb").read())
print("Built dist/YouTubeDownloader-PhoneServer.zip (%d files)" % len(files))
PY
ls -la dist
