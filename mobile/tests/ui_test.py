"""Drives the real mobile web app in Chromium with iPhone / Pixel / desktop emulation.
Run:  python3 -I ui_test.py [screenshot_dir]      (needs: pip install playwright; a Chromium binary)
"""
import glob, os, sys, tempfile, threading, time, importlib.util
from playwright.sync_api import sync_playwright, expect

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ytdl_server", os.path.join(HERE, "..", "server", "ytdl_server.py"))
S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
SHOTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tempfile.gettempdir(), "ytdl-shots")
os.makedirs(SHOTS, exist_ok=True)
PIN = "135790"
CHROME = os.environ.get("CHROME_BIN") or next(iter(glob.glob("/opt/pw-browsers/chromium-*/chrome-linux/chrome")), None)

results = []
def check(name, ok, extra=""):
    results.append((name, bool(ok)))
    print(("PASS  " if ok else "FAIL  ") + name + (("  - " + str(extra)) if (extra and not ok) else ""), flush=True)


def fresh_server():
    tmp = tempfile.TemporaryDirectory()
    mgr = S.Manager(os.path.join(tmp.name, "d"), os.path.join(tmp.name, "o"), [sys.executable, os.path.join(HERE, "fake_ytdlp.py")], None, PIN)
    httpd = S.make_server(mgr, "127.0.0.1", 0)
    mgr.start()
    threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True).start()
    return tmp, mgr, httpd, "http://127.0.0.1:%d" % httpd.server_address[1]


