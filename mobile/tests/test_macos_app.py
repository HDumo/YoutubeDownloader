"""Checks on dist/YouTubeDownloader-macOS.zip (structure) and a real run of its launcher script (Linux build + stand-in Mac commands).
   python3 -I test_macos_app.py
There is no Mac here, so the Mach-O binaries themselves are inspected, not executed; the launcher logic IS executed."""
import importlib.util, io, os, plistlib, shutil, stat, struct, subprocess, sys, tempfile, time, unittest, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ZIP = os.path.join(ROOT, "dist", "YouTubeDownloader-macOS.zip")
spec = importlib.util.spec_from_file_location("contract_test", os.path.join(HERE, "contract_test.py"))
CT = importlib.util.module_from_spec(spec); spec.loader.exec_module(CT)
APP = "YouTubeDownloader-macOS/YouTube Downloader.app/Contents/"


def macho_info(data):
    """(cpu, has_code_signature, minos 'X.Y') of a thin 64-bit Mach-O."""
    magic, cpu = struct.unpack("<II", data[:8])
    assert magic == 0xFEEDFACF, "not a 64-bit Mach-O"
    ncmds = struct.unpack("<I", data[16:20])[0]
    off, sig, minos = 32, False, None
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[off:off + 8])
        if cmd == 0x1D: sig = True
        if cmd == 0x32:                      # LC_BUILD_VERSION: platform, minos, sdk
            v = struct.unpack("<I", data[off + 12:off + 16])[0]; minos = "%d.%d" % (v >> 16, (v >> 8) & 255)
        if cmd == 0x24:                      # LC_VERSION_MIN_MACOSX
            v = struct.unpack("<I", data[off + 8:off + 12])[0]; minos = "%d.%d" % (v >> 16, (v >> 8) & 255)
        off += size
    return cpu, sig, minos


