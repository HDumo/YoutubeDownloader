package main

import (
	"bytes"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"
)

//go:embed web
var webFS embed.FS

const maxJSON = 64 * 1024

var staticFiles = map[string][2]string{
	"/":                     {"index.html", "text/html; charset=utf-8"},
	"/index.html":           {"index.html", "text/html; charset=utf-8"},
	"/app.js":               {"app.js", "text/javascript; charset=utf-8"},
	"/style.css":            {"style.css", "text/css; charset=utf-8"},
	"/manifest.webmanifest": {"manifest.webmanifest", "application/manifest+json"},
	"/sw.js":                {"sw.js", "text/javascript; charset=utf-8"},
	"/icon-192.png":         {"icon-192.png", "image/png"},
	"/icon-512.png":         {"icon-512.png", "image/png"},
	"/apple-touch-icon.png": {"apple-touch-icon.png", "image/png"},
	"/favicon.ico":          {"icon-192.png", "image/png"},
}

// Features tells the web app which extra (computer-only) controls this server supports.
type Features struct {
	Autostart bool `json:"autostart"`
	Quit      bool `json:"quit"`
	Lan       bool `json:"lan"`
	Folder    bool `json:"folder"`
	Chooser   bool `json:"chooser"`
	Setup     bool `json:"setup"`
}

// State is the JSON the web app polls.
type State struct {
	Version   string     `json:"version"`
	Impl      string     `json:"impl"`
	Platform  string     `json:"platform"`
	Now       float64    `json:"now"`
	Jobs      []Job      `json:"jobs"`
	Waiting   int        `json:"waiting"`
	Paused    bool       `json:"paused"`
	ResumeAt  *float64   `json:"resume_at"`
	Limit     Limit      `json:"limit"`
	LimitNext *float64   `json:"limit_next"`
	OutDir    string     `json:"out_dir"`
	Ytdlp     string     `json:"ytdlp"`
	Busy      *int       `json:"busy"`
	Features  Features   `json:"features"`
	IsLocal   bool       `json:"is_local"`
	Pin       string     `json:"pin,omitempty"`
	Lan       bool       `json:"lan"`
	LanURLs   []string   `json:"lan_urls"`
	Autostart bool       `json:"autostart"`
	Setup     SetupState `json:"setup"`
}

type failInfo struct {
	count int
	until time.Time
}

// Server is the HTTP side: login, routes, and the (re)bindable listener.
type Server struct {
	m         *Manager
	port      int
	macMode   bool
	exe       string
	extraArgs []string
	logPath   string

	mu      sync.Mutex
	ln      net.Listener
	addr    string
	servers []*http.Server

	failMu sync.Mutex
	fails  map[string]*failInfo

	tokMu  sync.Mutex
	tokens map[string]time.Time

	quit     chan struct{}
	quitOnce sync.Once
}

func newServer(m *Manager, port int, macMode bool) *Server {
	exe, _ := os.Executable()
	return &Server{m: m, port: port, macMode: macMode, exe: exe, fails: map[string]*failInfo{},
		tokens: map[string]time.Time{}, quit: make(chan struct{})}
}

func (s *Server) requestQuit() { s.quitOnce.Do(func() { close(s.quit) }) }

// ---- listening ---------------------------------------------------------------------------

func (s *Server) serveLocked(ln net.Listener, addr string) {
	s.ln, s.addr = ln, addr
	srv := &http.Server{Handler: s, ReadHeaderTimeout: 15 * time.Second}
	s.servers = append(s.servers, srv)
	go func() { _ = srv.Serve(ln) }()
}

func (s *Server) listen(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.serveLocked(ln, addr)
	s.mu.Unlock()
	return nil
}

// rebind switches between "this computer only" and "every device on the Wi-Fi" without restarting.
func (s *Server) rebind(addr string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	old, oldAddr := s.ln, s.addr
	if old != nil {
		_ = old.Close() // stop accepting; requests already running (like this one) finish normally
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		if old != nil {
			if ln2, e2 := net.Listen("tcp", oldAddr); e2 == nil {
				s.serveLocked(ln2, oldAddr)
			}
		}
		return err
	}
	s.serveLocked(ln, addr)
	return nil
}

func (s *Server) closeAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, srv := range s.servers {
		_ = srv.Close()
	}
}

