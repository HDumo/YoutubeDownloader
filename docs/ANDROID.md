# Android

You have three ways to use it. **Option A** is the easiest if you have a Windows PC.

| | Server (does the downloading) | Files end up | Needs |
|---|---|---|---|
| **A** | Your Windows PC | on the PC (copy to the phone with *Save*) | the Windows installer + APK |
| **B** | The phone itself, using Termux | in the phone's *Downloads/YouTubeDownloader* | the free Termux app |
| **C** | Another computer (Mac / Linux / Raspberry Pi / NAS) | on that computer | Python 3, yt-dlp, ffmpeg |

## Install the Android app (APK)

1. On the phone, download **[YouTubeDownloader.apk](https://github.com/HDumo/YoutubeDownloader/raw/main/dist/YouTubeDownloader.apk)**
   (or copy it from your PC by USB / cloud drive).
2. Open the downloaded file. Android asks to allow **"Install unknown apps"** for your browser/Files app - allow it for this one install.
3. If **Play Protect** warns about an unrecognised app, choose **Install anyway** (the app is signed with a personal key, not published on Google Play).
4. Open **YouTube Downloader**. It works on Android 6.0 and newer.

You can also skip the APK and open the same address in Chrome, then menu -> **Add to Home screen**.

## Option A - your Windows PC as the server

1. On the PC install the [Windows app](WINDOWS.md) and click **Phone / tablet access** (note the address and PIN).
2. Phone on the **same Wi-Fi**. Open the Android app -> type the address, e.g. `http://192.168.1.20:8765` -> **Connect**.
3. Enter the **PIN** once (the phone remembers it).
4. Add links on the **Add** tab, watch the **Queue** tab, then use the **Files** tab -> **Save** to copy finished files to the phone
   (saved to *Downloads/YouTubeDownloader*).

## Option B - everything on the phone (Termux)

1. Install **Termux** from **F-Droid** (https://f-droid.org/packages/com.termux/). The Google Play version is outdated and will not work.
2. Open Termux and run these three lines:
   ```
   pkg install -y git
   git clone https://github.com/HDumo/YoutubeDownloader
   sh YoutubeDownloader/mobile/android/termux-setup.sh
   ```
   Tap **Allow** when Android asks for storage access. It installs Python, ffmpeg and yt-dlp, then prints a **PIN** and starts the server.
3. Open the YouTube Downloader app -> **This phone (Termux) - 127.0.0.1** -> enter the PIN.
4. Files are saved straight to **Downloads/YouTubeDownloader**.
5. Next time, open Termux and run `~/ytdl-start.sh`. Keep Termux running (it holds a wake-lock); do not swipe it away.

## Option C - any other computer as the server

Download **[YouTubeDownloader-PhoneServer.zip](https://github.com/HDumo/YoutubeDownloader/raw/main/dist/YouTubeDownloader-PhoneServer.zip)**,
install Python 3, `yt-dlp` and `ffmpeg` (for example `sudo apt install python3 ffmpeg yt-dlp` or `brew install yt-dlp ffmpeg`), then:

```
python3 mobile/server/ytdl_server.py --out ~/Downloads/YouTubeDownloader
```

It prints the address and PIN. Options: `--port 8765`, `--bind 127.0.0.1` (this device only), `--pin 123456`, `--yt-dlp /path/to/yt-dlp`.

## Using the app

* **Add**: paste links (one per line), tick **MP3** / **MP4** (both = audio and video), optional name and folder.
* **Queue**: progress, cancel (x), retry, **Pause / Resume**, **Clear finished**.
* **Files**: tap **Save** to put a finished file on this phone.
* **Settings**: *Limit downloads* (max N per A unit + B smaller unit), *Pause for / until*, *Update yt-dlp*, *Change server*.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Can't connect" | The server window must be open on the PC; same Wi-Fi; check the address and port; allow the Windows firewall prompt. |
| Wrong PIN / locked out | 5 wrong PINs lock that device for a minute. The PIN is in the server window; `--pin` sets your own. |
| Termux: "yt-dlp not found" | `pkg install yt-dlp`, or `pip install -U yt-dlp`. |
| Termux stops in the background | Keep its notification, run `termux-wake-lock`, and exclude Termux from battery optimisation. |
| Downloads fail suddenly | Settings -> **Update yt-dlp** (on Termux: `pkg upgrade yt-dlp`). |
| Cannot install the APK | Allow "Install unknown apps" for the app you opened it from; free some storage. |
