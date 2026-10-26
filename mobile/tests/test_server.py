import http.client, json, os, sys, tempfile, threading, time, unittest, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ytdl_server", os.path.join(HERE, "..", "server", "ytdl_server.py"))
S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
FAKE = [sys.executable, os.path.join(HERE, "fake_ytdlp.py")]
PIN = "424242"


class Env:
    """A running server (random port) with temp folders."""
    def __init__(self, data=None, out=None):
        self.tmp = tempfile.TemporaryDirectory()
        self.data = data or os.path.join(self.tmp.name, "data")
        self.out = out or os.path.join(self.tmp.name, "out")
        self.mgr = S.Manager(self.data, self.out, FAKE, None, PIN)
        self.httpd = S.make_server(self.mgr, "127.0.0.1", 0)
        self.port = self.httpd.server_address[1]
        self.mgr.start()
        threading.Thread(target=self.httpd.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True).start()
        self.cookie = ""

    def req(self, method, path, body=None, headers=None, raw=None, auth=True):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        h = dict(headers or {})
        if auth and self.cookie:
            h.setdefault("Cookie", self.cookie)
        data = raw
        if body is not None:
            data = json.dumps(body).encode()
            h.setdefault("Content-Type", "application/json")
        c.request(method, path, body=data, headers=h)
        r = c.getresponse(); payload = r.read()
        try:
            js = json.loads(payload)
        except ValueError:
            js = None
        c.close()
        return r.status, js, payload, r

    def login(self):
        st, _, _, r = self.req("POST", "/api/login", {"pin": PIN}, auth=False)
        assert st == 200, st
        self.cookie = r.getheader("Set-Cookie").split(";")[0]

    def state(self):
        return self.req("GET", "/api/state")[1]

    def wait(self, pred, timeout=20, step=0.1):
        end = time.time() + timeout
        while time.time() < end:
            s = self.state()
            if pred(s):
                return s
            time.sleep(step)
        raise AssertionError("timed out; last state: %s" % json.dumps(self.state())[:600])

    def add(self, urls, kinds=("mp3",), **kw):
        st, js, _, _ = self.req("POST", "/api/add", dict({"urls": list(urls), "kinds": list(kinds)}, **kw))
        return st, js

    def close(self):
        self.mgr.shutdown(); self.httpd.shutdown(); self.httpd.server_close(); self.tmp.cleanup()


def done(s, n):
    return sum(1 for j in s["jobs"] if j["status"] == "done") >= n