func bindAddr(lan bool, port int, explicit string) string {
	host := "127.0.0.1"
	if explicit != "" {
		host = explicit
	} else if lan {
		host = "0.0.0.0"
	}
	return net.JoinHostPort(host, fmt.Sprint(port))
}

func lanURLs(port int) []string {
	out := []string{}
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil && !ipn.IP.IsLoopback() && !ipn.IP.IsLinkLocalUnicast() {
			out = append(out, fmt.Sprintf("http://%s:%d", ipn.IP, port))
		}
	}
	return out
}

// ---- helpers --------------------------------------------------------------------------------

func isLoopback(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func setCommonHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
}

func sendJSON(w http.ResponseWriter, code int, v interface{}) {
	setCommonHeaders(w)
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(buf.Bytes())
}

func jsonError(w http.ResponseWriter, code int, msg string) {
	sendJSON(w, code, map[string]string{"error": msg})
}

func safeEq(a, b string) bool { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }

func (s *Server) authed(r *http.Request) bool {
	if c, err := r.Cookie("ytdl_token"); err == nil && safeEq(c.Value, s.m.token()) {
		return true
	}
	pin := r.Header.Get("X-PIN")
	if a := r.Header.Get("Authorization"); len(a) > 7 && strings.EqualFold(a[:7], "bearer ") {
		pin = strings.TrimSpace(a[7:])
	}
	return pin != "" && safeEq(pin, s.m.pin())
}

func readJSON(w http.ResponseWriter, r *http.Request) (map[string]interface{}, bool) {
	ct := strings.ToLower(strings.TrimSpace(strings.SplitN(r.Header.Get("Content-Type"), ";", 2)[0]))
	if ct != "application/json" {
		jsonError(w, 415, "Send JSON (Content-Type: application/json).")
		return nil, false
	}
	if r.ContentLength > maxJSON {
		jsonError(w, 413, "Request too large.")
		return nil, false
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxJSON))
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			jsonError(w, 413, "Request too large.")
		} else {
			jsonError(w, 400, "Bad JSON.")
		}
		return nil, false
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return map[string]interface{}{}, true
	}
	var v interface{}
	if json.Unmarshal(raw, &v) != nil {
		jsonError(w, 400, "Bad JSON.")
		return nil, false
	}
	obj, ok := v.(map[string]interface{})
	if !ok {
		jsonError(w, 400, "Expected a JSON object.")
		return nil, false
	}
	return obj, true
}

func (s *Server) state(r *http.Request) State {
	m := s.m
	now := now()
	m.mu.Lock()
	jobs := make([]Job, 0, len(m.jobs))
	waiting := 0
	for _, j := range m.jobs {
		jobs = append(jobs, *j)
		if j.Status == "queued" {
			waiting++
		}
	}
	var next *float64
	if n := nextAllowed(m.startTimes, m.limit, now); n != 0 {
		next = &n
	}
	var busy *int
	if m.current != nil {
		id := m.current.ID
		busy = &id
	}
	st := State{Version: version, Impl: "go", Platform: runtime.GOOS, Now: now, Jobs: jobs, Waiting: waiting,
		Paused: m.paused, ResumeAt: m.resumeAt, Limit: m.limit, LimitNext: next, OutDir: m.outDir,
		Ytdlp: m.ytdlpVer, Busy: busy, Lan: m.cfg.Lan, LanURLs: []string{}}
	pin := m.cfg.Pin
	m.mu.Unlock()
	st.IsLocal = isLoopback(r)
	st.Features = Features{Autostart: s.macMode, Quit: true, Lan: true, Folder: true, Chooser: runtime.GOOS == "darwin", Setup: true}
	if st.IsLocal {
		st.Pin = pin
	}
	if st.Lan {
		st.LanURLs = lanURLs(s.port)
	}
	st.Autostart = s.macMode && autostartEnabled()
	st.Setup = m.setup.status()
	return st
}

// ---- routing -----------------------------------------------------------------------------------

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	defer func() {
		if rec := recover(); rec != nil {
			jsonError(w, 500, "Server error")
		}
	}()
	p := r.URL.Path
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		s.get(w, r, p)
		return
	}
	if r.Method == http.MethodPost {
		s.post(w, r, p)
		return
	}
	jsonError(w, 405, "Method not allowed.")
}

