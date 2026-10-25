#!/usr/bin/env python3
"""YouTube Downloader - phone edition server.

A small web server (Python standard library only) that downloads YouTube links as
MP3 and/or MP4 with yt-dlp + ffmpeg, keeps an ordered queue, and serves a mobile web
app so it can be driven from an Android phone, an iPhone/iPad, or any browser.

Run it where the files should be saved:
  * on the Windows PC (see PhoneServer.ps1) and use it from the phone's browser, or
  * on the Android phone itself in Termux (see mobile/android/termux-setup.sh), or
  * on any Mac / Linux / Raspberry Pi / NAS.

Everything is protected by a PIN that is printed when the server starts.
"""
import argparse
import hashlib
import hmac
import http.server
import json
import mimetypes
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse

VERSION = "1.0.0"

UNIT_ORDER = ["days", "hours", "minutes", "seconds"]
UNIT_SECONDS = {"days": 86400, "hours": 3600, "minutes": 60, "seconds": 1}
QUALITIES = {"best": 0, "1080p": 1080, "720p": 720, "480p": 480, "360p": 360}
MEDIA_EXT = (".mp3", ".mp4", ".m4a")
MAX_JSON = 64 * 1024

WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")


# --------------------------------------------------------------------------- helpers
def clean_name(name):
    """File name chosen by the user: no extension, no characters Windows/Android reject."""
    n = (name or "").strip()
    n = re.sub(r"(?i)\.(mp3|mp4)$", "", n)
    n = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", n)
    return n.strip(" .")[:150]


def clean_subfolder(name):
    """One folder name below the output folder - never a path."""
    n = (name or "").strip()
    n = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", n).strip(" .")
    if n in ("", ".", ".."):
        return ""
    return n[:80]


def normalize_url(text):
    """Return a clean http(s) URL, or None if the text does not look like a link."""
    u = (text or "").strip()
    if re.match(r"(?i)^(www\.|m\.|music\.)?(youtube\.com|youtu\.be)/", u):
        u = "https://" + u
    if re.match(r"(?i)^https?://[^\s]+$", u) and len(u) <= 2000:
        return u
    return None


def unit_smaller_than(first):
    """Units that may be chosen as the 'second' unit after `first` (strictly smaller)."""
    if first not in UNIT_ORDER:
        return []
    return UNIT_ORDER[UNIT_ORDER.index(first) + 1:]


def _int(value, lo, hi, default):
    try:
        v = int(value)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, v))


def normalize_span(a, u1, b, u2):
    """'a u1 + b u2' with u2 forced to be a smaller unit than u1 (or dropped)."""
    u1 = u1 if u1 in UNIT_ORDER else "hours"
    smaller = unit_smaller_than(u1)
    u2 = u2 if u2 in smaller else ""
    a = _int(a, 0, 9999, 0)
    b = _int(b, 0, 9999, 0) if u2 else 0
    return a, u1, b, u2


def span_seconds(a, u1, b, u2):
    a, u1, b, u2 = normalize_span(a, u1, b, u2)
    total = a * UNIT_SECONDS[u1]
    if u2:
        total += b * UNIT_SECONDS[u2]
    return total


def normalize_limit(d):
    d = d or {}
    a, u1, b, u2 = normalize_span(d.get("a", 1), d.get("u1"), d.get("b", 0), d.get("u2"))
    return {"count": _int(d.get("count", 0), 0, 1000, 0), "a": a, "u1": u1, "b": b, "u2": u2}


def next_allowed(start_times, limit, now):
    """None when a download may start now, otherwise the epoch time it may start."""
    count = limit["count"]
    window = span_seconds(limit["a"], limit["u1"], limit["b"], limit["u2"])
    if count <= 0 or window <= 0:
        return None
    recent = sorted(t for t in start_times if t > now - window)
    if len(recent) < count:
        return None
    return recent[len(recent) - count] + window


