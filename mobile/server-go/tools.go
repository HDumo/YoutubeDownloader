package main

import (
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// ---- finding yt-dlp and ffmpeg ---------------------------------------------------------

// A Mac app started from Finder has a tiny PATH, so Homebrew's folders are searched explicitly.
func extraBinDirs() []string {
	home, _ := os.UserHomeDir()
	return []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", filepath.Join(home, ".local", "bin")}
}

func exeName(n string) string {
	if runtime.GOOS == "windows" {
		return n + ".exe"
	}
	return n
}

func isFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func lookTool(name string) string {
	if os.Getenv("YTDL_NO_SYSTEM_TOOLS") != "" { // test hook: pretend nothing is installed system-wide
		return ""
	}
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	for _, d := range extraBinDirs() {
		if p := filepath.Join(d, exeName(name)); isFile(p) {
			return p
		}
	}
	return ""
}

func (m *Manager) findYtdlp() string {
	if m.ytdlpFlag != "" {
		return m.ytdlpFlag
	}
	if e := os.Getenv("YTDLP_BIN"); e != "" {
		return e
	}
	if p := filepath.Join(m.toolsDir, exeName("yt-dlp")); isFile(p) {
		return p
	}
	return lookTool("yt-dlp")
}

func (m *Manager) findFfmpegLoc() string {
	if m.ffmpegFlag != "" {
		return m.ffmpegFlag
	}
	if e := os.Getenv("FFMPEG_DIR"); e != "" {
		return e
	}
	if isFile(filepath.Join(m.toolsDir, exeName("ffmpeg"))) {
		return m.toolsDir
	}
	if p := lookTool("ffmpeg"); p != "" {
		return filepath.Dir(p)
	}
	return ""
}

// resolveTools returns the command that runs yt-dlp, the ffmpeg folder to pass, and whether we can download.
// A user who passes --yt-dlp manages their own tools, so ffmpeg is then not required.
func (m *Manager) resolveTools() ([]string, string, bool) {
	yt := m.findYtdlp()
	if yt == "" {
		return nil, "", false
	}
	ff := m.findFfmpegLoc()
	if ff == "" && m.ytdlpFlag == "" {
		return nil, "", false
	}
	return []string{yt}, ff, true
}

// ---- first-run download -----------------------------------------------------------------

// SetupState is what the web app shows while the helper programs are fetched.
type SetupState struct {
	State     string  `json:"state"` // ready | needed | running | error | unsupported
	Text      string  `json:"text"`
	Percent   float64 `json:"percent"`
	Error     string  `json:"error"`
	Supported bool    `json:"supported"`
}

type toolSetup struct {
	m       *Manager
	mu      sync.Mutex
	running bool
	text    string
	percent float64
	err     string
}

func newToolSetup(m *Manager) *toolSetup { return &toolSetup{m: m} }

func toolURLs() (ytdlp, ffmpeg string, ok bool) {
	ytdlp, ffmpeg = os.Getenv("YTDL_YTDLP_URL"), os.Getenv("YTDL_FFMPEG_URL")
	if ytdlp != "" && ffmpeg != "" {
		return ytdlp, ffmpeg, true
	}
	const yt = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
	const ff = "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.0/"
	switch runtime.GOOS + "/" + runtime.GOARCH {
	case "darwin/arm64":
		return yt + "yt-dlp_macos", ff + "ffmpeg-darwin-arm64.gz", true
	case "darwin/amd64":
		return yt + "yt-dlp_macos", ff + "ffmpeg-darwin-x64.gz", true
	case "linux/amd64":
		return yt + "yt-dlp_linux", ff + "ffmpeg-linux-x64.gz", true
	case "linux/arm64":
		return yt + "yt-dlp_linux_aarch64", ff + "ffmpeg-linux-arm64.gz", true
	}
	return "", "", false
}

func (t *toolSetup) status() SetupState {
	t.mu.Lock()
	defer t.mu.Unlock()
	_, _, supported := toolURLs()
	_, _, have := t.m.resolveTools()
	switch {
	case t.running:
		return SetupState{State: "running", Text: t.text, Percent: t.percent, Supported: supported}
	case have:
		return SetupState{State: "ready", Supported: supported}
	case t.err != "":
		return SetupState{State: "error", Error: t.err, Supported: supported}
	case !supported:
		return SetupState{State: "unsupported", Supported: false}
	}
	return SetupState{State: "needed", Supported: true}
}

// start downloads whatever is missing in the background (no-op if already running or nothing is missing).
func (t *toolSetup) start() {
	t.mu.Lock()
	if t.running {
		t.mu.Unlock()
		return
	}
	if _, _, have := t.m.resolveTools(); have {
		t.mu.Unlock()
		return
	}
	ytURL, ffURL, ok := toolURLs()
	if !ok {
		t.mu.Unlock()
		return
	}
	t.running, t.err, t.percent, t.text = true, "", 0, "Starting..."
	t.mu.Unlock()
	go func() {
		err := t.run(ytURL, ffURL)
		t.mu.Lock()
		t.running = false
		if err != nil {
			t.err = err.Error()
		}
		t.mu.Unlock()
		go t.m.probeVersion()
	}()
}

func (t *toolSetup) set(text string, pct float64) {
	t.mu.Lock()
	t.text, t.percent = text, pct
	t.mu.Unlock()
}

func (t *toolSetup) run(ytURL, ffURL string) error {
	if err := os.MkdirAll(t.m.toolsDir, 0o755); err != nil {
		return err
	}
	ytPath := filepath.Join(t.m.toolsDir, exeName("yt-dlp"))
	ffPath := filepath.Join(t.m.toolsDir, exeName("ffmpeg"))
	if t.m.findYtdlp() == "" {
		if err := t.fetch("Downloading yt-dlp (the YouTube engine)...", ytURL, ytPath, 0, 50); err != nil {
			return fmt.Errorf("yt-dlp: %v", err)
		}
		if err := verifyRuns(ytPath, "--version"); err != nil {
			return fmt.Errorf("yt-dlp downloaded but does not start: %v", err)
		}
	}
	if t.m.ytdlpFlag == "" && t.m.findFfmpegLoc() == "" {
		if err := t.fetch("Downloading ffmpeg (audio/video converter)...", ffURL, ffPath, 50, 100); err != nil {
			return fmt.Errorf("ffmpeg: %v", err)
		}
		if err := verifyRuns(ffPath, "-version"); err != nil {
			return fmt.Errorf("ffmpeg downloaded but does not start: %v", err)
		}
	}
	return nil
}

type countReader struct {
	r io.Reader
	n int64
	f func(int64)
}

func (c *countReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += int64(n)
	c.f(c.n)
	return n, err
}

// fetch downloads url to dest (decompressing .gz), marks it executable and reports progress between lo..hi percent.
func (t *toolSetup) fetch(label, url, dest string, lo, hi float64) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download failed (HTTP %d)", resp.StatusCode)
	}
	t.set(label, lo)
	total := resp.ContentLength
	cr := &countReader{r: resp.Body, f: func(n int64) {
		if total > 0 {
			t.set(label, lo+(hi-lo)*float64(n)/float64(total))
		}
	}}
	tmp := dest + ".part"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	var src io.Reader = cr
	if strings.HasSuffix(strings.ToLower(strings.SplitN(url, "?", 2)[0]), ".gz") {
		gz, gerr := gzip.NewReader(cr)
		if gerr != nil {
			out.Close()
			return gerr
		}
		defer gz.Close()
		src = gz
	}
	if _, err := io.Copy(out, src); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o755); err != nil {
		return err
	}
	if runtime.GOOS == "darwin" {
		_ = exec.Command("xattr", "-d", "com.apple.quarantine", tmp).Run()
	}
	return os.Rename(tmp, dest)
}

// verifyRuns checks the program starts. On a Mac, a binary that macOS refuses to run is ad-hoc signed once and retried.
func verifyRuns(path string, arg string) error {
	try := func() error {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		return exec.CommandContext(ctx, path, arg).Run()
	}
	err := try()
	if err != nil && runtime.GOOS == "darwin" {
		_ = exec.Command("codesign", "--force", "--sign", "-", path).Run()
		err = try()
	}
	return err
}
