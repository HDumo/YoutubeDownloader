# Test report

Run everything yourself: `sh tests/run-all.sh` (needs `python3`, PowerShell 7 `pwsh`, `playwright` + Chromium, `yt-dlp`, `ffmpeg`,
`aapt`/`apksigner`). Last full run: **208 checks, 0 failed.**

| Area | What was exercised | Checks |
|---|---|---|
| PowerShell syntax | `YouTubeMP3.ps1`, `PhoneServer.ps1`, `stop-app.ps1` parsed by the real PowerShell parser | 3 |
| Windows app logic | queue order, one-at-a-time downloads, MP3/MP4 command lines (incl. `%` in names, 720p cap), progress/title parsing, failure text, limit window maths (sliding window, 0 = unlimited), pause now / timed pause / indefinite pause, second-unit rule (Days -> Hours, Minutes, Seconds ... Seconds -> none), name/link cleaning, quoting | 30 |
| Windows remove / cancel | remove queued, finished and failed rows; cancel a running download (kills the process tree) and drop its row; retry; "nothing selected" message | 4 |
| Phone server (fake `yt-dlp`) | PIN login, cookie / `X-PIN` / Bearer auth, 5-try lockout, JSON-only POSTs, size limits, add (MP3+MP4, name, subfolder), strict queue order, failure + retry, cancel running then continue, pause / resume / timed pause, limit that holds extra links then releases them, restart persistence, file download + `Range`, path traversal / symlink / null-byte attempts | 16 |
| Phone server (REAL `yt-dlp` + `ffmpeg`) | a local video is converted by the real tools: real **MP3** (verified with `ffprobe`), real **MP4 H.264 + AAC**, custom names with `%`, subfolders, best-quality MP4, bad link fails cleanly | 4 |
| Mobile web app in a browser | Chromium running as **iPhone 13**, **Pixel 7**, **desktop**, and **iPhone in dark mode**; each: login (wrong/right PIN), add form rules, MP3+MP4 queue order, live progress, failure/retry/remove/clear, cancel, Files tab + forced download, unit dropdown rules (Days / Hours / Minutes / Seconds), limit saved and restored after reload, over-limit status text, pause for / until, resume, no sideways scrolling, 40px+ touch targets, no JavaScript errors, stays signed in | 136 (34 x 4) |
| Windows phone-server launcher | `PhoneServer.ps1` run under PowerShell with stand-in tools: starts the server, prints PIN, queue runs, files land in `-Out` | 3 |
| Android Termux script | `termux-setup.sh` with stubbed `pkg` / storage commands: syntax, server starts, output folder, `~/ytdl-start.sh` | 4 |
| Android APK | package, launcher activity, SDK range (API 23-30), permissions, signature (v1+v2+v3), compiled code, icons for 5 densities; also checked with Androguard (all expected methods present) | 8 |

Screenshots from the mobile runs are in [`screenshots/`](screenshots/).

## Bugs the testing found (all fixed)

1. Phone server treated an empty "kinds" list as MP3 instead of an error.
2. A `%00` in a file URL crashed the request handler; every request is now guarded and such paths are rejected.
3. Subprocess pipes were left open after a download (resource leak).
4. Mobile settings: number boxes stretched to full width and the "Video quality up to" label wrapped; header status text repeated itself.
5. **MP4 with a resolution cap** was rejected when a source does not report its height; the cap now tolerates unknown heights (`height<=?720`) in both the phone server and the Windows app.
6. APK build: a `WebViewClient` method that exists only on Android 7+ needed its `@Override` removed to compile against the API 23 stubs.
7. Earlier release: the `-Tray` switch name collided with the tray-icon variable (now `-StartInTray`).

## What was NOT tested (please read)

This was built and tested in a Linux cloud container. These things could not be run there:

* **The Windows window itself (WinForms) and the installer on a real Windows PC.** The installer was built with NSIS and its
  contents verified, and all non-visual logic runs under PowerShell, but nobody has clicked through the Windows GUI or run the installer yet.
* **The Android app on a real device or emulator.** The APK is structurally verified and signed; it has not been installed.
  The mobile *web* app it shows was tested in Chromium with Pixel 7 emulation, not on a phone.
* **iPhone / iPad.** There is no WebKit/Safari in the container. The web app was tested in Chromium with iPhone 13 emulation
  (viewport, touch, user agent, safe-area CSS); real Safari behaviour (Add to Home Screen, Files downloads) is untested.
* **Real YouTube.** The container cannot reach YouTube. Downloads were tested with the real `yt-dlp`/`ffmpeg` on a local video,
  which proves our command lines, MP3/MP4 conversion and naming, but not YouTube's own changes - use **Update yt-dlp** if downloads break.
* **Termux on a phone** (stubbed commands only) and the Windows firewall prompt.

If anything misbehaves on your devices, the exact error text or a screenshot is all that is needed to fix it.
