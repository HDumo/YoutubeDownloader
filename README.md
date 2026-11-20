# YouTube Downloader - Windows, Mac, Android and iPhone

Paste YouTube links, choose **MP3 (audio)** and/or **MP4 (video)**, and let an ordered queue download them one by one.
Optional limits ("max 3 downloads per 1 hour + 30 minutes"), timed pauses, your own file names and folders, and it keeps
working in the background.

| You have | Download | Guide |
|---|---|---|
| **Windows PC** | [YouTubeDownloader-Setup.exe](https://github.com/HDumo/YoutubeDownloader/raw/main/dist/YouTubeDownloader-Setup.exe) | [docs/WINDOWS.md](docs/WINDOWS.md) |
| **Mac** (Intel or Apple Silicon) | [YouTubeDownloader-macOS.zip](https://github.com/HDumo/YoutubeDownloader/raw/main/dist/YouTubeDownloader-macOS.zip) | [docs/MACOS.md](docs/MACOS.md) |
| **Android phone** | [YouTubeDownloader.apk](https://github.com/HDumo/YoutubeDownloader/raw/main/dist/YouTubeDownloader.apk) | [docs/ANDROID.md](docs/ANDROID.md) |
| **iPhone / iPad** | nothing to install - use Safari (no App Store app exists) | [docs/IOS.md](docs/IOS.md) |
| Linux / Raspberry Pi / NAS (as the server) | [YouTubeDownloader-PhoneServer.zip](https://github.com/HDumo/YoutubeDownloader/raw/main/dist/YouTubeDownloader-PhoneServer.zip) | [docs/ANDROID.md](docs/ANDROID.md#option-c---any-other-computer-as-the-server) |

## How the pieces fit

```
 Windows desktop app  ---------------------------- downloads on the PC (queue, MP3/MP4, limits, pauses, tray icon)
 Mac app  ---------------------------------------- same web app in your browser + menu-bar icon, runs in the background

 Phone edition  = small server + mobile web app (same features, big touch buttons, dark mode)
      server runs on:  your Windows PC  |  your Mac  |  the Android phone itself (Termux)  |  Linux / Raspberry Pi
      used from:       Android app (APK) | Chrome | iPhone Safari / "Add to Home Screen" | any browser
```

* The desktop app needs **no Python and no admin rights**; it downloads `yt-dlp` and `ffmpeg` on first start.
* The phone edition is protected by a **PIN** shown when the server starts, and only works on your own network.
* The **Mac app** needs nothing installed first (no Python, no Homebrew) and can also serve your iPhone/Android on the same Wi-Fi.
* **iPhone/iPad cannot run the downloader themselves** (iOS does not allow it); they use a server running on a PC, Mac or an
  Android phone and save the finished files to the Files app.

## What it does

* Queue in the order you add links; one download at a time.
* **MP3 and/or MP4** per link (tick both for audio *and* video). MP4 quality cap: Best, 1080p, 720p, 480p, 360p.
* **Save as** - keep the original title or type your own name; choose the folder.
* **Limit**: *max N downloads per A [unit] + B [smaller unit]* (e.g. 3 per 1 Hours + 30 Minutes). Extra links wait and start by themselves.
* **Pause** now, *resume in* A [unit] + B [smaller unit], or *pause until* a date and time.
* Remove / cancel / retry any item; the queue survives closing the app.
* Windows: closing the window keeps it running in the system tray. Mac: it runs in the background with a menu-bar icon and can start at login.

Only download audio and video you have the right to (your own uploads, Creative Commons, or with the owner's permission);
downloading can break YouTube's Terms of Service.

## Screenshots (mobile web app)

<img src="docs/screenshots/iphone-add.png" width="220"> <img src="docs/screenshots/iphone-queue.png" width="220"> <img src="docs/screenshots/iphone-dark-queue.png" width="220">

Mac app first start and settings:

<img src="docs/screenshots/mac-first-run.png" width="360"> <img src="docs/screenshots/mac-settings.png" width="220">

## For developers

| Path | What |
|---|---|
| `YouTubeMP3.ps1` | Windows desktop app (PowerShell + WinForms) |
| `PhoneServer.ps1`, `Start Phone Server.bat` | Windows launcher for the phone server (fetches a private Python) |
| `mobile/server/ytdl_server.py`, `mobile/server/web/` | Phone server (Python standard library only) + the web app all editions share |
| `mobile/server-go/` | The same server written in Go - one self-contained binary; powers the Mac app (also first-run download of yt-dlp/ffmpeg, start at login) |
| `mobile/macos/` | Mac app: launcher, menu-bar helper, `build-app.sh` |
| `mobile/android/` | Android app source, `build-apk.sh`, `termux-setup.sh` |
| `installer/` | NSIS installer script and artwork generator |
| `tests/`, `mobile/tests/` | All automated tests - run `sh tests/run-all.sh` (see [docs/TESTING.md](docs/TESTING.md)) |
| `build-release.sh` | Rebuilds everything in `dist/` |