def build_args(job, out_dir, ffmpeg_dir=None):
    """yt-dlp arguments (without the program itself) for one queue item."""
    folder = os.path.join(out_dir, job["subfolder"]) if job.get("subfolder") else out_dir
    leaf = (job["name"].replace("%", "%%") + ".%(ext)s") if job.get("name") else "%(title)s.%(ext)s"
    args = []
    if job["kind"] == "mp4":
        cap = "[height<=?%d]" % job["height"] if job.get("height") else ""
        fmt = ("bv*[vcodec^=avc1]" + cap + "+ba[acodec^=mp4a]/b[ext=mp4]" + cap +
               "/bv*" + cap + "+ba/b" + cap)
        args += ["-f", fmt, "--merge-output-format", "mp4"]
    else:
        args += ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
    args += ["--no-playlist", "--newline", "--windows-filenames", "--embed-metadata"]
    if ffmpeg_dir:
        args += ["--ffmpeg-location", ffmpeg_dir]
    args += ["-o", os.path.join(folder, leaf), job["url"]]
    return args


_RE_PCT = re.compile(r"^\[download\]\s+([\d.]+)%")
_RE_DEST = re.compile(r"^\[download\] Destination: (.+)$")
_RE_EXTRACT = re.compile(r"^\[ExtractAudio\] Destination: (.+)$")
_RE_NOCONV = re.compile(r"^\[ExtractAudio\] Not converting audio (.+?); file is already in target format")
_RE_MERGE = re.compile(r'^\[Merger\] Merging formats into "(.+)"$')
_RE_HAVE = re.compile(r"^\[download\] (.+) has already been downloaded")


def _title_from(path):
    base = os.path.splitext(os.path.basename(path.replace("\\", "/")))[0]
    return re.sub(r"\.f\d+$", "", base)


def parse_line(line, job):
    """Update a job from one line of yt-dlp output."""
    line = line.rstrip("\r\n")
    if not line:
        return
    if line.startswith("ERROR"):
        job["error"] = re.sub(r"^ERROR:\s*", "", line)
        return
    m = _RE_PCT.match(line)
    if m:
        job["percent"] = float(m.group(1))
        job["text"] = "Downloading %s%%" % m.group(1)
        return
    m = _RE_DEST.match(line)
    if m:
        job["_dest"] = m.group(1)
        if not job.get("name"):
            job["display"] = _title_from(m.group(1))
        return
    m = _RE_MERGE.match(line)
    if m:
        job["text"] = "Joining video and audio..."
        job["percent"] = 100.0
        job["_final"] = m.group(1)
        if not job.get("name"):
            job["display"] = _title_from(m.group(1))
        return
    m = _RE_EXTRACT.match(line)
    if m:
        job["text"] = "Converting to MP3..."
        job["percent"] = 100.0
        job["_final"] = m.group(1)
        if not job.get("name"):
            job["display"] = _title_from(m.group(1))
        return
    m = _RE_NOCONV.match(line)
    if m:
        job["_final"] = m.group(1)
        return
    m = _RE_HAVE.match(line)
    if m:
        job["text"] = "Already downloaded"
        job["_dest"] = m.group(1)
        if not job.get("name"):
            job["display"] = _title_from(m.group(1))


def safe_eq(a, b):
    """Constant-time string compare that never raises on odd characters."""
    return hmac.compare_digest(str(a).encode("utf-8", "replace"), str(b).encode("utf-8", "replace"))


def kill_tree(proc):
    """Stop yt-dlp and anything it started (ffmpeg)."""
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           creationflags=0x08000000)
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except Exception:
        pass
    try:
        proc.kill()
    except Exception:
        pass


def find_ytdlp(explicit=None):
    """Command list that runs yt-dlp."""
    cand = explicit or os.environ.get("YTDLP_BIN")
    if cand:
        return [cand]
    found = shutil.which("yt-dlp")
    if found:
        return [found]
    here = os.path.dirname(os.path.abspath(__file__))
    for rel in ("..", "../..", "../../tools"):
        for exe in ("yt-dlp.exe", "yt-dlp"):
            p = os.path.join(here, rel, exe)
            if os.path.isfile(p):
                return [p]
    return [sys.executable, "-m", "yt_dlp"]