func (s *Server) get(w http.ResponseWriter, r *http.Request, p string) {
	if f, ok := staticFiles[p]; ok {
		b, err := webFS.ReadFile("web/" + f[0])
		if err != nil {
			jsonError(w, 404, "Missing web file: "+f[0])
			return
		}
		setCommonHeaders(w)
		w.Header().Set("Content-Type", f[1])
		_, _ = w.Write(b)
		return
	}
	switch p {
	case "/api/health":
		sendJSON(w, 200, map[string]interface{}{"ok": true, "app": "youtube-downloader", "version": version})
		return
	case "/local-login":
		s.localLogin(w, r)
		return
	}
	if !s.authed(r) {
		jsonError(w, 401, "PIN required.")
		return
	}
	switch {
	case p == "/api/state":
		sendJSON(w, 200, s.state(r))
	case p == "/api/files":
		sendJSON(w, 200, map[string]interface{}{"files": s.m.listFiles(300)})
	case strings.HasPrefix(p, "/files/"):
		s.serveFile(w, r, strings.TrimPrefix(p, "/files/"))
	default:
		jsonError(w, 404, "Not found.")
	}
}

func (s *Server) serveFile(w http.ResponseWriter, r *http.Request, rel string) {
	full := s.m.resolveFile(rel) // r.URL.Path is already percent-decoded
	if full == "" {
		jsonError(w, 404, "File not found.")
		return
	}
	f, err := os.Open(full)
	if err != nil {
		jsonError(w, 404, "File not found.")
		return
	}
	defer f.Close()
	st, _ := f.Stat()
	ctype := mime.TypeByExtension(strings.ToLower(filepath.Ext(full)))
	if ctype == "" {
		ctype = "application/octet-stream"
	}
	h := w.Header()
	h.Set("Content-Type", ctype)
	h.Set("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(filepath.Base(full)))
	h.Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, "", st.ModTime(), f)
}

// ---- login -------------------------------------------------------------------------------------

func (s *Server) cookieFor() string {
	return fmt.Sprintf("ytdl_token=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000", s.m.token())
}

func clientIP(r *http.Request) string {
	h, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return h
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	s.failMu.Lock()
	fi := s.fails[ip]
	if fi != nil && time.Now().Before(fi.until) {
		left := int(time.Until(fi.until).Seconds()) + 1
		s.failMu.Unlock()
		jsonError(w, 429, fmt.Sprintf("Too many wrong PINs. Wait %d seconds.", left))
		return
	}
	s.failMu.Unlock()
	data, ok := readJSON(w, r)
	if !ok {
		return
	}
	pin := strings.TrimSpace(str(data["pin"]))
	if pin != "" && safeEq(pin, s.m.pin()) {
		s.failMu.Lock()
		delete(s.fails, ip)
		s.failMu.Unlock()
		w.Header().Set("Set-Cookie", s.cookieFor())
		sendJSON(w, 200, map[string]bool{"ok": true})
		return
	}
	s.failMu.Lock()
	if s.fails[ip] == nil {
		s.fails[ip] = &failInfo{}
	}
	s.fails[ip].count++
	if s.fails[ip].count >= 5 {
		s.fails[ip].until = time.Now().Add(60 * time.Second)
	}
	s.failMu.Unlock()
	jsonError(w, 401, "Wrong PIN.")
}

// mintLocalToken makes a one-time sign-in link for the browser on this computer (so no PIN typing).
func (s *Server) mintLocalToken() string {
	t := randomHex(24)
	s.tokMu.Lock()
	defer s.tokMu.Unlock()
	for k, exp := range s.tokens {
		if time.Now().After(exp) {
			delete(s.tokens, k)
		}
	}
	s.tokens[t] = time.Now().Add(2 * time.Minute)
	return t
}

func (s *Server) localLogin(w http.ResponseWriter, r *http.Request) {
	host := strings.ToLower(r.Host)
	okHost := host == fmt.Sprintf("127.0.0.1:%d", s.port) || host == fmt.Sprintf("localhost:%d", s.port)
	if !isLoopback(r) || !okHost {
		jsonError(w, 403, "This sign-in link only works on the computer running the downloader.")
		return
	}
	t := r.URL.Query().Get("t")
	s.tokMu.Lock()
	exp, found := s.tokens[t]
	delete(s.tokens, t) // single use
	s.tokMu.Unlock()
	if t == "" || !found || time.Now().After(exp) {
		jsonError(w, 403, "That sign-in link expired. Open the app again.")
		return
	}
	setCommonHeaders(w)
	w.Header().Set("Set-Cookie", s.cookieFor())
	w.Header().Set("Location", "/")
	w.WriteHeader(302)
}

