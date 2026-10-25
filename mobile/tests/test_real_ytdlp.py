"""Runs the server with the REAL yt-dlp and ffmpeg against a local video (YouTube itself is not needed).
Skipped automatically when yt-dlp or ffmpeg is missing.   python3 -I test_real_ytdlp.py
"""
import functools, http.server, importlib.util, json, os, shutil, subprocess, sys, tempfile, threading, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ytdl_server", os.path.join(HERE, "..", "server", "ytdl_server.py"))
S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
YT = shutil.which("yt-dlp"); FF = shutil.which("ffmpeg"); FP = shutil.which("ffprobe")


@unittest.skipUnless(YT and FF and FP, "needs yt-dlp, ffmpeg and ffprobe")
class RealToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        media = os.path.join(cls.tmp.name, "media"); os.makedirs(media)
        subprocess.run([FF, "-v", "error", "-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=15",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-shortest", os.path.join(media, "clip.mp4")], check=True)
        class Quiet(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *a, **k):
                pass
        handler = functools.partial(Quiet, directory=media)
        cls.media = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=cls.media.serve_forever, daemon=True).start()
        cls.url = "http://127.0.0.1:%d/clip.mp4" % cls.media.server_address[1]
        os.environ["NO_PROXY"] = os.environ["no_proxy"] = "127.0.0.1,localhost"
        cls.out = os.path.join(cls.tmp.name, "out")
        cls.mgr = S.Manager(os.path.join(cls.tmp.name, "data"), cls.out, [YT], os.path.dirname(FF), "111111")
        cls.mgr.start()

    @classmethod
    def tearDownClass(cls):
        cls.mgr.shutdown(); cls.media.shutdown(); cls.tmp.cleanup()

    def wait(self, ids, timeout=90):
        end = time.time() + timeout
        while time.time() < end:
            snap = self.mgr.snapshot()
            jobs = [j for j in snap["jobs"] if j["id"] in ids]
            if all(j["status"] in ("done", "failed") for j in jobs):
                return jobs
            time.sleep(0.3)
        self.fail("timed out: %s" % json.dumps(self.mgr.snapshot())[:800])

    def probe(self, rel):
        p = os.path.join(self.out, *rel.split("/"))
        out = subprocess.run([FP, "-v", "error", "-show_entries", "stream=codec_name,codec_type", "-of", "json", p],
                             capture_output=True, text=True, check=True).stdout
        return {s["codec_type"]: s["codec_name"] for s in json.loads(out)["streams"]}

    def test_1_real_mp3_and_mp4_with_custom_name_and_folder(self):
        ids, bad = self.mgr.add([self.url], ["mp3", "mp4"], name="My 100% Clip.mp3", quality="720p", subfolder="Trip")
        jobs = self.wait(ids)
        self.assertEqual([j["status"] for j in jobs], ["done", "done"], [j["text"] for j in jobs])
        mp3, mp4 = jobs
        self.assertEqual(mp3["file"], "Trip/My 100% Clip.mp3"); self.assertEqual(mp4["file"], "Trip/My 100% Clip.mp4")
        self.assertEqual(self.probe(mp3["file"]), {"audio": "mp3"})
        v = self.probe(mp4["file"]); self.assertEqual(v.get("video"), "h264"); self.assertEqual(v.get("audio"), "aac")

    def test_2_original_title_naming(self):
        ids, _ = self.mgr.add([self.url], ["mp3"])
        (job,) = self.wait(ids)
        self.assertEqual(job["status"], "done", job["text"])
        self.assertTrue(job["file"].endswith(".mp3") and "/" not in job["file"], job["file"])
        self.assertEqual(self.probe(job["file"]), {"audio": "mp3"})

    def test_2b_best_quality_mp4(self):
        ids, _ = self.mgr.add([self.url], ["mp4"], name="Best Quality", quality="best")
        (job,) = self.wait(ids)
        self.assertEqual(job["status"], "done", job["text"])
        self.assertEqual(self.probe(job["file"]).get("video"), "h264")

    def test_3_bad_link_fails_cleanly(self):
        ids, _ = self.mgr.add(["http://127.0.0.1:9/nothing.mp4"], ["mp3"])
        (job,) = self.wait(ids)
        self.assertEqual(job["status"], "failed"); self.assertTrue(job["text"].startswith("Failed:"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