def default_out_dir():
    home = os.path.expanduser("~")
    termux = os.path.join(home, "storage", "downloads")
    if os.path.isdir(termux):
        return os.path.join(termux, "YouTubeDownloader")
    for sub in ("Downloads", ""):
        base = os.path.join(home, sub) if sub else home
        if os.path.isdir(base):
            return os.path.join(base, "YouTubeDownloader")
    return os.path.join(home, "YouTubeDownloader")


def default_data_dir():
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        return os.path.join(base, "YouTubeDownloader", "phone")
    return os.path.join(os.path.expanduser("~"), ".youtube-downloader")


# --------------------------------------------------------------------------- manager
class Manager:
    """The queue, the limit/pause rules and the single download worker."""

    def __init__(self, data_dir, out_dir, ytdlp_cmd, ffmpeg_dir=None, pin=None):
        self.data_dir = data_dir
        self.out_dir = os.path.abspath(out_dir)
        self.ytdlp = ytdlp_cmd
        self.ffmpeg_dir = ffmpeg_dir
        self.lock = threading.RLock()
        self.jobs = []
        self.counter = 0
        self.limit = normalize_limit({})
        self.start_times = []
        self.paused = False
        self.resume_at = None
        self.proc = None
        self.current = None
        self.stop = threading.Event()
        self.ytdlp_version = ""
        os.makedirs(self.data_dir, exist_ok=True)
        os.makedirs(self.out_dir, exist_ok=True)
        self.cfg = self._load_config(pin)
        self._load_state()
        self.thread = threading.Thread(target=self._worker, name="worker", daemon=True)

    # ---- config / auth ----------------------------------------------------------
    def _load_config(self, pin):
        path = os.path.join(self.data_dir, "config.json")
        cfg = {}
        try:
            with open(path, "r", encoding="utf-8") as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            cfg = {}
        changed = False
        if not cfg.get("secret"):
            cfg["secret"] = secrets.token_hex(32)
            changed = True
        if pin and cfg.get("pin") != str(pin):
            cfg["pin"] = str(pin)
            changed = True
        if not cfg.get("pin"):
            cfg["pin"] = "%06d" % secrets.randbelow(1000000)
            changed = True
        if changed:
            self._write_json(path, cfg)
        return cfg

    @property
    def pin(self):
        return self.cfg["pin"]

    def token(self):
        return hmac.new(self.cfg["secret"].encode(), self.cfg["pin"].encode(), hashlib.sha256).hexdigest()

    # ---- persistence ---------------------------------------------------------------
    @staticmethod
    def _write_json(path, data):
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.replace(tmp, path)

    def _state_path(self):
        return os.path.join(self.data_dir, "state.json")

    def _load_state(self):
        try:
            with open(self._state_path(), "r", encoding="utf-8") as f:
                st = json.load(f)
        except (OSError, ValueError):
            return
        self.limit = normalize_limit(st.get("limit"))
        self.start_times = [float(t) for t in st.get("start_times", []) if isinstance(t, (int, float))]
        self.paused = bool(st.get("paused"))
        ra = st.get("resume_at")
        self.resume_at = float(ra) if isinstance(ra, (int, float)) else None
        self.counter = int(st.get("counter", 0))
        for j in st.get("jobs", []):
            url = normalize_url(j.get("url"))
            if not url:
                continue
            self.jobs.append(self._new_job(url, j.get("kind", "mp3"), j.get("name", ""),
                                           j.get("height", 0), j.get("subfolder", ""),
                                           job_id=j.get("id")))

    def save(self):
        with self.lock:
            keep = [{"id": j["id"], "url": j["url"], "kind": j["kind"], "name": j["name"],
                     "height": j["height"], "subfolder": j["subfolder"]}
                    for j in self.jobs if j["status"] in ("queued", "downloading")]
            st = {"limit": self.limit, "start_times": self.start_times, "paused": self.paused,
                  "resume_at": self.resume_at, "counter": self.counter, "jobs": keep}
            try:
                self._write_json(self._state_path(), st)
            except OSError:
                pass

    # ---- queue operations --------------------------------------------------------------
    def _new_job(self, url, kind, name, height, subfolder, job_id=None):
        kind = "mp4" if kind == "mp4" else "mp3"
        if job_id is None:
            self.counter += 1
            job_id = self.counter
        else:
            self.counter = max(self.counter, int(job_id))
        return {"id": int(job_id), "url": url, "kind": kind, "name": clean_name(name),
                "height": height if height in QUALITIES.values() else 0,
                "subfolder": clean_subfolder(subfolder), "display": clean_name(name) or "",
                "text": "Queued", "status": "queued", "percent": 0.0, "error": "",
                "file": "", "created": time.time()}

    def add(self, urls, kinds, name="", quality="best", subfolder=""):
        """Queue every URL once per kind. Returns (added_ids, rejected_texts)."""
        good, bad = [], []
        for raw in urls:
            u = normalize_url(raw)
            (good if u else bad).append(u or raw)
        kinds = [k for k in ("mp3", "mp4") if isinstance(kinds, (list, tuple)) and k in kinds]
        if not kinds:
            raise ValueError("Choose MP3, MP4, or both.")
        name = clean_name(name)
        if name and len(good) > 1:
            raise ValueError("A custom name can only be used with one link at a time.")
        height = QUALITIES.get(quality, 0)
        ids = []
        with self.lock:
            for u in good:
                for k in kinds:
                    job = self._new_job(u, k, name, height, subfolder)
                    self.jobs.append(job)
                    ids.append(job["id"])
            self.save()
        return ids, bad

    def remove(self, ids):
        with self.lock:
            for jid in ids:
                job = self._find(jid)
                if not job:
                    continue
                if job is self.current:
                    job["_remove"] = True
                    self._cancel_current()
                else:
                    self.jobs.remove(job)
            self.save()

    def retry(self, ids):
        with self.lock:
            for jid in ids:
                job = self._find(jid)
                if job and job is not self.current and job["status"] in ("failed", "cancelled"):
                    job.update(status="queued", text="Queued", percent=0.0, error="")
            self.save()

    def clear_finished(self):
        with self.lock:
            self.jobs[:] = [j for j in self.jobs
                            if j is self.current or j["status"] not in ("done", "failed", "cancelled")]
            self.save()

    def _find(self, jid):
        for j in self.jobs:
            if j["id"] == jid:
                return j
        return None

    def _cancel_current(self):
        job, proc = self.current, self.proc
        if job is None:
            return
        job["status"] = "cancelled"
        job["text"] = "Cancelled"
        job["_cancel"] = True
        if proc is not None:
            kill_tree(proc)

    # ---- pause / limit -------------------------------------------------------------------
    def pause(self, until=None):
        with self.lock:
            self.paused = True
            self.resume_at = float(until) if until else None
            self.save()

    def resume(self):
        with self.lock:
            self.paused = False
            self.resume_at = None
            self.save()

    def set_limit(self, d):
        with self.lock:
            self.limit = normalize_limit(d)
            self.save()
            return self.limit

    # ---- worker ----------------------------------------------------------------------------
    def start(self):
        self.thread.start()
        threading.Thread(target=self._probe_version, daemon=True).start()

    def shutdown(self):
        self.stop.set()
        with self.lock:
            if self.proc is not None:
                kill_tree(self.proc)
            self.save()

    def _probe_version(self):
        try:
            out = subprocess.run(self.ytdlp + ["--version"], capture_output=True, text=True, timeout=20)
            self.ytdlp_version = (out.stdout or "").strip()[:40]
        except Exception:
            self.ytdlp_version = ""

    def _state_gate(self, now):
        """(may_start_now, message). Called with the lock held."""
        if self.paused and self.resume_at and now >= self.resume_at:
            self.paused = False
            self.resume_at = None
            self.save()
        if self.paused:
            return False, "paused"
        nxt = next_allowed(self.start_times, self.limit, now)
        if nxt:
            return False, "limit"
        return True, ""

    def _worker(self):
        while not self.stop.is_set():
            job = None
            with self.lock:
                queued = [j for j in self.jobs if j["status"] == "queued"]
                if queued:
                    ok, _ = self._state_gate(time.time())
                    if ok:
                        job = queued[0]
                        job["status"] = "downloading"
                        job["text"] = "Starting..."
                        self.current = job
                        self.start_times.append(time.time())
                        self.start_times = [t for t in self.start_times if t > time.time() - 90 * 86400]
                        self.save()
                else:
                    self._state_gate(time.time())   # lets a timed pause end while idle
            if job is None:
                self.stop.wait(0.4)
                continue
            try:
                self._download(job)
            except Exception as exc:      # never let the worker die
                job["status"] = "failed"
                job["text"] = "Failed: %s" % exc
            with self.lock:
                self.current = None
                self.proc = None
                if job.get("_remove") and job in self.jobs:
                    self.jobs.remove(job)
                self.save()

    def _download(self, job):
        cmd = self.ytdlp + build_args(job, self.out_dir, self.ffmpeg_dir)
        kwargs = {}
        if os.name == "nt":
            kwargs["creationflags"] = 0x08000000        # no console window
        else:
            kwargs["start_new_session"] = True
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, env=env, bufsize=1,
                                    universal_newlines=True, encoding="utf-8", errors="replace", **kwargs)
        except OSError as exc:
            job["status"] = "failed"
            job["text"] = "Failed: could not start yt-dlp (%s)" % exc
            return
        with self.lock:
            self.proc = proc
            if job.get("_cancel"):
                kill_tree(proc)
        for line in proc.stdout:
            if job.get("_cancel"):
                continue
            with self.lock:
                parse_line(line, job)
        code = proc.wait()
        try:
            proc.stdout.close()
        except OSError:
            pass
        with self.lock:
            if job.get("_cancel"):
                job["status"] = "cancelled"
                job["text"] = "Cancelled"
                return
            if code == 0:
                job["status"] = "done"
                job["text"] = "Done"
                job["percent"] = 100.0
                final = job.get("_final") or (job.get("_dest") if str(job.get("_dest", "")).lower().endswith(MEDIA_EXT) else "")
                job["file"] = self._relative(final)
            else:
                why = job.get("error") or "exit code %d" % code
                job["status"] = "failed"
                job["text"] = "Failed: " + (why[:90] + "..." if len(why) > 90 else why)

    def _relative(self, path):
        if not path:
            return ""
        full = os.path.abspath(path)
        try:
            if os.path.commonpath([full, self.out_dir]) != self.out_dir:
                return ""
        except ValueError:
            return ""
        return os.path.relpath(full, self.out_dir).replace(os.sep, "/")

    # ---- views -----------------------------------------------------------------------------------
    def snapshot(self):
        now = time.time()
        with self.lock:
            nxt = next_allowed(self.start_times, self.limit, now)
            jobs = [{k: v for k, v in j.items() if not k.startswith("_")} for j in self.jobs]
            waiting = sum(1 for j in self.jobs if j["status"] == "queued")
            return {
                "version": VERSION,
                "now": now,
                "jobs": jobs,
                "waiting": waiting,
                "paused": self.paused,
                "resume_at": self.resume_at,
                "limit": dict(self.limit),
                "limit_next": nxt,
                "out_dir": self.out_dir,
                "ytdlp": self.ytdlp_version,
                "busy": self.current["id"] if self.current else None,
            }

    def list_files(self, limit=300):
        out = []
        base_depth = self.out_dir.rstrip(os.sep).count(os.sep)
        for root, dirs, files in os.walk(self.out_dir):
            if root.count(os.sep) - base_depth >= 3:
                dirs[:] = []
            for fn in files:
                if not fn.lower().endswith(MEDIA_EXT):
                    continue
                full = os.path.join(root, fn)
                try:
                    st = os.stat(full)
                except OSError:
                    continue
                out.append({"path": os.path.relpath(full, self.out_dir).replace(os.sep, "/"),
                            "name": fn, "size": st.st_size, "mtime": st.st_mtime})
        out.sort(key=lambda f: f["mtime"], reverse=True)
        return out[:limit]

    def resolve_file(self, rel):
        """Absolute path of a file below the output folder, or None (blocks ../ tricks)."""
        rel = rel.replace("\\", "/")
        if "\x00" in rel or rel.startswith("/") or ":" in rel.split("/")[0]:
            return None
        full = os.path.realpath(os.path.join(self.out_dir, *rel.split("/")))
        root = os.path.realpath(self.out_dir)
        try:
            if os.path.commonpath([full, root]) != root:
                return None
        except ValueError:
            return None
        return full if os.path.isfile(full) else None

    def update_ytdlp(self):
        try:
            out = subprocess.run(self.ytdlp + ["-U"], capture_output=True, text=True, timeout=180)
            text = ((out.stdout or "") + (out.stderr or "")).strip()
        except Exception as exc:
            text = "Could not run the updater: %s" % exc
        self._probe_version()
        return text[-600:]


