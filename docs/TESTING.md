# Test report

Run everything yourself: `sh tests/run-all.sh` (needs `python3`, PowerShell 7 `pwsh`, Go 1.22+, `playwright` + Chromium, `yt-dlp`,
`ffmpeg`/`ffprobe`, `aapt`/`apksigner`). Last full run: **419 checks, 0 failed.**

| Area | What was exercised | Checks |
|---|---|---|
| PowerShell syntax | `YouTubeMP3.ps1`, `PhoneServer.ps1`, `stop-app.ps1` parsed by the real PowerShell parser | 3 |
| Windows app logic | queue order, one-at-a-time downloads, MP3/MP4 command lines (incl. `%` in names, 720p cap), progress/title parsing, failure text, limit window maths, pause now / timed / indefinite, second-unit rule, name/link cleaning, quoting | 30 |
| Windows remove / cancel | remove queued, finished and failed rows; cancel a running download (kills the process tree); retry | 4 |
| Python server (in-process) | API, security, queue, limits, pauses, restart persistence, `Range`, traversal/symlink/null-byte attempts | 16 |
| **Go server (Mac engine)**: build | builds for Linux, **macOS Apple Silicon, macOS Intel**; `go vet` for Linux and Windows; both Mac binaries are genuine Mach-O | 3 |
| **Go server**: unit tests | limit window, unit rules, name/URL cleaning, yt-dlp arguments, output parsing, LaunchAgent plist | 7 |
| **Both servers, identical API** (black-box over HTTP) | PIN login + lockout, cookie / `X-PIN` / Bearer, JSON-only POSTs, size limits, MP3+MP4 queue order, files + `Range` + traversal/symlink attacks, name + folder, failure/retry/remove/clear, cancel a running download, pause / resume / timed pause, limit that holds then releases links, restart persistence (Python **and** Go run the same tests) | 22 |
| **Go-only (Mac) features** | first-run download of yt-dlp + gzipped ffmpeg from a local host (and a failing host: jobs wait, error shown), one-time local sign-in link (single use, wrong Host refused), second launch just re-opens the running app, start-at-login LaunchAgent plist (written/removed), Quit, Wi-Fi on/off (really re-binds the port), change save folder (inside home only), menu-bar helper commands (pause/resume/quit), phones cannot use computer-only settings and never see the PIN | 5 |
| **Both servers with the REAL `yt-dlp` + `ffmpeg`** | a local video is converted by the real tools, with ffmpeg in a folder **without ffprobe** (what the Windows and Mac first-run downloads provide): real **MP3** and **H.264 + AAC MP4** (checked with `ffprobe`), custom names with `%`, subfolders, best-quality MP4, bad link, file served as `audio/mpeg` | 10 |
| Web app in browsers | Chromium as **iPhone 13**, **Pixel 7**, **desktop** and **iPhone dark mode**, against **both servers** (34 checks x 4 profiles x 2): login, add form rules, queue order, live progress, failure/retry/remove/clear, cancel, Files tab + forced download, unit dropdown rules, limit saved/restored, over-limit status text, pause for/until, resume, no sideways scrolling, 40px+ touch targets, no JS errors, stays signed in; "This computer" card shown only on the Go server | 280 |
| Mac-style flow in a browser | slow first-run download with progress banner, banner disappears and the queue works, PIN shown on the computer, start-at-login writes/removes the LaunchAgent, Wi-Fi switch opens/closes the server, save folder change (and `/etc` refused), Quit button stops the server, no JS errors | 14 |
| Windows phone-server launcher | `PhoneServer.ps1` under PowerShell with stand-in tools | 3 |
| Android Termux script | stubbed Termux commands | 4 |
| Android APK | package, launcher activity, SDK range, permissions, signature v1+v2+v3, code, 5 icon densities (+ Androguard method check) | 8 |
| **macOS app bundle** | zip sanity, bundle layout + executable bits, `Info.plist`, **arm64 binary is ad-hoc signed** (Apple Silicon requires it) and **x86_64 binary present**, both target macOS 11 or older, icon opens as ICNS, launcher passes `sh -n`, menu-bar script passes `node --check`, READ-ME covers Gatekeeper; and **the launcher script is run for real** (Linux server build + stand-in `sysctl`/`xattr`/`open`): picks the Apple-Silicon vs Intel binary, copies it to a stable folder, starts it in the background and exits, opens the browser with a sign-in link, finishes first-run setup, LaunchAgent points at the stable copy and keeps the menu-bar helper, a second click starts no second server but re-opens the page, an app update replaces the stable copy, Quit works, PIN file is private (0600) | 10 |

Screenshots: [`screenshots/`](screenshots/).

## Bugs the testing found (all fixed)

1. Phone server treated an empty "kinds" list as MP3 instead of an error.
2. A `%00` in a file URL crashed the Python request handler; every request is now guarded.
3. Subprocess pipes were left open after a download (resource leak).
4. Mobile settings layout: number boxes stretched, the "Video quality up to" label wrapped, status text repeated itself.
5. **MP4 with a resolution cap** was rejected when a source does not report its height (now `height<=?720`; Windows app + both servers).
6. APK build: a `WebViewClient` method that exists only on Android 7+ needed its `@Override` removed for the API 23 stubs.
7. Earlier release: the `-Tray` switch name collided with the tray-icon variable.
8. **Mac:** a second copy of the app could exit before the browser-open command finished, so the page did not re-open (found by the launcher run; now waits).
9. **Mac / both servers:** the file holding the PIN is now created readable only by its owner (0600).

## What was NOT tested (please read)

This was built and tested in a Linux cloud container with no Mac, no iPhone, no Android device and no access to YouTube.

* **Nothing has run on a real Mac.** The Mac binaries are real Apple Silicon and Intel executables (cross-compiled, inspected, ad-hoc signed
  for Apple Silicon), and the launcher script and the server logic were run on Linux with stand-in Mac commands. Still untested on a Mac:
  Gatekeeper behaviour, `launchctl` (start at login), the **menu-bar icon** (a macOS script that was only syntax-checked), the native
  folder picker (`osascript`), the macOS firewall prompt, and the downloaded Mac builds of `yt-dlp` and `ffmpeg` (their download links were
  verified to exist and to be Mach-O files; they were not executed).
* **The Windows window (WinForms) and installer** on a real Windows PC (logic is tested under PowerShell; the installer was built and its contents verified).
* **The Android app** on a device/emulator (APK verified and signed; the web app it shows was tested in Chromium with Pixel 7 emulation).
* **iPhone / iPad**: no Safari/WebKit here; tested in Chromium with iPhone 13 emulation.
* **Real YouTube** is blocked in the container. Downloads were tested with the real `yt-dlp`/`ffmpeg` on a local video, which proves our command
  lines and conversions, not YouTube's own changes - use **Update yt-dlp** if downloads break.

If anything misbehaves on your devices, the exact error text or a screenshot is all that is needed to fix it.