class Structure(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.z = zipfile.ZipFile(ZIP)

    def mode(self, name): return (self.z.getinfo(name).external_attr >> 16) & 0o777

    def test_zip_is_sane(self):
        self.assertIsNone(self.z.testzip())
        for n in self.z.namelist():
            self.assertFalse(n.startswith("/") or ".." in n.split("/"), n)
        self.assertLess(os.path.getsize(ZIP), 25 * 1024 * 1024)

    def test_bundle_layout_and_permissions(self):
        for need in ("Info.plist", "PkgInfo", "MacOS/YouTubeDownloader", "Resources/AppIcon.icns", "Resources/menubar.js",
                     "Resources/bin/ytdl-server-arm64", "Resources/bin/ytdl-server-amd64"):
            self.assertIn(APP + need, self.z.namelist(), need)
        for ex in ("MacOS/YouTubeDownloader", "Resources/bin/ytdl-server-arm64", "Resources/bin/ytdl-server-amd64"):
            self.assertTrue(self.mode(APP + ex) & 0o100, ex + " must be executable")
        self.assertIn("YouTubeDownloader-macOS/READ ME FIRST.txt", self.z.namelist())

    def test_info_plist(self):
        pl = plistlib.loads(self.z.read(APP + "Info.plist"))
        self.assertEqual(pl["CFBundleExecutable"], "YouTubeDownloader")
        self.assertEqual(pl["CFBundleIdentifier"], "com.hdumo.youtubedownloader")
        self.assertEqual(pl["CFBundlePackageType"], "APPL"); self.assertEqual(pl["CFBundleIconFile"], "AppIcon")
        self.assertTrue(pl["LSUIElement"])
        self.assertIn(APP + "MacOS/" + pl["CFBundleExecutable"], self.z.namelist())
        self.assertEqual(pl["LSMinimumSystemVersion"], "11.0")

    def test_binaries_are_real_mac_executables(self):
        arm = self.z.read(APP + "Resources/bin/ytdl-server-arm64"); amd = self.z.read(APP + "Resources/bin/ytdl-server-amd64")
        cpu, sig, minos = macho_info(arm)
        self.assertEqual(cpu, 0x0100000C, "arm64"); self.assertTrue(sig, "Apple Silicon requires a (at least ad-hoc) code signature")
        self.assertLessEqual(tuple(map(int, minos.split("."))), (11, 0), "needs macOS %s" % minos)
        cpu2, _, minos2 = macho_info(amd)
        self.assertEqual(cpu2, 0x01000007, "x86_64"); self.assertLessEqual(tuple(map(int, minos2.split("."))), (11, 0))
        for b in (arm, amd):
            self.assertIn(b"youtube-downloader", b)           # our server is inside
            self.assertIn(b"eugeneware/ffmpeg-static", b)      # the verified ffmpeg download source
            self.assertIn(b"yt-dlp_macos", b)

    def test_icon(self):
        from PIL import Image
        im = Image.open(io.BytesIO(self.z.read(APP + "Resources/AppIcon.icns")))
        self.assertEqual(im.format, "ICNS"); self.assertGreaterEqual(im.size[0], 512)

    def test_scripts(self):
        tmp = tempfile.mkdtemp()
        try:
            for name in ("MacOS/YouTubeDownloader", "Resources/menubar.js"):
                with open(os.path.join(tmp, os.path.basename(name)), "wb") as f: f.write(self.z.read(APP + name))
            self.assertEqual(subprocess.run(["sh", "-n", os.path.join(tmp, "YouTubeDownloader")]).returncode, 0)
            self.assertEqual(subprocess.run(["node", "--check", os.path.join(tmp, "menubar.js")], capture_output=True).returncode, 0)
            with open(os.path.join(tmp, "menubar.js")) as f: js = f.read()
            for word in ("'open'", "'pause'", "'resume'", "'quit'", "NSStatusBar", "NSApplicationActivationPolicyAccessory"):
                self.assertIn(word, js)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_read_me_explains_gatekeeper(self):
        t = self.z.read("YouTubeDownloader-macOS/READ ME FIRST.txt").decode()
        for word in ("Open Anyway", "xattr -cr", "Privacy & Security", "Applications"):
            self.assertIn(word, t)


class LauncherRun(unittest.TestCase):
    """Runs Contents/MacOS/YouTubeDownloader for real, with the Linux server build in place of the Mac ones."""

    def prepare(self, arm_flag):
        tmp = tempfile.mkdtemp(prefix="ytdl-mac-")
        zipfile.ZipFile(ZIP).extractall(tmp)
        app = os.path.join(tmp, "YouTubeDownloader-macOS", "YouTube Downloader.app", "Contents")
        linux = open(CT.GO_BIN, "rb").read()
        for arch, tag in (("arm64", b"A-ARM"), ("amd64", b"B-INTEL")):       # distinguishable copies
            with open(os.path.join(app, "Resources", "bin", "ytdl-server-" + arch), "wb") as f: f.write(linux + tag)
        launcher = os.path.join(app, "MacOS", "YouTubeDownloader"); os.chmod(launcher, 0o755)
        home = os.path.join(tmp, "home"); os.makedirs(home)
        stubs = os.path.join(tmp, "stubs"); os.makedirs(stubs)
        opened = os.path.join(tmp, "opened.txt")
        def stub(name, body):
            with open(os.path.join(stubs, name), "w") as f: f.write("#!/bin/sh\n" + body + "\n")
            os.chmod(os.path.join(stubs, name), 0o755)
        stub("sysctl", 'echo %d' % arm_flag)                       # pretend to be Apple Silicon (1) or Intel (0)
        stub("xattr", 'echo "xattr $@" >> "%s.xattr"' % opened)
        stub("open", 'echo "$@" >> "%s"' % opened)
        stub("xdg-open", 'echo "$@" >> "%s"' % opened)
        host = CT.FakeToolHost()
        port = CT.free_port()
        env = dict(os.environ, HOME=home, PATH=stubs + ":" + os.environ["PATH"], YTDL_PORT=str(port), NO_PROXY="127.0.0.1", no_proxy="127.0.0.1",
                   YTDL_YTDLP_URL=host.url("yt-dlp_fake"), YTDL_FFMPEG_URL=host.url("ffmpeg-fake.gz"), YTDL_NO_SYSTEM_TOOLS="1",
                   YTDL_MAC_FEATURES="1",
                   YTDL_DATA=os.path.join(home, "Library", "Application Support", "YouTube Downloader"))   # = the Mac default
        return dict(tmp=tmp, app=app, launcher=launcher, home=home, opened=opened, host=host, port=port, env=env)

    def health(self, port):
        import http.client
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=2); c.request("GET", "/api/health"); ok = c.getresponse().status == 200; c.close(); return ok
        except OSError:
            return False

    def run_launcher(self, c):
        return subprocess.run(["sh", c["launcher"]], env=c["env"], capture_output=True, text=True, timeout=20)

    def wait_for(self, pred, timeout=15):
        end = time.time() + timeout
        while time.time() < end:
            if pred(): return True
            time.sleep(0.1)
        return False

    def finish(self, c):
        try:
            subprocess.run(["pkill", "-f", os.path.join(c["home"], "Library", "Application Support", "YouTube Downloader", "bin", "ytdl-server")], capture_output=True)
        finally:
            c["host"].close(); shutil.rmtree(c["tmp"], ignore_errors=True)

    def test_launch_background_single_instance_quit(self):
        c = self.prepare(1)
        data = os.path.join(c["home"], "Library", "Application Support", "YouTube Downloader")
        stable = os.path.join(data, "bin", "ytdl-server")
        try:
            r = self.run_launcher(c)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)                                    # launcher exits immediately ...
            self.assertTrue(self.wait_for(lambda: self.health(c["port"])), "server did not start")   # ... server keeps running
            self.assertTrue(os.access(stable, os.X_OK)); self.assertTrue(open(stable, "rb").read().endswith(b"A-ARM"))
            self.assertTrue(os.path.isfile(os.path.join(data, "menubar.js")))
            self.assertTrue(self.wait_for(lambda: os.path.exists(c["opened"])))
            first = open(c["opened"]).read()
            self.assertIn("127.0.0.1:%d/local-login?t=" % c["port"], first)                        # browser opened, already signed in
            self.assertTrue(os.path.exists(c["opened"] + ".xattr"))                                  # quarantine flag clearing was attempted
            with open(os.path.join(data, "server.log")) as f: log = f.read()
            self.assertIn("PIN:", log)
            self.assertIn("menu bar helper could not start", log)                                  # (no osascript on Linux) - and the server carried on
            # first-run download finished through the launcher-started server
            import json, http.client
            with open(os.path.join(data, "config.json")) as f: cfg = json.load(f)
            self.assertEqual(oct(os.stat(os.path.join(data, "config.json")).st_mode & 0o777), "0o600")   # PIN file is private
            srv = CT.Srv("go", tmp=c["tmp"], pin=cfg["pin"], port=c["port"]); srv.pin = cfg["pin"]; srv.login()
            self.assertTrue(self.wait_for(lambda: srv.state()["setup"]["state"] == "ready", 30))
            self.assertTrue(os.access(os.path.join(data, "tools", "yt-dlp"), os.X_OK))
            self.assertTrue(srv.state()["features"]["autostart"])
            # Start at login points at the stable copy, keeps the menu bar helper
            srv.raw("POST", "/api/autostart", {"enabled": True})
            pl = plistlib.load(open(os.path.join(c["home"], "Library", "LaunchAgents", "com.hdumo.youtubedownloader.plist"), "rb"))
            self.assertEqual(pl["ProgramArguments"][0], stable)
            self.assertIn("--background", pl["ProgramArguments"]); self.assertIn("--menubar", pl["ProgramArguments"])
            self.assertIn(os.path.join(data, "menubar.js"), pl["ProgramArguments"])
            # second click on the app: no second server, but the window opens again (fresh sign-in link)
            r2 = self.run_launcher(c); self.assertEqual(r2.returncode, 0)
            self.assertTrue(self.wait_for(lambda: open(c["opened"]).read().count("local-login") == 2))
            ps = subprocess.run(["pgrep", "-fc", stable + " --open"], capture_output=True, text=True).stdout.strip()
            self.assertLessEqual(int(ps or 0), 1)
            self.assertTrue(self.health(c["port"]))
            # Quit
            self.assertEqual(srv.raw("POST", "/api/quit", {})[0], 200)
            self.assertTrue(self.wait_for(lambda: not self.health(c["port"]), 10))
        finally:
            self.finish(c)

    def test_intel_mac_gets_the_intel_binary(self):
        c = self.prepare(0)
        data = os.path.join(c["home"], "Library", "Application Support", "YouTube Downloader")
        try:
            self.assertEqual(self.run_launcher(c).returncode, 0)
            self.assertTrue(self.wait_for(lambda: self.health(c["port"])))
            self.assertTrue(open(os.path.join(data, "bin", "ytdl-server"), "rb").read().endswith(b"B-INTEL"))
        finally:
            self.finish(c)

    def test_app_update_replaces_the_stable_copy(self):
        c = self.prepare(1)
        data = os.path.join(c["home"], "Library", "Application Support", "YouTube Downloader")
        try:
            os.makedirs(os.path.join(data, "bin"))
            with open(os.path.join(data, "bin", "ytdl-server"), "wb") as f: f.write(b"old version")
            self.assertEqual(self.run_launcher(c).returncode, 0)
            self.assertTrue(self.wait_for(lambda: self.health(c["port"])))
            self.assertTrue(open(os.path.join(data, "bin", "ytdl-server"), "rb").read().endswith(b"A-ARM"))
        finally:
            self.finish(c)


if __name__ == "__main__":
    if not os.path.exists(CT.GO_BIN):
        raise SystemExit("build the Linux server first: sh mobile/server-go/build.sh test")
    unittest.main(verbosity=2)