# --------------------------------------------------------------------------------- HTTP
STATIC = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
    "/sw.js": ("sw.js", "text/javascript; charset=utf-8"),
    "/icon-192.png": ("icon-192.png", "image/png"),
    "/icon-512.png": ("icon-512.png", "image/png"),
    "/apple-touch-icon.png": ("apple-touch-icon.png", "image/png"),
    "/favicon.ico": ("icon-192.png", "image/png"),
}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "YTDL/" + VERSION
    protocol_version = "HTTP/1.1"
    mgr = None            # set by make_server
    fails = {}            # ip -> (count, locked_until)
    fails_lock = threading.Lock()

    def log_message(self, fmt, *args):
        if os.environ.get("YTDL_VERBOSE"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # ---- plumbing --------------------------------------------------------------------------------
    def _send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if self.command == "POST" and not getattr(self, "_body_read", False):
            self.send_header("Connection", "close")
            self.close_connection = True
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json_error(self, code, message):
        self._send(code, {"error": message})

    def _cookie_token(self):
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "ytdl_token":
                return v
        return ""

    def _authed(self):
        m = self.mgr
        if safe_eq(self._cookie_token(), m.token()):
            return True
        pin = self.headers.get("X-PIN") or ""
        auth = self.headers.get("Authorization") or ""
        if auth.lower().startswith("bearer "):
            pin = auth[7:].strip()
        return bool(pin) and safe_eq(pin, m.pin)

    def _read_json(self):
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/json":
            self._json_error(415, "Send JSON (Content-Type: application/json).")
            return None
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0 or length > MAX_JSON:
            self._json_error(413, "Request too large.")
            return None
        raw = self.rfile.read(length)
        self._body_read = True
        try:
            data = json.loads(raw or b"{}")
        except ValueError:
            self._json_error(400, "Bad JSON.")
            return None
        if not isinstance(data, dict):
            self._json_error(400, "Expected a JSON object.")
            return None
        return data

    # ---- GET -------------------------------------------------------------------------------------
    def _guard(self, fn):
        """No request may crash a connection: unexpected errors become a clean 500."""
        try:
            fn()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception as exc:
            try:
                self._json_error(500, "Server error: %s" % type(exc).__name__)
            except Exception:
                self.close_connection = True

    def do_HEAD(self):
        self._guard(self._get)

    def do_GET(self):
        self._guard(self._get)

    def do_POST(self):
        self._guard(self._post)

    def _get(self):
        path = urllib.parse.urlsplit(self.path).path
        if path in STATIC:
            name, ctype = STATIC[path]
            try:
                with open(os.path.join(WEB_DIR, name), "rb") as f:
                    return self._send(200, f.read(), ctype)
            except OSError:
                return self._json_error(404, "Missing web file: " + name)
        if path == "/api/health":
            return self._send(200, {"ok": True, "app": "youtube-downloader", "version": VERSION})
        if not self._authed():
            return self._json_error(401, "PIN required.")
        if path == "/api/state":
            return self._send(200, self.mgr.snapshot())
        if path == "/api/files":
            return self._send(200, {"files": self.mgr.list_files()})
        if path.startswith("/files/"):
            return self._serve_file(urllib.parse.unquote(path[len("/files/"):]))
        return self._json_error(404, "Not found.")

    def _serve_file(self, rel):
        full = self.mgr.resolve_file(rel)
        if not full:
            return self._json_error(404, "File not found.")
        size = os.path.getsize(full)
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
            if m and (m.group(1) or m.group(2)):
                if m.group(1):
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else size - 1
                else:
                    start = max(0, size - int(m.group(2)))
                end = min(end, size - 1)
                if start > end or start >= size:
                    return self._send(416, b"", "text/plain", [("Content-Range", "bytes */%d" % size)])
                status = 206
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        fname = os.path.basename(full)
        disp = "attachment; filename*=UTF-8''" + urllib.parse.quote(fname)
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Disposition", disp)
        self.send_header("X-Content-Type-Options", "nosniff")
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(full, "rb") as f:
            f.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = f.read(min(65536, left))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    break
                left -= len(chunk)

    # ---- POST ------------------------------------------------------------------------------------
    def _post(self):
        self._body_read = False
        path = urllib.parse.urlsplit(self.path).path
        if path == "/api/login":
            return self._login()
        if not self._authed():
            return self._json_error(401, "PIN required.")
        data = self._read_json()
        if data is None:
            return
        m = self.mgr
        try:
            if path == "/api/add":
                urls = data.get("urls")
                if isinstance(urls, str):
                    urls = re.split(r"\s+", urls.strip())
                if not isinstance(urls, list):
                    return self._json_error(400, "urls must be a list.")
                urls = [str(u) for u in urls if str(u).strip()][:200]
                ids, bad = m.add(urls, data["kinds"] if "kinds" in data else ["mp3"], str(data.get("name") or ""),
                                 str(data.get("quality") or "best"), str(data.get("subfolder") or ""))
                if not ids:
                    return self._json_error(400, "No valid links found." + (" Skipped: " + ", ".join(bad[:3]) if bad else ""))
                return self._send(200, {"added": ids, "skipped": bad})
            if path == "/api/remove":
                m.remove([int(i) for i in data.get("ids", [])])
                return self._send(200, {"ok": True})
            if path == "/api/retry":
                m.retry([int(i) for i in data.get("ids", [])])
                return self._send(200, {"ok": True})
            if path == "/api/clear":
                m.clear_finished()
                return self._send(200, {"ok": True})
            if path == "/api/pause":
                mode = data.get("mode", "toggle")
                if mode == "resume" or (mode == "toggle" and m.paused):
                    m.resume()
                elif mode == "for":
                    secs = span_seconds(data.get("a", 0), data.get("u1"), data.get("b", 0), data.get("u2"))
                    if secs <= 0:
                        return self._json_error(400, "Enter how long to pause.")
                    m.pause(time.time() + secs)
                elif mode == "until":
                    until = float(data.get("until", 0))
                    if until <= time.time():
                        return self._json_error(400, "Pick a time in the future.")
                    m.pause(until)
                else:
                    m.pause(None)
                return self._send(200, m.snapshot())
            if path == "/api/limit":
                return self._send(200, {"limit": m.set_limit(data)})
            if path == "/api/update-ytdlp":
                return self._send(200, {"output": m.update_ytdlp(), "version": m.ytdlp_version})
        except (ValueError, TypeError) as exc:
            return self._json_error(400, str(exc))
        return self._json_error(404, "Not found.")

    def _login(self):
        ip = self.client_address[0]
        now = time.time()
        with self.fails_lock:
            count, until = self.fails.get(ip, (0, 0))
            if until > now:
                return self._json_error(429, "Too many wrong PINs. Wait %d seconds." % int(until - now + 1))
        data = self._read_json()
        if data is None:
            return
        pin = str(data.get("pin", "")).strip()
        if pin and safe_eq(pin, self.mgr.pin):
            with self.fails_lock:
                self.fails.pop(ip, None)
            cookie = "ytdl_token=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000" % self.mgr.token()
            return self._send(200, {"ok": True}, extra=[("Set-Cookie", cookie)])
        with self.fails_lock:
            count += 1
            self.fails[ip] = (count, now + 60 if count >= 5 else 0)
        return self._json_error(401, "Wrong PIN.")


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_server(mgr, bind, port):
    handler = type("BoundHandler", (Handler,), {"mgr": mgr, "fails": {}, "fails_lock": threading.Lock()})
    return Server((bind, port), handler)


def lan_addresses():
    addrs = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        addrs.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            if ip not in addrs and not ip.startswith("127."):
                addrs.append(ip)
    except OSError:
        pass
    return addrs


def main(argv=None):
    ap = argparse.ArgumentParser(description="YouTube Downloader - phone edition server")
    ap.add_argument("--port", type=int, default=int(os.environ.get("YTDL_PORT", 8765)))
    ap.add_argument("--bind", default=os.environ.get("YTDL_BIND", "0.0.0.0"),
                    help="0.0.0.0 = reachable from your phone on the same Wi-Fi; 127.0.0.1 = this device only")
    ap.add_argument("--out", default=os.environ.get("YTDL_OUT") or default_out_dir(), help="folder for the downloaded files")
    ap.add_argument("--data", default=os.environ.get("YTDL_DATA") or default_data_dir(), help="folder for settings and queue")
    ap.add_argument("--yt-dlp", dest="ytdlp", default=None, help="path to yt-dlp (default: auto-detect)")
    ap.add_argument("--ffmpeg-location", dest="ffmpeg", default=os.environ.get("FFMPEG_DIR"), help="folder that contains ffmpeg")
    ap.add_argument("--pin", default=os.environ.get("YTDL_PIN"), help="set the PIN (default: random 6 digits, kept between runs)")
    args = ap.parse_args(argv)

    mgr = Manager(args.data, args.out, find_ytdlp(args.ytdlp), args.ffmpeg, args.pin)
    try:
        httpd = make_server(mgr, args.bind, args.port)
    except OSError as exc:
        print("Could not listen on %s:%d - %s" % (args.bind, args.port, exc))
        return 2
    mgr.start()

    print("=" * 60)
    print(" YouTube Downloader - phone edition %s" % VERSION)
    print("=" * 60)
    print(" Open this on your phone (same Wi-Fi):")
    if args.bind in ("0.0.0.0", ""):
        for ip in lan_addresses() or ["<this device's IP>"]:
            print("     http://%s:%d" % (ip, args.port))
    else:
        print("     http://%s:%d" % (args.bind, args.port))
    print("     (on this device: http://127.0.0.1:%d)" % args.port)
    print()
    print(" PIN: %s" % mgr.pin)
    print(" Saving files to: %s" % mgr.out_dir)
    print(" Keep this window open. Press Ctrl+C to stop.")
    print("=" * 60, flush=True)

    def _stop(*_):
        threading.Thread(target=httpd.shutdown, daemon=True).start()
    try:
        signal.signal(signal.SIGTERM, _stop)
    except (ValueError, OSError):
        pass
    try:
        httpd.serve_forever(poll_interval=0.3)
    except KeyboardInterrupt:
        pass
    finally:
        mgr.shutdown()
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