// ---- POST routes -------------------------------------------------------------------------------

var reSpace = regexp.MustCompile(`\s+`)

func idList(v interface{}) ([]int, bool) {
	out := []int{}
	if v == nil {
		return out, true
	}
	list, ok := v.([]interface{})
	if !ok {
		return nil, false
	}
	for _, x := range list {
		f, ok := x.(float64)
		if !ok {
			return nil, false
		}
		out = append(out, int(f))
	}
	return out, true
}

func (s *Server) post(w http.ResponseWriter, r *http.Request, p string) {
	if p == "/api/login" {
		s.login(w, r)
		return
	}
	if !s.authed(r) {
		jsonError(w, 401, "PIN required.")
		return
	}
	data, ok := readJSON(w, r)
	if !ok {
		return
	}
	m := s.m
	switch p {
	case "/api/add":
		var urls []string
		switch u := data["urls"].(type) {
		case string:
			for _, x := range reSpace.Split(strings.TrimSpace(u), -1) {
				if x != "" {
					urls = append(urls, x)
				}
			}
		case []interface{}:
			for _, x := range u {
				sx := fmt.Sprint(x)
				if strings.TrimSpace(sx) != "" {
					urls = append(urls, sx)
				}
			}
		default:
			jsonError(w, 400, "urls must be a list.")
			return
		}
		if len(urls) > 200 {
			urls = urls[:200]
		}
		var kinds interface{} = []interface{}{"mp3"}
		if k, present := data["kinds"]; present {
			kinds = k
		}
		quality := str(data["quality"])
		if quality == "" {
			quality = "best"
		}
		ids, bad, err := m.add(urls, kinds, str(data["name"]), quality, str(data["subfolder"]))
		if err != nil {
			jsonError(w, 400, err.Error())
			return
		}
		if len(ids) == 0 {
			msg := "No valid links found."
			if len(bad) > 0 {
				if len(bad) > 3 {
					bad = bad[:3]
				}
				msg += " Skipped: " + strings.Join(bad, ", ")
			}
			jsonError(w, 400, msg)
			return
		}
		sendJSON(w, 200, map[string]interface{}{"added": ids, "skipped": bad})
	case "/api/remove", "/api/retry":
		ids, ok := idList(data["ids"])
		if !ok {
			jsonError(w, 400, "ids must be numbers.")
			return
		}
		if p == "/api/remove" {
			m.removeIDs(ids)
		} else {
			m.retry(ids)
		}
		sendJSON(w, 200, map[string]bool{"ok": true})
	case "/api/clear":
		m.clearFinished()
		sendJSON(w, 200, map[string]bool{"ok": true})
	case "/api/pause":
		mode := str(data["mode"])
		if _, has := data["mode"]; !has {
			mode = "toggle"
		}
		switch {
		case mode == "resume" || (mode == "toggle" && m.isPaused()):
			m.resume()
		case mode == "for":
			a := toInt(data["a"], 0, 1<<30, 0)
			b := toInt(data["b"], 0, 1<<30, 0)
			secs := spanSeconds(a, str(data["u1"]), b, str(data["u2"]))
			if secs <= 0 {
				jsonError(w, 400, "Enter how long to pause.")
				return
			}
			until := now() + float64(secs)
			m.pause(&until)
		case mode == "until":
			until, isNum := data["until"].(float64)
			if !isNum {
				jsonError(w, 400, "Pick a time in the future.")
				return
			}
			if until <= now() {
				jsonError(w, 400, "Pick a time in the future.")
				return
			}
			m.pause(&until)
		default:
			m.pause(nil)
		}
		sendJSON(w, 200, s.state(r))
	case "/api/limit":
		sendJSON(w, 200, map[string]interface{}{"limit": m.setLimit(data)})
	case "/api/update-ytdlp":
		out, ver := m.updateYtdlp()
		sendJSON(w, 200, map[string]string{"output": out, "version": ver})
	case "/api/setup":
		m.setup.start()
		sendJSON(w, 200, m.setup.status())
	case "/api/local-token":
		if !isLoopback(r) {
			jsonError(w, 403, "Only on the computer running the downloader.")
			return
		}
		sendJSON(w, 200, map[string]string{"url": "/local-login?t=" + s.mintLocalToken()})
	case "/api/autostart", "/api/quit", "/api/lan", "/api/folder", "/api/choose-folder":
		s.computerOnly(w, r, p, data)
	default:
		jsonError(w, 404, "Not found.")
	}
}

