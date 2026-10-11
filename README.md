# YouTube MP3 Downloader (Windows)

A small window where you paste YouTube links; they download as MP3 one after
another, in the order you added them. Nothing to install - it uses PowerShell,
which is already part of Windows 10/11.

## How to use

1. Copy this whole folder to your PC (e.g. Desktop).
2. Double-click **Start YouTube MP3 Downloader.bat**.
   - First time only: it downloads two free helpers (`yt-dlp` and `ffmpeg`, ~100 MB)
     into a `tools` folder. Wait for the black window to finish.
   - If Windows says "Windows protected your PC", click **More info -> Run anyway**.
3. Paste one or more links (one per line), optionally type a name, press **Add to queue**.

## Options

| What | How |
|---|---|
| Choose where files go | **Browse...** next to "Save to folder" (remembered next time) |
| Keep the original title | Leave "Save as" empty |
| Use your own name | Type it in "Save as" and add **one** link (".mp3" is added for you) |
| Limit downloads per hour | Set "Max downloads per hour" (0 = no limit). Extra links wait in the queue and start automatically when a slot frees up |
| Pause / resume | **Pause** button |
| Cancel or remove | Select rows -> **Remove / cancel selected** |
| Links still waiting when you close | Saved and restored next time you open the app |

## Notes

- It uses `yt-dlp` directly instead of a website like yout.com: no ads, no
  per-hour cap from a third party, and it can be automated reliably. The
  hourly limit above is optional and only if you want to pace yourself.
- A link to a video inside a playlist downloads just that one video.
- If downloads start failing, click **Update yt-dlp** (YouTube changes often;
  the tool also checks for an update once a week).
- Only download audio you have the right to (your own uploads, Creative Commons,
  permission from the owner). Downloading can break YouTube's Terms of Service.
