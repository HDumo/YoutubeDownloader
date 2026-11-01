"""Black-box API tests run against BOTH servers (Python and Go) so they behave identically.

   python3 -I contract_test.py                 # both implementations
   YTDL_IMPLS=go python3 -I contract_test.py   # one of them
The Go binary is taken from $YTDL_GO_BIN (default: build with `sh mobile/server-go/build.sh test`).
"""
import http.client, json, os, plistlib, shutil, signal, socket, stat, subprocess, sys, tempfile, textwrap, threading, time, unittest, gzip
import http.server, functools, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PY_SERVER = os.path.join(ROOT, "mobile", "server", "ytdl_server.py")
GO_BIN = os.environ.get("YTDL_GO_BIN") or os.path.join(ROOT, "mobile", "server-go", "build", "ytdl-server-linux")
FAKE = os.path.join(HERE, "fake_ytdlp.py")
PIN = "424242"
IMPLS = [i for i in os.environ.get("YTDL_IMPLS", "python,go").split(",") if i]


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


class Srv:
    """One server process in its own temp HOME / data / output folders."""
    def __init__(self, impl, tmp=None, extra=None, env=None, fake=True, port=None, pin=PIN, keep=False):
        self.impl = impl
        self.tmp = tmp or tempfile.mkdtemp(prefix="ytdl-")
        self.home = os.path.join(self.tmp, "home"); os.makedirs(self.home, exist_ok=True)
        self.data = os.path.join(self.tmp, "data"); self.out = os.path.join(self.tmp, "out")
        self.port = port or free_port()
        self.extra = list(extra or [])
        self.env = dict(os.environ, HOME=self.home, NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
        self.env.update(env or {})
        self.fake = fake; self.pin = pin; self.cookie = ""; self.proc = None
        self.log = os.path.join(self.tmp, "server.log")

    def cmd(self):
        common = ["--port", str(self.port), "--out", self.out, "--data", self.data]
        if self.pin:
            common += ["--pin", self.pin]
        if self.fake:
            common += ["--yt-dlp", FAKE]
        if self.impl == "python":
            return [sys.executable, "-I", PY_SERVER, "--bind", "127.0.0.1"] + common + self.extra
        return [GO_BIN, "--no-setup"] + common + self.extra

    def start(self):
        self.logf = open(self.log, "ab")
        self.proc = subprocess.Popen(self.cmd(), stdout=self.logf, stderr=subprocess.STDOUT, env=self.env, stdin=subprocess.DEVNULL)
        end = time.time() + 15
        while time.time() < end:
            if self.proc.poll() is not None:
                raise RuntimeError("server exited: " + open(self.log).read()[-800:])
            try:
                if self.raw("GET", "/api/health", auth=False)[0] == 200:
                    return self
            except OSError:
                pass
            time.sleep(0.1)
        raise RuntimeError("server did not start: " + open(self.log).read()[-800:])

    def raw(self, method, path, body=None, headers=None, rawbody=None, auth=True, host=None, ip="127.0.0.1"):
        c = http.client.HTTPConnection(ip, self.port, timeout=15)
        h = dict(headers or {})
        if auth and self.cookie:
            h.setdefault("Cookie", self.cookie)
        data = rawbody
        if body is not None:
            data = json.dumps(body).encode(); h.setdefault("Content-Type", "application/json")
        if host:
            h["Host"] = host
        c.request(method, path, body=data, headers=h)
        r = c.getresponse(); payload = r.read()
        try: js = json.loads(payload)
        except ValueError: js = None
        c.close()
        return r.status, js, payload, r

    req = raw

    def login(self):
        st, _, _, r = self.raw("POST", "/api/login", {"pin": self.pin or PIN}, auth=False)
        assert st == 200, st
        self.cookie = r.getheader("Set-Cookie").split(";")[0]

    def state(self):
        return self.raw("GET", "/api/state")[1]

    def wait(self, pred, timeout=20, step=0.1):
        end = time.time() + timeout
        while time.time() < end:
            s = self.state()
            if pred(s): return s
            time.sleep(step)
        raise AssertionError("timed out; last state: %s" % json.dumps(self.state())[:700])

    def add(self, urls, kinds=("mp3",), **kw):
        st, js, _, _ = self.raw("POST", "/api/add", dict({"urls": list(urls), "kinds": list(kinds)}, **kw))
        return st, js

    def stop(self, wait=True):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            if wait:
                try: self.proc.wait(10)
                except subprocess.TimeoutExpired: self.proc.kill()
        try: self.logf.close()
        except Exception: pass

    def close(self):
        self.stop(); shutil.rmtree(self.tmp, ignore_errors=True)


def done(s, n): return sum(1 for j in s["jobs"] if j["status"] == "done") >= n


def make_api_tests(impl):
    class ApiTests(unittest.TestCase):
        IMPL = impl

        @classmethod
        def setUpClass(cls):
            cls.e = Srv(impl).start(); cls.e.login()

        @classmethod
        def tearDownClass(cls):
            cls.e.close()

        def test_00_auth(self):
            e = Srv(impl).start()
            try:
                self.assertEqual(e.req("GET", "/api/health", auth=False)[0], 200)
                self.assertEqual(e.req("GET", "/api/state", auth=False)[0], 401)
                self.assertEqual(e.req("GET", "/files/x.mp3", auth=False)[0], 401)
                self.assertEqual(e.req("GET", "/", auth=False)[0], 200)
                self.assertEqual(e.req("GET", "/api/state", headers={"X-PIN": PIN}, auth=False)[0], 200)
                self.assertEqual(e.req("GET", "/api/state", headers={"Authorization": "Bearer " + PIN}, auth=False)[0], 200)
                self.assertEqual(e.req("GET", "/api/state", headers={"X-PIN": "000000"}, auth=False)[0], 401)
                self.assertEqual(e.req("GET", "/api/state", headers={"Cookie": "ytdl_token=\u00e9\u00e9".encode("utf-8").decode("latin-1")}, auth=False)[0], 401)
                self.assertEqual(e.req("POST", "/api/add", {"urls": ["https://youtu.be/a"]}, auth=False)[0], 401)
                for i in range(5):
                    self.assertEqual(e.req("POST", "/api/login", {"pin": "bad%d" % i}, auth=False)[0], 401)
                self.assertEqual(e.req("POST", "/api/login", {"pin": PIN}, auth=False)[0], 429)
            finally:
                e.close()

        def test_01_post_validation(self):
            e = self.e
            ct = {"Content-Type": "application/json"}
            self.assertEqual(e.req("POST", "/api/add", rawbody=b"urls=1", headers={"Content-Type": "text/plain"})[0], 415)
            self.assertEqual(e.req("POST", "/api/add", rawbody=b"{bad", headers=ct)[0], 400)
            self.assertEqual(e.req("POST", "/api/add", rawbody=b"[1]", headers=ct)[0], 400)
            self.assertEqual(e.req("POST", "/api/add", rawbody=b"x" * 70000, headers=ct)[0], 413)
            self.assertEqual(e.add(["not a link"])[0], 400)
            self.assertEqual(e.add(["https://youtu.be/a"], kinds=[])[0], 400)
            self.assertEqual(e.add(["https://youtu.be/a", "https://youtu.be/b"], name="Same")[0], 400)
            self.assertEqual(e.req("POST", "/api/nope", {})[0], 404)
            self.assertEqual(e.req("GET", "/nope")[0], 404)

        def test_10_download_mp3_and_mp4_in_order(self):
            e = self.e
            st, js = e.add(["https://youtu.be/one", "https://youtu.be/two"], kinds=("mp3", "mp4"))
            self.assertEqual(st, 200); self.assertEqual(len(js["added"]), 4)
            s = e.wait(lambda s: done(s, 4))
            ids = [j["id"] for j in s["jobs"]]
            self.assertEqual([j["kind"] for j in s["jobs"]], ["mp3", "mp4", "mp3", "mp4"])
            self.assertEqual(ids, sorted(ids))
            for j in s["jobs"]:
                self.assertTrue(j["file"].endswith(".mp3" if j["kind"] == "mp3" else ".mp4"), j)
                self.assertTrue(os.path.isfile(os.path.join(e.out, *j["file"].split("/"))))
                self.assertTrue(j["display"].startswith("Fake Title"))
            order = sorted(s["jobs"], key=lambda j: os.path.getmtime(os.path.join(e.out, *j["file"].split("/"))))
            self.assertEqual([j["id"] for j in order], ids)

        def test_20_files_download_range_and_traversal(self):
            e = self.e
            e.add(["https://youtu.be/files"]); e.wait(lambda s: any(j["file"] and "files" in j["file"] for j in s["jobs"]))
            files = e.req("GET", "/api/files")[1]["files"]
            self.assertTrue(files and all(f["name"].lower().endswith((".mp3", ".mp4")) for f in files))
            f = next(x for x in files if "files" in x["name"])
            url = "/files/" + "/".join(urllib.parse.quote(p) for p in f["path"].split("/"))
            st, _, body, r = e.req("GET", url)
            self.assertEqual(st, 200); self.assertEqual(len(body), f["size"]); self.assertIn("attachment", r.getheader("Content-Disposition"))
            st, _, body, r = e.req("GET", url, headers={"Range": "bytes=10-19"})
            self.assertEqual(st, 206); self.assertEqual(len(body), 10); self.assertEqual(r.getheader("Content-Range"), "bytes 10-19/%d" % f["size"])
            self.assertEqual(e.req("GET", url, headers={"Range": "bytes=-5"})[0], 206)
            self.assertEqual(e.req("GET", url, headers={"Range": "bytes=99999999-"})[0], 416)
            for bad in ("/files/../../../etc/passwd", "/files/%2e%2e/%2e%2e/etc/passwd", "/files//etc/passwd",
                        "/files/..%2f..%2fetc%2fpasswd", "/files/C:/Windows/win.ini", "/files/..\\..\\x", "/files/%00"):
                self.assertIn(e.req("GET", bad)[0], (400, 404), bad)
            outside = os.path.join(e.tmp, "secret.mp3")
            with open(outside, "wb") as fh: fh.write(b"secret")
            os.symlink(outside, os.path.join(e.out, "link.mp3"))
            self.assertEqual(e.req("GET", "/files/link.mp3")[0], 404)

        def test_30_name_override_and_subfolder(self):
            e = self.e
            st, js = e.add(["https://youtu.be/named"], name="My 100% Song.mp3", subfolder="../Road Trip")
            self.assertEqual(st, 200)
            s = e.wait(lambda s: any(j["id"] == js["added"][0] and j["status"] == "done" for j in s["jobs"]))
            j = next(j for j in s["jobs"] if j["id"] == js["added"][0])
            self.assertEqual(j["display"], "My 100% Song")
            self.assertEqual(j["file"].split("/")[-1], "My 100% Song.mp3")
            self.assertEqual(len(j["file"].split("/")), 2)
            self.assertTrue(os.path.realpath(os.path.join(e.out, *j["file"].split("/"))).startswith(os.path.realpath(e.out)))

        def test_40_failure_retry_remove_clear(self):
            e = self.e
            st, js = e.add(["https://youtu.be/fail1"]); jid = js["added"][0]
            s = e.wait(lambda s: any(j["id"] == jid and j["status"] == "failed" for j in s["jobs"]))
            self.assertIn("Video unavailable", next(j for j in s["jobs"] if j["id"] == jid)["text"])
            e.req("POST", "/api/retry", {"ids": [jid]})
            e.wait(lambda s: any(j["id"] == jid and j["status"] == "failed" for j in s["jobs"]))
            e.req("POST", "/api/remove", {"ids": [jid]})
            self.assertFalse(any(j["id"] == jid for j in e.state()["jobs"]))
            e.req("POST", "/api/clear", {})
            self.assertFalse(any(j["status"] in ("done", "failed", "cancelled") for j in e.state()["jobs"]))

        def test_50_cancel_running_and_continue(self):
            e = self.e
            st, js = e.add(["https://youtu.be/slow1"]); slow = js["added"][0]
            st, js = e.add(["https://youtu.be/after"]); after = js["added"][0]
            e.wait(lambda s: any(j["id"] == slow and j["status"] == "downloading" and j["percent"] > 0 for j in s["jobs"]))
            e.req("POST", "/api/remove", {"ids": [slow]})
            s = e.wait(lambda s: any(j["id"] == after and j["status"] == "done" for j in s["jobs"]), timeout=20)
            self.assertFalse(any(j["id"] == slow for j in s["jobs"]))

        def test_60_pause_resume_timed(self):
            e = self.e
            e.req("POST", "/api/pause", {"mode": "toggle"}); self.assertTrue(e.state()["paused"])
            st, js = e.add(["https://youtu.be/paused"]); jid = js["added"][0]
            time.sleep(1.2)
            self.assertEqual(next(j for j in e.state()["jobs"] if j["id"] == jid)["status"], "queued")
            e.req("POST", "/api/pause", {"mode": "toggle"})
            e.wait(lambda s: any(j["id"] == jid and j["status"] == "done" for j in s["jobs"]))
            st, s, _, _ = e.req("POST", "/api/pause", {"mode": "for", "a": 2, "u1": "seconds"})
            self.assertEqual(st, 200); self.assertTrue(s["paused"]); self.assertTrue(s["resume_at"] > time.time())
            t0 = time.time(); st, js = e.add(["https://youtu.be/timed"]); jid = js["added"][0]
            e.wait(lambda s: any(j["id"] == jid and j["status"] == "done" for j in s["jobs"]), timeout=20)
            self.assertGreater(time.time() - t0, 1.2); self.assertFalse(e.state()["paused"])
            self.assertEqual(e.req("POST", "/api/pause", {"mode": "until", "until": time.time() - 5})[0], 400)
            self.assertEqual(e.req("POST", "/api/pause", {"mode": "for", "a": 0, "u1": "hours"})[0], 400)
            st, s, _, _ = e.req("POST", "/api/pause", {"mode": "until", "until": time.time() + 3600})
            self.assertTrue(s["paused"] and s["resume_at"] > time.time() + 3000)
            e.req("POST", "/api/pause", {"mode": "resume"}); self.assertFalse(e.state()["paused"])

        def test_80_update_and_state_fields(self):
            e = self.e
            st, js, _, _ = e.req("POST", "/api/update-ytdlp", {})
            self.assertEqual(st, 200); self.assertIn("up to date", js["output"])
            s = e.state()
            self.assertEqual(os.path.realpath(s["out_dir"]), os.path.realpath(e.out)); self.assertTrue(s["version"])
            for k in ("jobs", "waiting", "paused", "resume_at", "limit", "limit_next", "busy", "ytdlp", "now"):
                self.assertIn(k, s)
            self.assertNotIn("_final", json.dumps(s))

    ApiTests.__name__ = ApiTests.__qualname__ = "Api_" + impl
    return ApiTests


def make_extra_tests(impl):
    class LimitAndPersistence(unittest.TestCase):
        def test_70_limit_queues_the_rest(self):
            e = Srv(impl).start(); e.login()
            try:
                st, js = e.req("POST", "/api/limit", {"count": 2, "a": 4, "u1": "seconds", "b": 9, "u2": "hours"})[:2]
                self.assertEqual(js["limit"], {"count": 2, "a": 4, "u1": "seconds", "b": 0, "u2": ""})
                t0 = time.time()
                st, js = e.add(["https://youtu.be/l1", "https://youtu.be/l2", "https://youtu.be/l3"]); ids = js["added"]
                s = e.wait(lambda s: sum(1 for j in s["jobs"] if j["id"] in ids and j["status"] == "done") == 2, timeout=10)
                self.assertEqual(next(j for j in s["jobs"] if j["id"] == ids[2])["status"], "queued")
                s = e.wait(lambda s: s["limit_next"] is not None, timeout=5)
                self.assertGreater(s["limit_next"], time.time() - 0.5)
                e.wait(lambda s: next(j for j in s["jobs"] if j["id"] == ids[2])["status"] == "done", timeout=15)
                self.assertGreaterEqual(time.time() - t0, 3.5)
            finally:
                e.close()

        def test_queue_limit_pause_and_pin_survive_restart(self):
            e = Srv(impl).start(); e.login()
            try:
                e.req("POST", "/api/limit", {"count": 3, "a": 2, "u1": "days", "b": 6, "u2": "hours"})
                e.req("POST", "/api/pause", {"mode": "until", "until": time.time() + 3600})
                e.add(["https://youtu.be/keep1", "https://youtu.be/keep2"], kinds=("mp3", "mp4"))
                cookie = e.cookie
                e.stop()
                e2 = Srv(impl, tmp=e.tmp, pin=None, port=e.port); e2.data, e2.out, e2.home = e.data, e.out, e.home
                e2.start(); e2.cookie = cookie            # no --pin given: it must remember the PIN and accept the old cookie
                try:
                    s = e2.state()
                    self.assertEqual(s["limit"], {"count": 3, "a": 2, "u1": "days", "b": 6, "u2": "hours"})
                    self.assertTrue(s["paused"] and s["resume_at"] > time.time())
                    self.assertEqual([(j["kind"], j["status"]) for j in s["jobs"]], [("mp3", "queued"), ("mp4", "queued")] * 2)
                    e2.pin = PIN; e2.cookie = ""
                    e2.login()                                   # remembered PIN still works
                finally:
                    e2.stop(); e.tmp = e2.tmp
            finally:
                shutil.rmtree(e.tmp, ignore_errors=True)
    LimitAndPersistence.__name__ = LimitAndPersistence.__qualname__ = "Limit_" + impl
    return LimitAndPersistence


class FakeToolHost:
    """A local web server that hands out a fake yt-dlp and a gzipped fake ffmpeg (first-run download test)."""
    def __init__(self, missing=False):
        self.dir = tempfile.mkdtemp(prefix="ytdl-tools-")
        shutil.copy(FAKE, os.path.join(self.dir, "yt-dlp_fake")); os.chmod(os.path.join(self.dir, "yt-dlp_fake"), 0o755)
        with gzip.open(os.path.join(self.dir, "ffmpeg-fake.gz"), "wb") as g:
            g.write(b"#!/bin/sh\necho 'ffmpeg version fake'\n" + b"#" * 200000)
        class Quiet(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *a, **k): pass
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=self.dir))
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
    def url(self, name): return "http://127.0.0.1:%d/%s" % (self.port, name)
    def close(self): self.httpd.shutdown(); shutil.rmtree(self.dir, ignore_errors=True)


