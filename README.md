# YouTube Downloader - MP3 and MP4 (Windows)

A small window where you paste YouTube links; they download as MP3 (audio) and/or MP4 (video) one after
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
| MP3, MP4, or both | Tick **MP3 (audio)** and/or **MP4 (video)** before pressing Add. Ticking both queues two rows per link (one audio, one video). **Video quality up to** caps the resolution (Best, 1080p ... 360p); video is H.264 + AAC where YouTube offers it, so it plays everywhere. The **Type** column shows which is which. |
| Choose where files go | **Browse...** next to "Save to folder" (remembered next time) |
| Keep the original title | Leave "Save as" empty |
| Use your own name | Type it in "Save as" and add **one** link (".mp3" / ".mp4" is added for you, so the audio and video of a link can share one name) |
| Limit downloads | "Limit: max **N** downloads per **A** *unit* + **B** *smaller unit*", e.g. 3 downloads per 1 Hours + 30 Minutes. The second dropdown only lists units smaller than the first (Hours -> Minutes, Seconds; Seconds -> none). N = 0 means no limit. Extra links wait in the queue and start by themselves when allowed. |
| Pause / resume | **Pause** button (or the tray icon menu); the same button turns into **Resume** |
| Pause for a while | "Pause now, resume in **A** *unit* + **B** *smaller unit*" then **Pause for this long** (e.g. 1 Days + 6 Hours). Same dropdown rules as the limit. |
| Pause until a date/time | Pick a date and time in "Or pause until", then **Pause until then**. A timed pause survives closing the app. |
| Remove or cancel | Select rows -> **Remove / cancel selected** (also the Delete key or right-click). A running download is stopped and removed. Right-click -> Retry for failed ones. |
| Links still waiting when you close | Saved and restored next time you open the app |

## Background mode

Closing the window with the X does **not** quit: the app keeps downloading from
the system tray. Click the **^** arrow next to the clock to find its red icon
(Windows calls these "hidden icons"). Double-click it to open the window;
right-click for Open / Pause / Exit. Use the **Exit app** button or the tray
menu's Exit to really quit. Untick "When I close this window, keep working in
the background" if you would rather the X quit the app. Starting the .bat again
while it is running just brings the existing window back.

## Notes

- It uses `yt-dlp` directly instead of a website like yout.com: no ads, no
  per-hour cap from a third party, and it can be automated reliably. The
  hourly limit above is optional and only if you want to pace yourself.
- A pause only stops *new* downloads from starting; the one already running finishes first.
- A link to a video inside a playlist downloads just that one video.
- If downloads start failing, click **Update yt-dlp** (YouTube changes often;
  the tool also checks for an update once a week).
- Only download audio you have the right to (your own uploads, Creative Commons,
  permission from the owner). Downloading can break YouTube's Terms of Service.
