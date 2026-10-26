# iPhone and iPad

**There is no iOS app to install.** Apple does not allow apps that download YouTube videos, and an iPhone cannot run `yt-dlp`.
Instead the iPhone uses the same mobile web app as Android, talking to a server on **your Windows PC** (or an Android phone, Mac, Linux box
or Raspberry Pi) on the same Wi-Fi. It behaves like an app once added to the Home Screen.

## Set up (2 minutes)

1. On the PC: install the [Windows app](WINDOWS.md) and click **Phone / tablet access**. Note the **address** (like `http://192.168.1.20:8765`) and the **PIN**.
   *(No PC? Run the server on an Android phone with Termux - see [ANDROID.md](ANDROID.md) - or on a Mac/Linux/Raspberry Pi.)*
2. On the iPhone: join the **same Wi-Fi**, open **Safari**, and go to that address.
3. Enter the **PIN**. Safari remembers it.
4. **Add to Home Screen**: tap the Share button -> **Add to Home Screen** -> **Add**. Open it from the new *YT Downloader* icon (full screen, no Safari bars).

## Use it

* **Add** tab: paste links, tick **MP3** / **MP4**, optional name and folder, **Add to queue**.
* **Queue** tab: progress, cancel, retry, **Pause / Resume**.
* **Files** tab: tap a file -> **Save**. Safari asks **Download**; the file lands in **Files -> Downloads** (iOS 13+). MP3 opens in Files / Music apps, MP4 in Photos or Files.
* **Settings** tab: download **limit** (max N per A unit + B smaller unit), **pause for / until**, **Update yt-dlp**.

The downloads happen on the server, so the PC (or Android phone) must stay on with the server window open. Queued items keep going after you close the page.

## Optional: "Send to downloader" from the Share Sheet

Create a Shortcut (Shortcuts app -> **+**):

1. Tap the info button -> turn on **Show in Share Sheet**; under *Share Sheet Types* keep **URLs**.
2. Add **Get Contents of URL**
   * URL: `http://192.168.1.20:8765/api/add` (your address)
   * Method: **POST**
   * Headers: `X-PIN` = `your PIN`
   * Request Body: **JSON** with `urls` = *List* containing **Shortcut Input**, and `kinds` = *List* containing the text `mp3` (add `mp4` for video too)
3. Add **Show Notification** ("Added to the queue"). Name it *Send to downloader*.

Now in YouTube (or Safari) tap **Share -> Send to downloader**.

## Limits of iOS (honest list)

* No App Store app and no `.ipa`: building one needs a Mac, an Apple developer account, and Apple would not publish it.
* Plain `http://` pages cannot use background caching ("service worker"), so the home-screen app needs the server to be reachable when opened.
* The page cannot wake the server; leave the PC/Android server running.

## Troubleshooting

| Problem | Fix |
|---|---|
| Safari "cannot connect" | Same Wi-Fi? Server window open? Allow the Windows firewall prompt (Private networks). Guest Wi-Fi blocks devices from talking to each other. |
| Address changed next day | Routers hand out new IPs; reserve one for the PC in the router, or read the new address from the server window. |
| Wrong PIN | Shown in the server window; 5 wrong tries lock the device for a minute. |
| File will not save | Use the **Save** button in the Files tab (not long-press); check **Files -> Downloads**. |