class PureTests(unittest.TestCase):
    def test_names_and_urls(self):
        self.assertEqual(S.clean_name(" My: Song?.MP3 "), "My_ Song_")
        self.assertEqual(S.clean_name("Clip.mp4"), "Clip")
        self.assertEqual(S.clean_subfolder("../etc"), "_etc")
        self.assertEqual(S.clean_subfolder(".."), "")
        self.assertEqual(S.clean_subfolder("a/b\\c"), "a_b_c")
        self.assertEqual(S.normalize_url("youtu.be/abc"), "https://youtu.be/abc")
        self.assertEqual(S.normalize_url("www.youtube.com/watch?v=1"), "https://www.youtube.com/watch?v=1")
        self.assertIsNone(S.normalize_url("hello world"))
        self.assertIsNone(S.normalize_url("javascript:alert(1)"))
        self.assertIsNone(S.normalize_url("file:///etc/passwd"))

    def test_unit_rules(self):
        self.assertEqual(S.unit_smaller_than("days"), ["hours", "minutes", "seconds"])
        self.assertEqual(S.unit_smaller_than("hours"), ["minutes", "seconds"])
        self.assertEqual(S.unit_smaller_than("minutes"), ["seconds"])
        self.assertEqual(S.unit_smaller_than("seconds"), [])
        self.assertEqual(S.normalize_span(1, "hours", 30, "hours"), (1, "hours", 0, ""))      # not smaller -> dropped
        self.assertEqual(S.normalize_span(1, "hours", 30, "days"), (1, "hours", 0, ""))
        self.assertEqual(S.normalize_span(1, "seconds", 5, "seconds"), (1, "seconds", 0, ""))
        self.assertEqual(S.normalize_span(2, "days", 6, "hours"), (2, "days", 6, "hours"))
        self.assertEqual(S.span_seconds(1, "hours", 30, "minutes"), 5400)
        self.assertEqual(S.span_seconds(2, "days", 15, "hours"), 2 * 86400 + 15 * 3600)
        self.assertEqual(S.normalize_limit({"count": 5000, "a": -3, "u1": "weeks"})["u1"], "hours")

    def test_limit_window(self):
        lim = S.normalize_limit({"count": 3, "a": 1, "u1": "hours", "b": 30, "u2": "minutes"})
        now = 100000.0
        self.assertIsNone(S.next_allowed([], lim, now))
        self.assertIsNone(S.next_allowed([now - 60, now - 30], lim, now))
        t = [now - 4800, now - 3600, now - 600]
        self.assertAlmostEqual(S.next_allowed(t, lim, now), t[0] + 5400)
        self.assertIsNone(S.next_allowed([now - 9000, now - 3600, now - 600], lim, now))     # oldest fell out of the window
        self.assertIsNone(S.next_allowed(t, S.normalize_limit({"count": 0}), now))          # 0 = unlimited

    def test_build_args(self):
        job = {"kind": "mp3", "url": "https://youtu.be/x", "name": "100% Mix", "height": 0, "subfolder": "Trip"}
        a = S.build_args(job, "/out", "/ff")
        self.assertIn("-x", a); self.assertIn("mp3", a)
        self.assertEqual(a[a.index("-o") + 1], os.path.join("/out", "Trip", "100%% Mix.%(ext)s"))
        self.assertEqual(a[a.index("--ffmpeg-location") + 1], "/ff"); self.assertEqual(a[-1], "https://youtu.be/x")
        v = S.build_args({"kind": "mp4", "url": "u", "name": "", "height": 720, "subfolder": ""}, "/out")
        fmt = v[v.index("-f") + 1]
        self.assertIn("[height<=?720]", fmt); self.assertIn("mp4", v); self.assertNotIn("-x", v)
        self.assertEqual(v[v.index("-o") + 1], os.path.join("/out", "%(title)s.%(ext)s"))

    def test_parse_line(self):
        j = {"name": "", "display": "", "text": "", "percent": 0, "error": ""}
        S.parse_line("[download] Destination: /o/Nice Song.f137.mp4", j); self.assertEqual(j["display"], "Nice Song")
        S.parse_line("[download]  42.5% of 3MiB", j); self.assertEqual(j["percent"], 42.5)
        S.parse_line('[Merger] Merging formats into "/o/Nice Song.mp4"', j); self.assertEqual(j["_final"], "/o/Nice Song.mp4")
        S.parse_line("[ExtractAudio] Destination: /o/Nice Song.mp3", j); self.assertEqual(j["_final"], "/o/Nice Song.mp3")
        S.parse_line("ERROR: [youtube] x: Video unavailable", j); self.assertEqual(j["error"], "[youtube] x: Video unavailable")
        j2 = {"name": "Mine", "display": "Mine", "text": "", "percent": 0, "error": ""}
        S.parse_line("[download] Destination: /o/Other.webm", j2); self.assertEqual(j2["display"], "Mine")


class ApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e = Env(); cls.e.login()

    @classmethod
    def tearDownClass(cls):
        cls.e.close()

    def test_00_auth(self):
        e = Env()
        try:
            self.assertEqual(e.req("GET", "/api/health", auth=False)[0], 200)
            self.assertEqual(e.req("GET", "/api/state", auth=False)[0], 401)
            self.assertEqual(e.req("GET", "/files/x.mp3", auth=False)[0], 401)
            self.assertEqual(e.req("GET", "/", auth=False)[0], 200)                       # the login page is public
            self.assertEqual(e.req("GET", "/api/state", headers={"X-PIN": PIN}, auth=False)[0], 200)
            self.assertEqual(e.req("GET", "/api/state", headers={"Authorization": "Bearer " + PIN}, auth=False)[0], 200)
            self.assertEqual(e.req("GET", "/api/state", headers={"X-PIN": "000000"}, auth=False)[0], 401)
            self.assertEqual(e.req("GET", "/api/state", headers={"Cookie": "ytdl_token=\u00e9\u00e9"}, auth=False)[0], 401)
            self.assertEqual(e.req("POST", "/api/add", {"urls": ["https://youtu.be/a"]}, auth=False)[0], 401)
            for i in range(5):
                self.assertEqual(e.req("POST", "/api/login", {"pin": "bad%d" % i}, auth=False)[0], 401)
            st, js, _, _ = e.req("POST", "/api/login", {"pin": PIN}, auth=False)
            self.assertEqual(st, 429)                                                      # locked out even for the right PIN
        finally:
            e.close()

    def test_01_post_validation(self):
        e = self.e
        self.assertEqual(e.req("POST", "/api/add", raw=b"urls=1", headers={"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(e.req("POST", "/api/add", raw=b"{bad", headers={"Content-Type": "application/json"})[0], 400)
        self.assertEqual(e.req("POST", "/api/add", raw=b"[1]", headers={"Content-Type": "application/json"})[0], 400)
        self.assertEqual(e.req("POST", "/api/add", raw=b"x" * 70000, headers={"Content-Type": "application/json"})[0], 413)
        self.assertEqual(e.add(["not a link"])[0], 400)
        self.assertEqual(e.add(["https://youtu.be/a"], kinds=[])[0], 400)
        self.assertEqual(e.add(["https://youtu.be/a", "https://youtu.be/b"], name="Same")[0], 400)
        self.assertEqual(e.req("POST", "/api/nope", {})[0], 404)
        self.assertEqual(e.req("GET", "/nope")[0], 404)

    def test_10_download_mp3_and_mp4_in_order(self):
        e = self.e
        st, js = e.add(["https://youtu.be/one", "https://youtu.be/two"], kinds=("mp3", "mp4"))
        self.assertEqual(st, 200); self.assertEqual(js["added"], sorted(js["added"])); self.assertEqual(len(js["added"]), 4)
        s = e.wait(lambda s: done(s, 4))
        ids = [j["id"] for j in s["jobs"]]
        kinds = [j["kind"] for j in s["jobs"]]
        self.assertEqual(kinds, ["mp3", "mp4", "mp3", "mp4"])
        self.assertEqual(ids, sorted(ids))
        for j in s["jobs"]:
            self.assertTrue(j["file"].endswith(".mp3" if j["kind"] == "mp3" else ".mp4"), j)
            self.assertTrue(os.path.isfile(os.path.join(e.out, *j["file"].split("/"))))
            self.assertTrue(j["display"].startswith("Fake Title"))
        # strictly one at a time: file creation order == queue order
        order = sorted(s["jobs"], key=lambda j: os.path.getmtime(os.path.join(e.out, *j["file"].split("/"))))
        self.assertEqual([j["id"] for j in order], ids)

    def test_20_files_download_range_and_traversal(self):
        e = self.e
        e.add(["https://youtu.be/files"]); e.wait(lambda s: any(j["file"] and "files" in j["file"] for j in s["jobs"]))
        files = e.req("GET", "/api/files")[1]["files"]
        self.assertTrue(files and all(f["name"].lower().endswith((".mp3", ".mp4")) for f in files))
        f = next(x for x in files if "files" in x["name"])
        import urllib.parse
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
        # a symlink that points outside the folder must not be served
        outside = os.path.join(e.tmp.name, "secret.mp3")
        with open(outside, "wb") as fh:
            fh.write(b"secret")
        try:
            os.symlink(outside, os.path.join(e.out, "link.mp3"))
            self.assertEqual(e.req("GET", "/files/link.mp3")[0], 404)
        except OSError:
            pass

    def test_30_name_override_and_subfolder(self):
        e = self.e
        st, js = e.add(["https://youtu.be/named"], name="My 100% Song.mp3", subfolder="../Road Trip")
        self.assertEqual(st, 200)
        s = e.wait(lambda s: any(j["id"] == js["added"][0] and j["status"] == "done" for j in s["jobs"]))
        j = next(j for j in s["jobs"] if j["id"] == js["added"][0])
        self.assertEqual(j["display"], "My 100% Song")
        self.assertEqual(j["file"].split("/")[-1], "My 100% Song.mp3")
        self.assertEqual(len(j["file"].split("/")), 2)                                  # one folder level, never a path
        self.assertTrue(os.path.realpath(os.path.join(e.out, *j["file"].split("/"))).startswith(os.path.realpath(e.out)))

    def test_40_failure_retry_remove_clear(self):
        e = self.e
        st, js = e.add(["https://youtu.be/fail1"]); jid = js["added"][0]
        s = e.wait(lambda s: any(j["id"] == jid and j["status"] == "failed" for j in s["jobs"]))
        j = next(j for j in s["jobs"] if j["id"] == jid)
        self.assertIn("Video unavailable", j["text"])
        e.req("POST", "/api/retry", {"ids": [jid]})
        e.wait(lambda s: any(j["id"] == jid and j["status"] == "failed" for j in s["jobs"]))   # fails again, but ran again
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
        self.assertFalse(any(j["id"] == slow for j in s["jobs"]))                     # cancelled job was removed, queue moved on

    def test_60_pause_resume_timed(self):
        e = self.e
        e.req("POST", "/api/pause", {"mode": "toggle"})
        self.assertTrue(e.state()["paused"])
        st, js = e.add(["https://youtu.be/paused"]); jid = js["added"][0]
        time.sleep(1.2)
        self.assertEqual(next(j for j in e.state()["jobs"] if j["id"] == jid)["status"], "queued")
        e.req("POST", "/api/pause", {"mode": "toggle"})                                # resume
        e.wait(lambda s: any(j["id"] == jid and j["status"] == "done" for j in s["jobs"]))
        # timed pause: resume in 2 seconds, by itself
        st, s, _, _ = e.req("POST", "/api/pause", {"mode": "for", "a": 2, "u1": "seconds"})
        self.assertEqual(st, 200); self.assertTrue(s["paused"]); self.assertTrue(s["resume_at"] > time.time())
        t0 = time.time(); st, js = e.add(["https://youtu.be/timed"]); jid = js["added"][0]
        e.wait(lambda s: any(j["id"] == jid and j["status"] == "done" for j in s["jobs"]), timeout=20)
        self.assertGreater(time.time() - t0, 1.2)
        self.assertFalse(e.state()["paused"])
        # pause until a time, and bad input
        self.assertEqual(e.req("POST", "/api/pause", {"mode": "until", "until": time.time() - 5})[0], 400)
        self.assertEqual(e.req("POST", "/api/pause", {"mode": "for", "a": 0, "u1": "hours"})[0], 400)
        st, s, _, _ = e.req("POST", "/api/pause", {"mode": "until", "until": time.time() + 3600})
        self.assertTrue(s["paused"] and s["resume_at"] > time.time() + 3000)
        e.req("POST", "/api/pause", {"mode": "resume"})
        self.assertFalse(e.state()["paused"])

    def test_70_limit_queues_the_rest(self):
        e = self.e
        st, js = e.req("POST", "/api/limit", {"count": 2, "a": 4, "u1": "seconds", "b": 9, "u2": "hours"})[:2]
        self.assertEqual(js["limit"], {"count": 2, "a": 4, "u1": "seconds", "b": 0, "u2": ""})       # hours is not smaller than seconds
        st, js = e.req("POST", "/api/limit", {"count": 2, "a": 4, "u1": "seconds"})[:2]
        e.mgr.start_times.clear()
        t0 = time.time()
        st, js = e.add(["https://youtu.be/l1", "https://youtu.be/l2", "https://youtu.be/l3"]); ids = js["added"]
        s = e.wait(lambda s: sum(1 for j in s["jobs"] if j["id"] in ids and j["status"] == "done") == 2, timeout=10)
        third = next(j for j in s["jobs"] if j["id"] == ids[2])
        self.assertEqual(third["status"], "queued")
        s = e.wait(lambda s: s["limit_next"] is not None, timeout=5)
        self.assertGreater(s["limit_next"], time.time() - 0.5)
        e.wait(lambda s: next(j for j in s["jobs"] if j["id"] == ids[2])["status"] == "done", timeout=15)
        self.assertGreaterEqual(time.time() - t0, 3.5)                                   # third waited for the 4 s window
        e.req("POST", "/api/limit", {"count": 0})

    def test_80_update_and_state_fields(self):
        e = self.e
        st, js, _, _ = e.req("POST", "/api/update-ytdlp", {})
        self.assertEqual(st, 200); self.assertIn("up to date", js["output"])
        s = e.state()
        self.assertEqual(s["out_dir"], e.mgr.out_dir); self.assertEqual(s["version"], S.VERSION)
        self.assertNotIn("_final", json.dumps(s))


class PersistenceTests(unittest.TestCase):
    def test_queue_limit_pause_and_pin_survive_restart(self):
        e = Env(); e.login()
        e.req("POST", "/api/limit", {"count": 3, "a": 2, "u1": "days", "b": 6, "u2": "hours"})
        e.req("POST", "/api/pause", {"mode": "until", "until": time.time() + 3600})
        e.add(["https://youtu.be/keep1", "https://youtu.be/keep2"], kinds=("mp3", "mp4"))
        data, out = e.data, e.out
        e.mgr.shutdown(); e.httpd.shutdown(); e.httpd.server_close()
        m2 = S.Manager(data, out, FAKE, None, None)
        try:
            self.assertEqual(m2.pin, PIN)
            snap = m2.snapshot()
            self.assertEqual(snap["limit"], {"count": 3, "a": 2, "u1": "days", "b": 6, "u2": "hours"})
            self.assertTrue(snap["paused"] and snap["resume_at"] > time.time())
            self.assertEqual([(j["kind"], j["status"]) for j in snap["jobs"]], [("mp3", "queued"), ("mp4", "queued")] * 2)
            self.assertEqual(m2.token(), e.mgr.token())                                # old browser cookies stay valid
        finally:
            m2.stop.set(); e.tmp.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
