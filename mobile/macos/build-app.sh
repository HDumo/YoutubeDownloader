#!/bin/sh
# Builds dist/YouTubeDownloader-macOS.zip (a double-clickable "YouTube Downloader.app") on any computer with Go + Python/Pillow.
set -e
cd "$(dirname "$0")"
sh ../server-go/build.sh mac >/dev/null
python3 - <<'PY'
import os, plistlib, stat, zipfile, io
from PIL import Image

ROOT = os.path.abspath("../..")
APP = "YouTube Downloader.app"
VERSION = "2.1.0"
files = {}          # path inside the zip -> (bytes, mode)

def add(path, data, mode=0o644):
    files["YouTubeDownloader-macOS/" + path] = (data, mode)

def rd(p): return open(p, "rb").read()

# --- Info.plist
plist = {
    "CFBundleName": "YouTube Downloader", "CFBundleDisplayName": "YouTube Downloader",
    "CFBundleIdentifier": "com.hdumo.youtubedownloader", "CFBundleVersion": VERSION, "CFBundleShortVersionString": VERSION,
    "CFBundleExecutable": "YouTubeDownloader", "CFBundleIconFile": "AppIcon", "CFBundlePackageType": "APPL",
    "CFBundleInfoDictionaryVersion": "6.0", "LSMinimumSystemVersion": "11.0", "LSUIElement": True,
    "NSHighResolutionCapable": True, "LSApplicationCategoryType": "public.app-category.utilities",
    "NSHumanReadableCopyright": "Free to use",
}
add(APP + "/Contents/Info.plist", plistlib.dumps(plist, fmt=plistlib.FMT_XML))
add(APP + "/Contents/PkgInfo", b"APPL????")
add(APP + "/Contents/MacOS/YouTubeDownloader", rd("launcher.sh"), 0o755)

# --- icon (.icns)
src = Image.open(os.path.join(ROOT, "assets", "app.png")).convert("RGBA").resize((1024, 1024), Image.LANCZOS)
buf = io.BytesIO(); src.save(buf, format="ICNS"); add(APP + "/Contents/Resources/AppIcon.icns", buf.getvalue())

# --- helper + both server binaries
add(APP + "/Contents/Resources/menubar.js", rd("menubar.js"))
for arch in ("arm64", "amd64"):
    add(APP + "/Contents/Resources/bin/ytdl-server-" + arch, rd(os.path.join(ROOT, "mobile", "server-go", "build", "ytdl-server-darwin-" + arch)), 0o755)

add("READ ME FIRST.txt", open("READ-ME-FIRST.txt", "rb").read())

out = os.path.join(ROOT, "dist", "YouTubeDownloader-macOS.zip")
os.makedirs(os.path.dirname(out), exist_ok=True)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    # directory entries first (some unzip tools need them to keep permissions)
    dirs = sorted({os.path.dirname(p) for p in files} | {"YouTubeDownloader-macOS"})
    for d in dirs:
        parts = d.split("/")
        for i in range(1, len(parts) + 1):
            name = "/".join(parts[:i]) + "/"
            if name not in z.namelist():
                zi = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0)); zi.external_attr = (0o755 | stat.S_IFDIR) << 16
                z.writestr(zi, b"")
    for path, (data, mode) in sorted(files.items()):
        zi = zipfile.ZipInfo(path, (2026, 1, 1, 0, 0, 0)); zi.compress_type = zipfile.ZIP_DEFLATED
        zi.external_attr = (mode | stat.S_IFREG) << 16
        z.writestr(zi, data)
print("Built", out, "(%d bytes)" % os.path.getsize(out))
PY
