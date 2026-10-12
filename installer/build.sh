#!/bin/sh
# Rebuilds dist/YouTubeDownloader-Setup.exe (needs: makensis; optional: pip install pillow for the artwork).
set -e
cd "$(dirname "$0")"
[ -f ../assets/app.ico ] || python3 make_assets.py
makensis -V2 installer.nsi
echo "Built: $(cd .. && pwd)/dist/YouTubeDownloader-Setup.exe"
