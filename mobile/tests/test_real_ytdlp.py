"""Both servers (Python and Go) driven over HTTP with the REAL yt-dlp and ffmpeg against a local video (YouTube is not needed).
ffmpeg is given in a folder WITHOUT ffprobe - exactly what the Windows and Mac first-run downloads provide.
Skipped automatically when yt-dlp, ffmpeg or ffprobe is missing.     python3 -I test_real_ytdlp.py
"""
import functools, http.server, importlib.util, json, os, shutil, subprocess, sys, tempfile, threading, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("contract_test", os.path.join(HERE, "contract_test.py"))
CT = importlib.util.module_from_spec(spec); spec.loader.exec_module(CT)
YT = shutil.which("yt-dlp"); FF = shutil.which("ffmpeg"); FP = shutil.which("ffprobe")


def make(impl):
    @unittest.skipUnless(YT and FF and FP, "needs yt-dlp, ffmpeg and ffprobe")
    class RealToolTests(unittest.TestCase):
        @classmethod
        def setUpClass(cls):
            cls.tmp = tempfile.mkdtemp(prefix="ytdl-real-")
            media = os.path.join(cls.tmp, "media"); os.makedirs(media)
            cls.ffdir = os.path.join(cls.tmp, "ffonly"); os.makedirs(cls.ffdir)
            shutil.copy(FF, os.path.join(cls.ffdir, "ffmpeg"))                  # no ffprobe next to it
            subprocess.run([FF, "-v", "error", "-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=15",
                            "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                            "-c:a", "aac", "-shortest", os.path.join(media, "clip.mp4")], check=True)
            class Quiet(http.server.SimpleHTTPRequestHandler):
                def log_message(self, *a, **k): pass
            cls.media = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=media))
            threading.Thread(target=cls.media.serve_forever, daemon=True).start()
            cls.url = "http://127.0.0.1:%d/clip.mp4" % cls.media.server_address[1]
            cls.srv = CT.Srv(impl, fake=False, pin="111111", extra=["--yt-dlp", YT, "--ffmpeg-location", cls.ffdir]).start()
            cls.srv.login()

        @classmethod
        def tearDownClass(cls):
            cls.srv.close(); cls.media.shutdown(); shutil.rmtree(cls.tmp, ignore_errors=True)

        def wait(self, ids, timeout=90):
            end = time.time() + timeout
            while time.time() < end:
                jobs = [j for j in self.srv.state()["jobs"] if j["id"] in ids]
                if jobs and all(j["status"] in ("done", "failed") for j in jobs):
                    return jobs
                time.sleep(0.3)
            self.fail("timed out: %s" % json.dumps(self.srv.state())[:800])

        def probe(self, rel):
            p = os.path.join(self.srv.out, *rel.split("/"))
            out = subprocess.run([FP, "-v", "error", "-show_entries", "stream=codec_name,codec_type", "-of", "json", p],
                                 capture_output=True, text=True, check=True).stdout
            return {s["codec_type"]: s["codec_name"] for s in json.loads(out)["streams"]}

        def test_1_real_mp3_and_mp4_with_custom_name_and_folder(self):
            st, js = self.srv.add([self.url], ("mp3", "mp4"), name="My 100% Clip.mp3", quality="720p", subfolder="Trip")
            self.assertEqual(st, 200, js)
            mp3, mp4 = self.wait(js["added"])
            self.assertEqual((mp3["status"], mp4["status"]), ("done", "done"), (mp3["text"], mp4["text"]))
            self.assertEqual(mp3["file"], "Trip/My 100% Clip.mp3"); self.assertEqual(mp4["file"], "Trip/My 100% Clip.mp4")
            self.assertEqual(self.probe(mp3["file"]), {"audio": "mp3"})
            v = self.probe(mp4["file"]); self.assertEqual(v.get("video"), "h264"); self.assertEqual(v.get("audio"), "aac")

        def test_2_original_title_naming(self):
            st, js = self.srv.add([self.url], ("mp3",))
            (job,) = self.wait(js["added"])
            self.assertEqual(job["status"], "done", job["text"])
            self.assertTrue(job["file"].endswith(".mp3") and "/" not in job["file"], job["file"])
            self.assertEqual(self.probe(job["file"]), {"audio": "mp3"})

        def test_2b_best_quality_mp4(self):
            st, js = self.srv.add([self.url], ("mp4",), name="Best Quality", quality="best")
            (job,) = self.wait(js["added"])
            self.assertEqual(job["status"], "done", job["text"])
            self.assertEqual(self.probe(job["file"]).get("video"), "h264")

        def test_3_bad_link_fails_cleanly(self):
            st, js = self.srv.add(["http://127.0.0.1:9/nothing.mp4"], ("mp3",))
            (job,) = self.wait(js["added"])
            self.assertEqual(job["status"], "failed"); self.assertTrue(job["text"].startswith("Failed:"))

        def test_4_downloaded_file_is_served(self):
            st, js = self.srv.add([self.url], ("mp3",), name="Served")
            (job,) = self.wait(js["added"])
            st, _, body, r = self.srv.raw("GET", "/files/" + job["file"])
            self.assertEqual(st, 200); self.assertEqual(r.getheader("Content-Type"), "audio/mpeg"); self.assertGreater(len(body), 1000)
    RealToolTests.__name__ = RealToolTests.__qualname__ = "Real_" + impl
    return RealToolTests


def suite():
    s = unittest.TestSuite()
    for impl in CT.IMPLS:
        s.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(make(impl)))
    return s


if __name__ == "__main__":
    res = unittest.TextTestRunner(verbosity=2).run(suite())
    sys.exit(0 if res.wasSuccessful() else 1)