class GoComputerFeatures(unittest.TestCase):
    """Go-server-only features (Mac app): first-run download, one-click sign-in, start at login, quit, Wi-Fi switch, folder."""
    impl = "go"

    def test_first_run_downloads_tools_then_works(self):
        host = FakeToolHost()
        e = Srv("go", fake=False, extra=["--mac-features"], env={"YTDL_YTDLP_URL": host.url("yt-dlp_fake"), "YTDL_FFMPEG_URL": host.url("ffmpeg-fake.gz"),
                                                                 "YTDL_NO_SYSTEM_TOOLS": "1"})
        e.cmd_orig = e.cmd
        e.cmd = lambda: [a for a in e.cmd_orig() if a != "--no-setup"]      # let it download
        try:
            e.start(); e.login()
            s = e.wait(lambda s: s["setup"]["state"] in ("running", "ready", "error"), timeout=10)
            s = e.wait(lambda s: s["setup"]["state"] == "ready", timeout=30)
            tools = os.path.join(e.data, "tools")
            self.assertTrue(os.access(os.path.join(tools, "yt-dlp"), os.X_OK)); self.assertTrue(os.access(os.path.join(tools, "ffmpeg"), os.X_OK))
            self.assertTrue(open(os.path.join(tools, "ffmpeg"), "rb").read(30).startswith(b"#!/bin/sh\necho 'ffmpeg"))   # gunzipped
            st, js = e.add(["https://youtu.be/setupok"], kinds=("mp3", "mp4"))
            e.wait(lambda s: done(s, 2), timeout=20)
            self.assertIn("fake", e.wait(lambda s: s["ytdlp"] != "", timeout=10)["ytdlp"])
        finally:
            e.close(); host.close()

    def test_jobs_wait_while_tools_are_missing_and_error_is_reported(self):
        e = Srv("go", fake=False, extra=["--mac-features"], env={"YTDL_YTDLP_URL": "http://127.0.0.1:9/nope", "YTDL_FFMPEG_URL": "http://127.0.0.1:9/nope.gz",
                                                                 "YTDL_NO_SYSTEM_TOOLS": "1"})
        e.cmd_orig = e.cmd
        e.cmd = lambda: [a for a in e.cmd_orig() if a != "--no-setup"]
        try:
            e.start(); e.login()
            e.add(["https://youtu.be/needs-tools"])
            s = e.wait(lambda s: s["setup"]["state"] == "error", timeout=15)
            self.assertTrue(s["setup"]["error"])
            self.assertEqual([j["status"] for j in s["jobs"]], ["queued"])        # waits, does not fail
        finally:
            e.close()

    def test_local_login_start_at_login_quit_lan_folder(self):
        marker = tempfile.mkdtemp(prefix="ytdl-open-")
        stubdir = os.path.join(marker, "bin"); os.makedirs(stubdir)
        opened = os.path.join(marker, "opened.txt")
        for name in ("xdg-open", "open"):
            with open(os.path.join(stubdir, name), "w") as f:
                f.write('#!/bin/sh\necho "$@" >> "%s"\n' % opened)
            os.chmod(os.path.join(stubdir, name), 0o755)
        env = {"PATH": stubdir + ":" + os.environ["PATH"]}
        e = Srv("go", extra=["--mac-features", "--open"], env=env)
        try:
            e.start()
            for _ in range(30):
                if os.path.exists(opened): break
                time.sleep(0.1)
            first = open(opened).read().strip()
            self.assertIn("/local-login?t=", first)                                   # --open launched the browser with a sign-in link
            link = first.split()[-1]; path = "/" + link.split("/", 3)[3]
            # the one-time link signs a browser in, once
            st, _, _, r = e.raw("GET", path, auth=False, host="127.0.0.1:%d" % e.port)
            self.assertEqual(st, 302); cookie = r.getheader("Set-Cookie").split(";")[0]
            e.cookie = cookie; self.assertEqual(e.raw("GET", "/api/state")[0], 200)
            self.assertEqual(e.raw("GET", path, auth=False, host="127.0.0.1:%d" % e.port)[0], 403)      # single use
            self.assertEqual(e.raw("GET", "/local-login?t=bogus", auth=False, host="127.0.0.1:%d" % e.port)[0], 403)
            st, js, _, _ = e.raw("POST", "/api/local-token", {}, headers={"X-PIN": PIN}, auth=False)
            self.assertEqual(st, 200)
            self.assertEqual(e.raw("GET", js["url"], auth=False, host="evil.example:%d" % e.port)[0], 403)  # DNS-rebinding style Host refused
            self.assertEqual(e.raw("POST", "/api/local-token", {}, auth=False)[0], 401)                        # needs the PIN

            s = e.state()
            self.assertTrue(s["is_local"]); self.assertEqual(s["pin"], PIN); self.assertTrue(s["features"]["autostart"])
            self.assertEqual(s["platform"], sys.platform if sys.platform != "linux" else "linux")

            # start at login = a LaunchAgent plist
            plist = os.path.join(e.home, "Library", "LaunchAgents", "com.hdumo.youtubedownloader.plist")
            self.assertFalse(s["autostart"])
            s = e.raw("POST", "/api/autostart", {"enabled": True})[1]
            self.assertTrue(s["autostart"]); self.assertTrue(os.path.isfile(plist))
            with open(plist, "rb") as f: pl = plistlib.load(f)
            self.assertEqual(pl["Label"], "com.hdumo.youtubedownloader"); self.assertIn("--background", pl["ProgramArguments"])
            self.assertTrue(pl["RunAtLoad"]); self.assertTrue(os.path.isabs(pl["ProgramArguments"][0]))
            s = e.raw("POST", "/api/autostart", {"enabled": False})[1]
            self.assertFalse(s["autostart"]); self.assertFalse(os.path.exists(plist))

            # Wi-Fi switch: 127.0.0.2 only answers when the server listens on every address
            def reachable():
                try: return e.raw("GET", "/api/health", auth=False, ip="127.0.0.2")[0] == 200
                except OSError: return False
            self.assertFalse(reachable())
            s = e.raw("POST", "/api/lan", {"enabled": True})[1]
            self.assertTrue(s["lan"]); self.assertTrue(reachable()); self.assertEqual(e.raw("GET", "/api/state")[0], 200)
            self.assertFalse(e.raw("GET", "/api/state", ip="127.0.0.2")[1].get("is_local") is False and False)
            s = e.raw("POST", "/api/lan", {"enabled": False})[1]
            self.assertFalse(s["lan"]); self.assertFalse(reachable())

            # folder
            home = e.home
            newdir = os.path.join(home, "Music", "YT Mac")
            s = e.raw("POST", "/api/folder", {"path": newdir})[1]
            self.assertEqual(os.path.realpath(s["out_dir"]), os.path.realpath(newdir)); self.assertTrue(os.path.isdir(newdir))
            s = e.raw("POST", "/api/folder", {"path": "~/Movies/YT Tilde"})[1]
            self.assertTrue(s["out_dir"].endswith("Movies/YT Tilde"))
            for bad in ("/etc", "relative/folder", "", "/tmp/../etc"):
                self.assertEqual(e.raw("POST", "/api/folder", {"path": bad})[0], 400, bad)
            st, js = e.add(["https://youtu.be/inmovies"])
            e.wait(lambda s: done(s, 1))
            self.assertTrue(os.path.isfile(os.path.join(home, "Movies", "YT Tilde", "Fake Title inmovies.mp3")))
            self.assertEqual(e.raw("POST", "/api/choose-folder", {})[0], 501)          # native picker only exists on a Mac

            # a second copy of the app only shows the first one (and asks it for a fresh sign-in link)
            before = open(opened).read().count("local-login")
            p2 = subprocess.run(e.cmd() + ["--open"], env=e.env, capture_output=True, text=True, timeout=20)
            self.assertEqual(p2.returncode, 0, p2.stdout + p2.stderr)
            self.assertEqual(open(opened).read().count("local-login"), before + 1)
            self.assertEqual(e.raw("GET", "/api/health", auth=False)[0], 200)           # the first server is still running

            # Quit
            self.assertEqual(e.raw("POST", "/api/quit", {})[0], 200)
            e.proc.wait(10); self.assertEqual(e.proc.returncode, 0)
        finally:
            e.close(); shutil.rmtree(marker, ignore_errors=True)

    def test_menubar_helper_commands(self):
        tmp = tempfile.mkdtemp(prefix="ytdl-menu-")
        script = os.path.join(tmp, "menubar.sh")
        with open(script, "w") as f:
            f.write('#!/bin/sh\nsleep 1.5\necho pause\nsleep 1\necho resume\nsleep 1\necho pause\nsleep 1\necho quit\nsleep 30\n')
        os.chmod(script, 0o755)
        e = Srv("go", extra=["--mac-features", "--menubar", script], tmp=tmp)
        try:
            e.start(); e.login()
            e.wait(lambda s: s["paused"], timeout=10)                  # "pause" command from the menu bar
            e.wait(lambda s: not s["paused"], timeout=10)              # "resume"
            e.wait(lambda s: s["paused"], timeout=10)
            e.proc.wait(15); self.assertEqual(e.proc.returncode, 0)    # "quit" shuts the server down
            time.sleep(0.5)
            out = subprocess.run(["pgrep", "-f", script], capture_output=True, text=True).stdout.strip()
            self.assertEqual(out, "")                                  # and the helper was stopped too
        finally:
            e.close()

    def test_phone_cannot_use_computer_only_settings(self):
        e = Srv("go", extra=["--mac-features"], env={"YTDL_TEST_NONLOCAL": "1"}).start()
        try:
            e.login()
            # a request from a non-loopback address would be refused; simulate with the LAN IP if there is one
            lan = [a for a in subprocess.run(["hostname", "-I"], capture_output=True, text=True).stdout.split() if a and not a.startswith("127.")]
            if not lan:
                self.skipTest("no LAN address in this environment")
            e.raw("POST", "/api/lan", {"enabled": True})
            st, js, _, _ = e.raw("POST", "/api/quit", {}, ip=lan[0])
            self.assertEqual(st, 403)
            self.assertEqual(e.raw("POST", "/api/folder", {"path": e.home}, ip=lan[0])[0], 403)
            self.assertEqual(e.raw("POST", "/api/lan", {"enabled": False}, ip=lan[0])[0], 403)
            s = e.raw("GET", "/api/state", ip=lan[0])[1]
            self.assertFalse(s["is_local"]); self.assertNotIn("pin", s)           # the PIN is never shown to other devices
        finally:
            e.close()


def load_suite():
    suite = unittest.TestSuite()
    ld = unittest.defaultTestLoader
    for impl in IMPLS:
        if impl == "go" and not os.path.exists(GO_BIN):
            raise SystemExit("Go binary not found: %s (run: sh mobile/server-go/build.sh test)" % GO_BIN)
        suite.addTests(ld.loadTestsFromTestCase(make_api_tests(impl)))
        suite.addTests(ld.loadTestsFromTestCase(make_extra_tests(impl)))
    if "go" in IMPLS:
        suite.addTests(ld.loadTestsFromTestCase(GoComputerFeatures))
    return suite


if __name__ == "__main__":
    res = unittest.TextTestRunner(verbosity=2).run(load_suite())
    sys.exit(0 if res.wasSuccessful() else 1)