// computerOnly handles settings that change the computer itself; they are refused from phones.
func (s *Server) computerOnly(w http.ResponseWriter, r *http.Request, p string, data map[string]interface{}) {
	if !isLoopback(r) {
		jsonError(w, 403, "Change this on the computer that runs the downloader.")
		return
	}
	m := s.m
	switch p {
	case "/api/quit":
		sendJSON(w, 200, map[string]bool{"ok": true})
		go func() { time.Sleep(300 * time.Millisecond); s.requestQuit() }()
	case "/api/autostart":
		if !s.macMode {
			jsonError(w, 501, "Start at login is only available in the Mac app.")
			return
		}
		en, _ := data["enabled"].(bool)
		if err := setAutostart(en, s.exe, s.extraArgs, s.logPath); err != nil {
			jsonError(w, 500, "Could not change start at login: "+err.Error())
			return
		}
		sendJSON(w, 200, s.state(r))
	case "/api/lan":
		en, _ := data["enabled"].(bool)
		m.mu.Lock()
		prev := m.cfg.Lan
		m.cfg.Lan = en
		m.mu.Unlock()
		if err := s.rebind(bindAddr(en, s.port, "")); err != nil {
			m.mu.Lock()
			m.cfg.Lan = prev
			m.mu.Unlock()
			jsonError(w, 500, "Could not change Wi-Fi access: "+err.Error())
			return
		}
		m.mu.Lock()
		_ = m.saveConfigLocked()
		m.mu.Unlock()
		sendJSON(w, 200, s.state(r))
	case "/api/folder":
		dir, err := m.setOutDir(str(data["path"]))
		if err != nil {
			jsonError(w, 400, err.Error())
			return
		}
		_ = dir
		sendJSON(w, 200, s.state(r))
	case "/api/choose-folder":
		if runtime.GOOS != "darwin" {
			jsonError(w, 501, "The folder picker is only available in the Mac app. Type the folder instead.")
			return
		}
		out, err := exec.Command("osascript", "-e", `POSIX path of (choose folder with prompt "Choose where to save your downloads")`).Output()
		if err != nil {
			jsonError(w, 400, "No folder was chosen.")
			return
		}
		dir, err := m.setOutDir(strings.TrimSpace(string(out)))
		if err != nil {
			jsonError(w, 400, err.Error())
			return
		}
		_ = dir
		sendJSON(w, 200, s.state(r))
	}
}

// setOutDir changes where new downloads are saved. It must be inside the user's home folder.
func (m *Manager) setOutDir(p string) (string, error) {
	p = strings.TrimSpace(p)
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return "", fmt.Errorf("Cannot find your home folder.")
	}
	if p == "~" || strings.HasPrefix(p, "~/") {
		p = filepath.Join(home, strings.TrimPrefix(p, "~"))
	}
	if p == "" || !filepath.IsAbs(p) {
		return "", fmt.Errorf("Type the full folder path, for example %s", filepath.Join(home, "Downloads", "YouTubeDownloader"))
	}
	p = filepath.Clean(p)
	rp, err := filepath.EvalSymlinks(home)
	if err != nil {
		rp = home
	}
	rel, err := filepath.Rel(home, p)
	if err != nil || strings.HasPrefix(rel, "..") {
		if rel2, err2 := filepath.Rel(rp, p); err2 != nil || strings.HasPrefix(rel2, "..") {
			return "", fmt.Errorf("Choose a folder inside your home folder (%s).", home)
		}
	}
	if err := os.MkdirAll(p, 0o755); err != nil {
		return "", fmt.Errorf("Could not use that folder: %v", err)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.outDir = p
	m.cfg.OutDir = p
	_ = m.saveConfigLocked()
	return p, nil
}
