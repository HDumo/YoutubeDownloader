# macOS

Works on **Intel and Apple Silicon Macs running macOS 11 (Big Sur) or newer.** Nothing to install first: no Python, no Homebrew, no Xcode.

## Install

1. Download **[YouTubeDownloader-macOS.zip](https://github.com/HDumo/YoutubeDownloader/raw/main/dist/YouTubeDownloader-macOS.zip)** and double-click it to unzip.
2. Drag **YouTube Downloader.app** into your **Applications** folder.
3. Open it. macOS will block it the first time (the app is not signed with a paid Apple developer certificate). Do **one** of these:
   * **macOS 15 Sequoia and newer:** click **Done**, open **System Settings -> Privacy & Security**, scroll down, click **Open Anyway** next to *YouTube Downloader*, confirm with your password or Touch ID.
   * **macOS 14 and older:** Control-click (right-click) the app -> **Open** -> **Open**.
   * **Any version, in Terminal:** `xattr -cr "/Applications/YouTube Downloader.app"` then open it normally.
4. **First start only:** a banner at the top of the page shows the one-time download of two free helpers, `yt-dlp` and `ffmpeg` (about 100 MB). If you already have them from Homebrew (`/opt/homebrew/bin` or `/usr/local/bin`) they are used instead.
5. Your browser opens the app, already signed in. A **download-arrow icon** appears in the menu bar (top right).

## Use it

1. **Add** tab: paste links (one per line), tick **MP3 (audio)**, **MP4 (video)**, or both; for MP4 choose a quality cap. Optional **Save as** (one link) and **Save in folder**. **Add to queue**.
2. **Queue** tab: live progress, cancel (x), retry, **Pause / Resume**, **Clear finished**. Items download one at a time, in order.
3. **Files** tab: your finished files with a **Save** button (handy from a phone).
4. **Settings** tab:
   * **Limit downloads**: *max N downloads per A [unit] + B [smaller unit]* (for example 3 per 1 Hours + 30 Minutes).
   * **Pause now, resume in** A [unit] + B [smaller unit], or **Or pause until** a date and time.
   * **This computer** card:
     * **Let phones and tablets on my Wi-Fi use this** - shows the address to type on your iPhone/Android, plus the **PIN**. (macOS asks once whether to allow incoming connections - choose **Allow**.)
     * **Start when I log in** - runs quietly in the background after every login.
     * **Save downloads in** - type a folder inside your home folder and press **Use this folder** (a **Choose...** button opens the normal Mac folder picker). Default: `~/Downloads/YouTubeDownloader`.
     * **Quit YouTube Downloader**.

### Background and the menu bar
Closing the browser tab does **not** stop anything. Downloads continue in the background. Click the menu-bar icon for **Open**, **Pause downloads**, **Resume downloads** and **Quit**. Clicking the app in Applications again simply opens the page again. (If the menu-bar icon does not appear, everything else still works; use **Quit** in Settings.)

## Use your iPhone / iPad / Android with the Mac as the server
1. On the Mac: **Settings -> This computer -> Let phones and tablets on my Wi-Fi use this**. Note the address (for example `http://192.168.1.20:8765`) and the PIN.
2. On the phone (same Wi-Fi) follow [IOS.md](IOS.md) or [ANDROID.md](ANDROID.md), starting at *open the address*.
3. Phones can add and manage downloads; only the Mac itself can change the folder, Wi-Fi access, start-at-login or quit.

## Update and uninstall
* **Update:** quit the old copy (menu bar -> Quit), replace the app in Applications with the new one, open it. Your queue and settings are kept.
* **Uninstall:** turn off *Start when I log in*, **Quit**, drag the app to the Trash, and delete the folder `~/Library/Application Support/YouTube Downloader` (this also removes the helpers, queue and settings).

## Where things are
| What | Where |
|---|---|
| Settings, queue, PIN | `~/Library/Application Support/YouTube Downloader/` |
| Helper programs | `.../YouTube Downloader/tools/` |
| Log (for troubleshooting) | `.../YouTube Downloader/server.log` |
| Start-at-login item | `~/Library/LaunchAgents/com.hdumo.youtubedownloader.plist` |

## Troubleshooting
| Problem | Fix |
|---|---|
| "Apple cannot check it for malicious software" | See step 3 above (Open Anyway / right-click Open / `xattr -cr`). |
| Banner says setup could not finish | Check your internet connection, then **Try again** in the banner. |
| Downloads suddenly fail | **Settings -> Update yt-dlp** (YouTube changes often). |
| Page says "Cannot reach the server" | The app was quit. Open it again from Applications. |
| Phone cannot connect | Wi-Fi switch on? Same network? Click **Allow** on the macOS firewall prompt. Guest Wi-Fi often blocks device-to-device traffic. |
| Port 8765 already in use | Another program uses it; quit that program (or start the app from Terminal with `YTDL_PORT=8800`). |
| Nothing opens | Open `http://127.0.0.1:8765` in your browser, or look at `server.log`. |

## How it works (for the curious)
The app is a tiny launcher script plus a self-contained server program (written in Go, one build for Apple Silicon and one for Intel; no Python needed). The launcher copies the server to `~/Library/Application Support/YouTube Downloader/bin/` and starts it in the background; the server serves the same web app the phone edition uses and runs `yt-dlp`/`ffmpeg`. The optional menu-bar icon is a small macOS script (`menubar.js`) started by the server.

## Honest limits
* **Not notarized / not signed with an Apple Developer ID**, hence the one-time "Open Anyway". Notarization needs a paid Apple Developer account.
* **Built and tested without a Mac** (see [TESTING.md](TESTING.md)): the Mac binaries were verified structurally and the launcher logic was run on Linux with stand-in Mac commands, but nobody has opened the app on a real Mac yet. The menu-bar icon and the native folder picker are the least-tested parts.
* Only download audio and video you have the right to.
