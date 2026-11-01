// YouTube Downloader - computer edition server (Go).
//
// Same API and web app as mobile/server/ytdl_server.py, but one self-contained binary that needs no Python.
// It powers the macOS app. Run with --help for the options.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

func defaultDataDir() string {
	home, _ := os.UserHomeDir()
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support", "YouTube Downloader")
	}
	return filepath.Join(home, ".youtube-downloader")
}

func defaultOutDir() string {
	home, _ := os.UserHomeDir()
	if d := filepath.Join(home, "Downloads"); isDir(d) {
		return filepath.Join(d, "YouTubeDownloader")
	}
	return filepath.Join(home, "YouTubeDownloader")
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func openURL(u string) {
	var c *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		c = exec.Command("open", u)
	case "windows":
		c = exec.Command("cmd", "/c", "start", "", u)
	default:
		c = exec.Command("xdg-open", u)
	}
	if err := c.Start(); err != nil {
		fmt.Println(" Open this address in your browser:", u)
		return
	}
	// Give the opener a moment to finish (a second copy of the app exits right after calling this).
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
	}
}

// openRunningInstance is used when a second copy is started: ask the first one for a sign-in link and open it.
func openRunningInstance(port int, dataDir string) bool {
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/api/health", port))
	if err != nil {
		return false
	}
	var h struct {
		App string `json:"app"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&h)
	resp.Body.Close()
	if h.App != "youtube-downloader" {
		return false
	}
	base := fmt.Sprintf("http://127.0.0.1:%d", port)
	var cfg config
	if b, err := os.ReadFile(filepath.Join(dataDir, "config.json")); err == nil {
		_ = json.Unmarshal(b, &cfg)
	}
	req, _ := http.NewRequest("POST", base+"/api/local-token", strings.NewReader("{}"))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-PIN", cfg.Pin)
	r2, err := client.Do(req)
	if err == nil && r2.StatusCode == 200 {
		var t struct {
			URL string `json:"url"`
		}
		_ = json.NewDecoder(r2.Body).Decode(&t)
		r2.Body.Close()
		if t.URL != "" {
			openURL(base + t.URL)
			return true
		}
	}
	openURL(base + "/")
	return true
}

// runMenubar starts the Mac menu-bar helper and acts on the commands it prints (open / pause / resume / quit).
func runMenubar(s *Server, script string) *exec.Cmd {
	var cmd *exec.Cmd
	if runtime.GOOS == "darwin" {
		cmd = exec.Command("osascript", "-l", "JavaScript", script, fmt.Sprint(s.port))
	} else {
		cmd = exec.Command(script, fmt.Sprint(s.port))
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil
	}
	if err := cmd.Start(); err != nil {
		fmt.Println(" (menu bar helper could not start:", err, ")")
		return nil
	}
	go func() {
		sc := bufio.NewScanner(out)
		for sc.Scan() {
			switch strings.TrimSpace(sc.Text()) {
			case "open":
				openURL(fmt.Sprintf("http://127.0.0.1:%d/local-login?t=%s", s.port, s.mintLocalToken()))
			case "pause":
				s.m.pause(nil)
			case "resume":
				s.m.resume()
			case "quit":
				s.requestQuit()
			}
		}
		_, _ = io.Copy(io.Discard, out)
	}()
	go func() { _ = cmd.Wait() }()
	return cmd
}

func main() {
	var (
		port       = flag.Int("port", envInt("YTDL_PORT", 8765), "port to listen on")
		bind       = flag.String("bind", os.Getenv("YTDL_BIND"), "address to listen on (default: this computer only, or the Wi-Fi when enabled in Settings)")
		out        = flag.String("out", os.Getenv("YTDL_OUT"), "folder for the downloaded files")
		data       = flag.String("data", envStr("YTDL_DATA", defaultDataDir()), "folder for settings and queue")
		ytdlp      = flag.String("yt-dlp", "", "path to yt-dlp (default: auto-detect, or download it)")
		ffmpeg     = flag.String("ffmpeg-location", os.Getenv("FFMPEG_DIR"), "folder that contains ffmpeg")
		pin        = flag.String("pin", os.Getenv("YTDL_PIN"), "set the PIN (default: random 6 digits, kept between runs)")
		openBrowse = flag.Bool("open", false, "open the app in your browser (signed in) once the server is running")
		background = flag.Bool("background", false, "start quietly (used when starting at login)")
		menubar    = flag.String("menubar", "", "path of the Mac menu-bar helper script")
		noSetup    = flag.Bool("no-setup", false, "do not download yt-dlp / ffmpeg automatically")
		macFeat    = flag.Bool("mac-features", runtime.GOOS == "darwin" || os.Getenv("YTDL_MAC_FEATURES") != "", "enable Mac-only settings (start at login)")
		showVer    = flag.Bool("version", false, "print the version and exit")
	)
	flag.Parse()
	if *showVer {
		fmt.Println("ytdl-server", version)
		return
	}

	m, err := newManager(*data, *out, *ytdlp, *ffmpeg, *pin)
	if err != nil {
		fmt.Println("Could not start:", err)
		os.Exit(2)
	}
	s := newServer(m, *port, *macFeat)
	s.logPath = filepath.Join(*data, "server.log")
	s.extraArgs = []string{"--background"}
	if *menubar != "" {
		s.extraArgs = append(s.extraArgs, "--menubar", *menubar) // so the menu-bar icon also appears when started at login
	}
	if *data != defaultDataDir() {
		s.extraArgs = append(s.extraArgs, "--data", *data)
	}

	addr := bindAddr(m.cfg.Lan, *port, *bind)
	if err := s.listen(addr); err != nil {
		if (*openBrowse || *background) && openRunningInstance(*port, *data) {
			return // already running: just showed the existing app
		}
		fmt.Printf("Could not listen on %s - %v\n", addr, err)
		os.Exit(2)
	}
	m.start()
	if !*noSetup {
		m.setup.start()
	}

	fmt.Println(strings.Repeat("=", 60))
	fmt.Printf(" YouTube Downloader - computer edition %s\n", version)
	fmt.Println(strings.Repeat("=", 60))
	fmt.Printf("   on this computer: http://127.0.0.1:%d\n", *port)
	if m.cfg.Lan || strings.HasPrefix(addr, "0.0.0.0") {
		fmt.Println("   from your phone (same Wi-Fi):")
		for _, u := range lanURLs(*port) {
			fmt.Println("     " + u)
		}
	}
	fmt.Println()
	fmt.Println(" PIN:", m.pin())
	fmt.Println(" Saving files to:", m.outDir)
	fmt.Println(strings.Repeat("=", 60))

	var menu *exec.Cmd
	if *menubar != "" && isFile(*menubar) {
		menu = runMenubar(s, *menubar)
	}
	if *openBrowse && !*background {
		openURL(fmt.Sprintf("http://127.0.0.1:%d/local-login?t=%s", *port, s.mintLocalToken()))
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	select {
	case <-sig:
	case <-s.quit:
	}
	if menu != nil && menu.Process != nil {
		_ = menu.Process.Kill()
	}
	s.closeAll()
	m.shutdown()
}

func envStr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	var n int
	if _, err := fmt.Sscan(os.Getenv(k), &n); err == nil && n > 0 {
		return n
	}
	return def
}