def run_device(pw, label, ctx_opts):
    tmp, mgr, httpd, base = fresh_server()
    browser = pw.chromium.launch(executable_path=CHROME, args=["--no-sandbox"])
    ctx = browser.new_context(**ctx_opts)
    page = ctx.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    # the app deliberately provokes a few 400/401 answers (wrong PIN, name+many links); those are expected
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" and not any(c in m.text for c in ("status of 400", "status of 401")) else None)
    P = label + ": "
    mobile = ctx_opts.get("viewport", {}).get("width", 1000) < 600
    try:
        # ---- login ----
        page.goto(base)
        expect(page.locator("#login")).to_be_visible()
        check(P + "login screen shown first (locked)", page.locator("#app").is_hidden())
        page.fill("#pin", "000000"); page.click("#loginForm button[type=submit]")
        expect(page.locator("#loginErr")).to_contain_text("Wrong PIN")
        check(P + "wrong PIN rejected", True)
        page.screenshot(path=os.path.join(SHOTS, label + "-1-login.png"))
        page.fill("#pin", PIN); page.click("#loginForm button[type=submit]")
        expect(page.locator("#app")).to_be_visible()
        expect(page.locator("#tabs")).to_be_visible()
        check(P + "right PIN unlocks the app", True)

        # ---- add tab ----
        expect(page.locator("#pill")).to_have_text("Idle")
        check(P + "quality disabled until MP4 ticked", page.locator("#quality").is_disabled())
        page.check("#mp4")
        check(P + "quality enabled after ticking MP4", page.locator("#quality").is_enabled())
        page.select_option("#quality", "720p")
        page.screenshot(path=os.path.join(SHOTS, label + "-2-add.png"))
        page.click("#addBtn")
        expect(page.locator("#toast")).to_contain_text("Paste at least one link")
        page.fill("#urls", "https://youtu.be/wait111\nhttps://youtu.be/second22")
        page.fill("#name", "x"); page.click("#addBtn")
        expect(page.locator("#toast")).to_contain_text("one link at a time")
        check(P + "custom name with several links is refused", True)
        page.fill("#name", ""); page.click("#addBtn")
        expect(page.locator('section[data-tab="queue"]')).to_be_visible()
        check(P + "adding switches to the Queue tab", True)
        expect(page.locator("#queue li")).to_have_count(4)
        kinds = page.locator("#queue li .badge").all_inner_texts()
        check(P + "both links queued as MP3+MP4 in order", kinds == ["MP3", "MP4", "MP3", "MP4"], kinds)
        expect(page.locator("#queueCount")).to_be_visible()
        page.wait_for_selector("#queue li.s-downloading .prog")
        page.screenshot(path=os.path.join(SHOTS, label + "-3-queue-downloading.png"))
        check(P + "progress bar shown while downloading", page.locator("#queue li.s-downloading .prog i").count() == 1)
        expect(page.locator("#pill")).to_contain_text("Downloading")
        page.wait_for_function("document.querySelectorAll('#queue li.s-done').length === 4", timeout=40000)
        check(P + "all four downloads finish", True)
        expect(page.locator("#pill")).to_have_text("Idle")

        # ---- failure, retry, remove ----
        page.click('#tabs button[data-tab="add"]')
        page.uncheck("#mp4"); page.fill("#urls", "https://youtu.be/fail999"); page.click("#addBtn")
        page.wait_for_selector("#queue li.s-failed")
        check(P + "failed download shows the reason", "Video unavailable" in page.locator("#queue li.s-failed .st").inner_text())
        page.screenshot(path=os.path.join(SHOTS, label + "-4-queue-failed.png"))
        page.click('#queue li.s-failed button[data-act="retry"]')
        page.wait_for_selector("#queue li.s-failed")
        page.click('#queue li.s-failed button[data-act="remove"]')
        expect(page.locator("#queue li.s-failed")).to_have_count(0)
        check(P + "retry then remove works", True)
        page.click("#clearBtn"); expect(page.locator("#queue li")).to_have_count(0)
        check(P + "clear finished empties the list", page.locator("#queueEmpty").is_visible())

        # ---- cancel a running one ----
        page.click('#tabs button[data-tab="add"]')
        page.fill("#urls", "https://youtu.be/slow123"); page.click("#addBtn")
        page.wait_for_selector("#queue li.s-downloading")
        page.click('#queue li.s-downloading button[data-act="remove"]')
        expect(page.locator("#queue li")).to_have_count(0, timeout=15000)
        check(P + "running download can be cancelled and disappears", True)

        # ---- files tab ----
        page.click('#tabs button[data-tab="files"]')
        expect(page.locator("#files li").first).to_be_visible()
        n = page.locator("#files li").count()
        href = page.locator("#files a").first.get_attribute("href")
        resp = page.request.get(base + href)
        check(P + "files tab lists %d files and each can be saved" % n, n >= 4 and resp.status == 200 and len(resp.body()) > 1000)
        check(P + "file link forces a download", "attachment" in resp.headers.get("content-disposition", "") and page.locator("#files a").first.get_attribute("download") is not None)
        page.screenshot(path=os.path.join(SHOTS, label + "-5-files.png"))

        # ---- settings: unit rules, limit, pauses ----
        page.click('#tabs button[data-tab="settings"]')
        opts = lambda sel: page.locator(sel + " option").all_inner_texts()
        page.select_option("#limU1", "days")
        check(P + "days -> second unit offers Hours/Minutes/Seconds", opts("#limU2") == ["Hours", "Minutes", "Seconds"], opts("#limU2"))
        page.select_option("#limU1", "hours")
        check(P + "hours -> second unit offers Minutes/Seconds", opts("#limU2") == ["Minutes", "Seconds"], opts("#limU2"))
        page.select_option("#limU1", "minutes")
        check(P + "minutes -> second unit offers Seconds", opts("#limU2") == ["Seconds"], opts("#limU2"))
        page.select_option("#limU1", "seconds")
        check(P + "seconds -> second unit disabled", page.locator("#limU2").is_disabled() and page.locator("#limB").is_disabled())
        page.select_option("#pU1", "days")
        check(P + "pause form follows the same rule", opts("#pU2") == ["Hours", "Minutes", "Seconds"], opts("#pU2"))
        page.select_option("#limU1", "hours"); page.select_option("#limU2", "minutes")
        page.fill("#limCount", "3"); page.fill("#limA", "1"); page.fill("#limB", "30")
        page.screenshot(path=os.path.join(SHOTS, label + "-6-settings.png"), full_page=True)
        page.click("#limSave"); expect(page.locator("#toast")).to_contain_text("Limit saved")
        page.reload(); expect(page.locator("#app")).to_be_visible()
        page.click('#tabs button[data-tab="settings"]')
        check(P + "limit survives a page reload", page.input_value("#limCount") == "3" and page.input_value("#limA") == "1"
              and page.input_value("#limU1") == "hours" and page.input_value("#limB") == "30" and page.input_value("#limU2") == "minutes")
        # earlier downloads already used up the 3-per-90-minutes limit -> the next link must wait and say so
        page.click('#tabs button[data-tab="add"]')
        page.fill("#urls", "https://youtu.be/limited1"); page.click("#addBtn")
        expect(page.locator("#pill")).to_contain_text("Limit reached - next download at")
        time.sleep(1.5)
        check(P + "over-limit link waits in the queue and the status says when it will start",
              page.locator("#queue li.s-queued").count() == 1)
        page.click('#tabs button[data-tab="settings"]')
        page.fill("#limCount", "0"); page.click("#limSave")
        page.wait_for_selector("#queue li.s-done", state="attached", timeout=20000)
        expect(page.locator("#pill")).to_have_text("Idle", timeout=20000)
        check(P + "removing the limit (0) lets the waiting link run", True)
        page.click('#tabs button[data-tab="queue"]'); page.click("#clearBtn")
        page.click('#tabs button[data-tab="settings"]')
        page.select_option("#pU1", "hours"); page.fill("#pA", "2"); page.fill("#pB", "0")
        page.click("#pauseFor"); expect(page.locator("#pill")).to_contain_text("Paused until")
        check(P + "'pause for' shows when it ends", True)
        page.click('#tabs button[data-tab="queue"]')
        check(P + "pause button becomes Resume", page.locator("#pauseBtn").inner_text() == "Resume")
        page.click("#pauseBtn"); expect(page.locator("#pill")).to_have_text("Idle")
        page.click('#tabs button[data-tab="settings"]')
        future = time.strftime("%Y-%m-%dT%H:%M", time.localtime(time.time() + 3 * 3600))
        page.fill("#pUntil", future); page.click("#pauseUntil")
        expect(page.locator("#pill")).to_contain_text("Paused until")
        check(P + "'pause until date/time' works", True)
        page.click('#tabs button[data-tab="queue"]'); page.click("#pauseBtn")
        # queued link waits while paused, then runs on resume
        page.click("#pauseBtn"); page.click('#tabs button[data-tab="add"]')
        page.fill("#urls", "https://youtu.be/whilepaused"); page.click("#addBtn")
        page.wait_for_selector("#queue li.s-queued")
        time.sleep(1.5)
        check(P + "link added while paused stays queued", page.locator("#queue li.s-queued").count() == 1)
        page.click("#pauseBtn")
        page.wait_for_selector("#queue li.s-done", timeout=20000)
        check(P + "resume lets it run", True)

        # ---- layout ----
        overflow = page.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        check(P + "no sideways scrolling", overflow <= 0, overflow)
        small = page.evaluate("""() => Array.from(document.querySelectorAll('button, .icon, select, input:not([type=checkbox])'))
            .filter(e => e.offsetParent !== null).map(e => e.getBoundingClientRect()).filter(r => r.height < 40).length""")
        check(P + "every visible control is at least 40px tall (touch friendly)", small == 0, small)
        tabs_ok = page.evaluate("document.getElementById('tabs').getBoundingClientRect().bottom <= window.innerHeight + 1")
        check(P + "tab bar sits inside the screen", tabs_ok)
        check(P + "no JavaScript errors", not errors, errors[:3])
        # sign-in persists across a new page in the same browser (cookie)
        p2 = ctx.new_page(); p2.goto(base); expect(p2.locator("#app")).to_be_visible()
        check(P + "stays signed in on the next visit", True)
    except Exception as exc:
        check(P + "UNEXPECTED: " + type(exc).__name__ + ": " + str(exc)[:300], False)
        try: page.screenshot(path=os.path.join(SHOTS, label + "-error.png"))
        except Exception: pass
    finally:
        browser.close(); mgr.shutdown(); httpd.shutdown(); httpd.server_close(); tmp.cleanup()


with sync_playwright() as pw:
    dev = pw.devices
    run_device(pw, "iPhone13", dict(dev["iPhone 13"]))
    run_device(pw, "Pixel7", dict(dev["Pixel 7"]))
    run_device(pw, "Desktop", dict(viewport={"width": 1280, "height": 800}))
    run_device(pw, "iPhoneDark", dict(dev["iPhone 13"], color_scheme="dark"))

bad = [n for n, ok in results if not ok]
print("\n%d checks, %d failed" % (len(results), len(bad)))
sys.exit(1 if bad else 0)
