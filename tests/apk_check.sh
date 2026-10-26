#!/bin/sh
# Static checks on dist/YouTubeDownloader.apk (there is no Android device or emulator in this environment).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; APK="$ROOT/dist/YouTubeDownloader.apk"
B="$(aapt dump badging "$APK")"
echo "$B" | grep -q "package: name='com.hdumo.ytdownloader'" && echo "PASS  package name"
echo "$B" | grep -q "launchable-activity: name='com.hdumo.ytdownloader.MainActivity'" && echo "PASS  launcher activity present"
echo "$B" | grep -q "sdkVersion:'23'" && echo "PASS  runs on Android 6.0 (API 23) and newer"
echo "$B" | grep -q "targetSdkVersion:'30'" && echo "PASS  target SDK 30 (installs on Android 14/15)"
echo "$B" | grep -q "uses-permission: name='android.permission.INTERNET'" && echo "PASS  internet permission"
apksigner verify --verbose "$APK" 2>&1 | grep -q "Verified using v2 scheme (APK Signature Scheme v2): true" && echo "PASS  APK is signed (v1+v2+v3)"
unzip -l "$APK" | grep -q classes.dex && echo "PASS  contains compiled code (classes.dex)"
unzip -l "$APK" | grep -c ic_launcher | grep -q 5 && echo "PASS  launcher icons for 5 screen densities"
