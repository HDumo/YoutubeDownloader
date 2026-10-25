#!/bin/sh
# Builds dist/YouTubeDownloader.apk without Gradle or Android Studio.
# Needs (Ubuntu/Debian): apt install default-jdk-headless aapt apksigner zipalign dalvik-exchange android-sdk-platform-23
set -e
cd "$(dirname "$0")"
ANDROID_JAR="${ANDROID_JAR:-/usr/lib/android-sdk/platforms/android-23/android.jar}"
OUT="../../dist/YouTubeDownloader.apk"
KEYSTORE="ytdownloader.keystore"
B=build
rm -rf "$B"; mkdir -p "$B/classes" "$(dirname "$OUT")"

javac --release 8 -Xlint:-options -classpath "$ANDROID_JAR" -d "$B/classes" $(find app/src -name '*.java')
dalvik-exchange --dex --min-sdk-version=23 --output="$B/classes.dex" "$B/classes"
aapt package -f -M app/AndroidManifest.xml -S app/res -I "$ANDROID_JAR" -F "$B/unsigned.apk"
(cd "$B" && aapt add unsigned.apk classes.dex >/dev/null)
zipalign -f -p 4 "$B/unsigned.apk" "$B/aligned.apk"

# A fixed sideload key keeps updates installing over the old version. It is NOT a secret and not a Play Store key.
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android -alias ytdownloader \
    -keyalg RSA -keysize 2048 -validity 36500 -dname "CN=YouTube Downloader, O=HDumo" >/dev/null 2>&1
fi
apksigner sign --v4-signing-enabled false --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android --out "$OUT" "$B/aligned.apk"
apksigner verify --verbose "$OUT"
rm -rf "$B"
echo "Built $(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
