# Windows

## Install

1. Download **[YouTubeDownloader-Setup.exe](https://github.com/HDumo/YoutubeDownloader/raw/main/dist/YouTubeDownloader-Setup.exe)**.
2. Double-click it. If Windows says **"Windows protected your PC"**, click **More info -> Run anyway**
   (the installer is not code-signed).
3. Welcome page -> **Next**. On *Choose Components* leave these ticked (defaults):
   * **YouTube Downloader (required)**
   * **Phone and tablet access (Android / iPhone)** - adds a *Phone Server* item to the Start menu
   * **Desktop shortcut**
   * **Start Menu shortcut**
   * *Start with Windows (quietly, in the tray)* - optional, off by default
4. **Install**, then leave *Start YouTube Downloader now* ticked and click **Finish**.
5. First start only: a small window downloads two free helpers, `yt-dlp` and `ffmpeg` (about 150 MB). Then the app opens.

No administrator rights are needed; everything lives in `%LOCALAPPDATA%\Programs\YouTubeDownloader`.

## Use it

1. Paste one or more links (one per line).
2. Tick **MP3**, **MP4**, or both. For MP4 pick the quality cap.
3. Optional: **Save as** (one link only) and **Save to folder**.
4. **Add to queue**. Downloads run one after another.

Extra controls: **Limit** (max N downloads per A unit + B smaller unit), **Pause now, resume in ...**, **Or pause until ...**,
**Remove / cancel selected** (also the Delete key or right-click), **Update yt-dlp**.
Closing the window with X keeps downloading from the tray icon (under the hidden-icons arrow near the clock). Use **Exit app** to quit.

## Phone / tablet access from this PC

Click **Phone / tablet access** in the app, or Start menu -> *YouTube Downloader - Phone Server*.
A window opens and prints something like:

```
 Open this on your phone (same Wi-Fi):
     http://192.168.1.20:8765
 PIN: 482913
```

* First run downloads a private copy of Python (about 10 MB). Nothing else is installed.
* When Windows Defender Firewall asks, tick **Private networks** and click **Allow access**.
* Keep that window open while you use the phone. Files are saved on the PC (same folder as the desktop app).
* Then follow [ANDROID.md](ANDROID.md) or [IOS.md](IOS.md) on the phone.

## Update, uninstall, portable use

* **Update**: run a newer `YouTubeDownloader-Setup.exe` over the old one. Your queue and settings are kept.
* **Uninstall**: Windows Settings -> Apps -> *YouTube Downloader* -> Uninstall (also removes the helpers, settings and queue).
* **Portable**: copy the repository files into a folder and double-click `Start YouTube MP3 Downloader.bat`
  (desktop app) or `Start Phone Server.bat` (phone server).

## Troubleshooting

| Problem | Fix |
|---|---|
| Downloads suddenly fail | Click **Update yt-dlp** (YouTube changes often). |
| Phone cannot open the address | Same Wi-Fi? Allow the firewall prompt (Private networks). Guest Wi-Fi often blocks device-to-device traffic. |
| "Could not listen on 0.0.0.0:8765" | The phone server is already running (look for its window) or another program uses port 8765. |
| First-run setup window fails | Check the internet connection and start the app again. |
