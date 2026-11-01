package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const version = "1.1.0"

var mediaExt = []string{".mp3", ".mp4", ".m4a"}

// Job is one queue item. Exported fields are sent to the web app; the rest is internal.
type Job struct {
	ID        int     `json:"id"`
	URL       string  `json:"url"`
	Kind      string  `json:"kind"`
	Name      string  `json:"name"`
	Height    int     `json:"height"`
	Subfolder string  `json:"subfolder"`
	Display   string  `json:"display"`
	Text      string  `json:"text"`
	Status    string  `json:"status"`
	Percent   float64 `json:"percent"`
	Error     string  `json:"error"`
	File      string  `json:"file"`
	Created   float64 `json:"created"`

	dest, final    string
	cancel, remove bool
}

type savedJob struct {
	ID        int    `json:"id"`
	URL       string `json:"url"`
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Height    int    `json:"height"`
	Subfolder string `json:"subfolder"`
}

type savedState struct {
	Limit      Limit      `json:"limit"`
	StartTimes []float64  `json:"start_times"`
	Paused     bool       `json:"paused"`
	ResumeAt   *float64   `json:"resume_at"`
	Counter    int        `json:"counter"`
	Jobs       []savedJob `json:"jobs"`
}

type config struct {
	Secret string `json:"secret"`
	Pin    string `json:"pin"`
	Lan    bool   `json:"lan"`
	OutDir string `json:"out_dir,omitempty"`
}

// Manager owns the queue, the limit/pause rules and the single download worker.
type Manager struct {
	mu         sync.Mutex
	dataDir    string
	outDir     string
	toolsDir   string
	ytdlpFlag  string // explicit --yt-dlp
	ffmpegFlag string // explicit --ffmpeg-location

	jobs       []*Job
	counter    int
	limit      Limit
	startTimes []float64
	paused     bool
	resumeAt   *float64
	current    *Job
	cmd        *exec.Cmd

	cfg         config
	ytdlpVer    string
	stop        chan struct{}
	stopped     bool
	wg          sync.WaitGroup
	setup       *toolSetup
	downloadLog func(string)
}

func now() float64 { return float64(time.Now().UnixNano()) / 1e9 }

func newManager(dataDir, outDir, ytdlpFlag, ffmpegFlag, pin string) (*Manager, error) {
	m := &Manager{dataDir: dataDir, outDir: outDir, toolsDir: filepath.Join(dataDir, "tools"),
		ytdlpFlag: ytdlpFlag, ffmpegFlag: ffmpegFlag, stop: make(chan struct{}),
		limit: normalizeLimit(map[string]interface{}{})}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	if err := m.loadConfig(pin); err != nil {
		return nil, err
	}
	if m.outDir == "" {
		m.outDir = m.cfg.OutDir
	}
	if m.outDir == "" {
		m.outDir = defaultOutDir()
	}
	abs, err := filepath.Abs(m.outDir)
	if err != nil {
		return nil, err
	}
	m.outDir = abs
	if err := os.MkdirAll(m.outDir, 0o755); err != nil {
		return nil, err
	}
	m.setup = newToolSetup(m)
	m.loadState()
	return m, nil
}

// ---- config / auth -------------------------------------------------------------------

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func (m *Manager) loadConfig(pin string) error {
	path := filepath.Join(m.dataDir, "config.json")
	var cfg config
	if b, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(b, &cfg)
	}
	changed := false
	if cfg.Secret == "" {
		cfg.Secret = randomHex(32)
		changed = true
	}
	if pin != "" && cfg.Pin != pin {
		cfg.Pin = pin
		changed = true
	}
	if cfg.Pin == "" {
		n, _ := rand.Int(rand.Reader, big.NewInt(1000000))
		cfg.Pin = fmt.Sprintf("%06d", n.Int64())
		changed = true
	}
	m.cfg = cfg
	if changed {
		return m.saveConfigLocked()
	}
	return nil
}

func (m *Manager) saveConfigLocked() error {
	b, _ := json.Marshal(m.cfg)
	path := filepath.Join(m.dataDir, "config.json")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (m *Manager) pin() string { return m.cfg.Pin }

func (m *Manager) token() string {
	h := hmac.New(sha256.New, []byte(m.cfg.Secret))
	h.Write([]byte(m.cfg.Pin))
	return hex.EncodeToString(h.Sum(nil))
}

// ---- persistence ----------------------------------------------------------------------

func (m *Manager) statePath() string { return filepath.Join(m.dataDir, "state.json") }

func (m *Manager) loadState() {
	b, err := os.ReadFile(m.statePath())
	if err != nil {
		return
	}
	var st savedState
	if json.Unmarshal(b, &st) != nil {
		return
	}
	m.limit = normalizeLimit(map[string]interface{}{"count": float64(st.Limit.Count), "a": float64(st.Limit.A), "u1": st.Limit.U1, "b": float64(st.Limit.B), "u2": st.Limit.U2})
	m.startTimes = st.StartTimes
	m.paused = st.Paused
	m.resumeAt = st.ResumeAt
	m.counter = st.Counter
	for _, sj := range st.Jobs {
		u := normalizeURL(sj.URL)
		if u == "" {
			continue
		}
		m.jobs = append(m.jobs, m.newJobLocked(u, sj.Kind, sj.Name, sj.Height, sj.Subfolder, sj.ID))
	}
}

func (m *Manager) saveLocked() {
	st := savedState{Limit: m.limit, StartTimes: m.startTimes, Paused: m.paused, ResumeAt: m.resumeAt, Counter: m.counter, Jobs: []savedJob{}}
	if st.StartTimes == nil {
		st.StartTimes = []float64{}
	}
	for _, j := range m.jobs {
		if j.Status == "queued" || j.Status == "downloading" {
			st.Jobs = append(st.Jobs, savedJob{j.ID, j.URL, j.Kind, j.Name, j.Height, j.Subfolder})
		}
	}
	b, _ := json.Marshal(st)
	tmp := m.statePath() + ".tmp"
	if os.WriteFile(tmp, b, 0o644) == nil {
		_ = os.Rename(tmp, m.statePath())
	}
}

// ---- queue operations -----------------------------------------------------------------

func (m *Manager) newJobLocked(url, kind, name string, height int, subfolder string, id int) *Job {
	if kind != "mp4" {
		kind = "mp3"
	}
	if id == 0 {
		m.counter++
		id = m.counter
	} else if id > m.counter {
		m.counter = id
	}
	h := 0
	for _, q := range qualities {
		if q == height {
			h = height
		}
	}
	cn := cleanName(name)
	return &Job{ID: id, URL: url, Kind: kind, Name: cn, Height: h, Subfolder: cleanSubfolder(subfolder),
		Display: cn, Text: "Queued", Status: "queued", Created: now()}
}

// add queues every URL once per kind. It returns the new ids and the rejected texts.
func (m *Manager) add(urls []string, kinds interface{}, name, quality, subfolder string) ([]int, []string, error) {
	var good, bad []string
	for _, raw := range urls {
		if u := normalizeURL(raw); u != "" {
			good = append(good, u)
		} else {
			bad = append(bad, raw)
		}
	}
	var ks []string
	if list, ok := kinds.([]interface{}); ok {
		for _, want := range []string{"mp3", "mp4"} {
			for _, k := range list {
				if s, ok := k.(string); ok && s == want {
					ks = append(ks, want)
					break
				}
			}
		}
	}
	if len(ks) == 0 {
		return nil, nil, fmt.Errorf("Choose MP3, MP4, or both.")
	}
	name = cleanName(name)
	if name != "" && len(good) > 1 {
		return nil, nil, fmt.Errorf("A custom name can only be used with one link at a time.")
	}
	height := qualities[quality]
	ids := []int{}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, u := range good {
		for _, k := range ks {
			j := m.newJobLocked(u, k, name, height, subfolder, 0)
			m.jobs = append(m.jobs, j)
			ids = append(ids, j.ID)
		}
	}
	m.saveLocked()
	if bad == nil {
		bad = []string{}
	}
	return ids, bad, nil
}

func (m *Manager) findLocked(id int) *Job {
	for _, j := range m.jobs {
		if j.ID == id {
			return j
		}
	}
	return nil
}

func (m *Manager) removeJobLocked(j *Job) {
	for i, x := range m.jobs {
		if x == j {
			m.jobs = append(m.jobs[:i], m.jobs[i+1:]...)
			return
		}
	}
}

func (m *Manager) removeIDs(ids []int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, id := range ids {
		j := m.findLocked(id)
		if j == nil {
			continue
		}
		if j == m.current {
			j.remove = true
			m.cancelCurrentLocked()
		} else {
			m.removeJobLocked(j)
		}
	}
	m.saveLocked()
}

func (m *Manager) retry(ids []int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, id := range ids {
		j := m.findLocked(id)
		if j != nil && j != m.current && (j.Status == "failed" || j.Status == "cancelled") {
			j.Status, j.Text, j.Percent, j.Error = "queued", "Queued", 0, ""
		}
	}
	m.saveLocked()
}

func (m *Manager) clearFinished() {
	m.mu.Lock()
	defer m.mu.Unlock()
	keep := m.jobs[:0]
	for _, j := range m.jobs {
		if j == m.current || (j.Status != "done" && j.Status != "failed" && j.Status != "cancelled") {
			keep = append(keep, j)
		}
	}
	m.jobs = keep
	m.saveLocked()
}

func (m *Manager) cancelCurrentLocked() {
	j := m.current
	if j == nil {
		return
	}
	j.Status, j.Text, j.cancel = "cancelled", "Cancelled", true
	if m.cmd != nil {
		killTree(m.cmd)
	}
}

// ---- pause / limit --------------------------------------------------------------------

func (m *Manager) pause(until *float64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.paused, m.resumeAt = true, until
	m.saveLocked()
}

func (m *Manager) resume() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.paused, m.resumeAt = false, nil
	m.saveLocked()
}

func (m *Manager) isPaused() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.paused
}

func (m *Manager) setLimit(d map[string]interface{}) Limit {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.limit = normalizeLimit(d)
	m.saveLocked()
	return m.limit
}

// ---- worker ---------------------------------------------------------------------------

func (m *Manager) start() {
	m.wg.Add(1)
	go func() { defer m.wg.Done(); m.worker() }()
	go m.probeVersion()
}

func (m *Manager) shutdown() {
	m.mu.Lock()
	if !m.stopped {
		m.stopped = true
		close(m.stop)
	}
	if m.cmd != nil {
		killTree(m.cmd)
	}
	m.saveLocked()
	m.mu.Unlock()
	m.wg.Wait()
}

func (m *Manager) sleep(d time.Duration) {
	select {
	case <-m.stop:
	case <-time.After(d):
	}
}

func (m *Manager) gateLocked(t float64) bool {
	if m.paused && m.resumeAt != nil && t >= *m.resumeAt {
		m.paused, m.resumeAt = false, nil
		m.saveLocked()
	}
	if m.paused {
		return false
	}
	return nextAllowed(m.startTimes, m.limit, t) == 0
}

func (m *Manager) worker() {
	for {
		select {
		case <-m.stop:
			return
		default:
		}
		var job *Job
		m.mu.Lock()
		var queued *Job
		for _, j := range m.jobs {
			if j.Status == "queued" {
				queued = j
				break
			}
		}
		t := now()
		if queued != nil {
			if m.gateLocked(t) {
				if _, _, ok := m.resolveTools(); ok {
					job = queued
					job.Status, job.Text = "downloading", "Starting..."
					m.current = job
					m.startTimes = append(m.startTimes, t)
					cut := t - 90*86400
					keep := m.startTimes[:0]
					for _, s := range m.startTimes {
						if s > cut {
							keep = append(keep, s)
						}
					}
					m.startTimes = keep
					m.saveLocked()
				}
			}
		} else {
			m.gateLocked(t)
		}
		m.mu.Unlock()
		if job == nil {
			m.sleep(400 * time.Millisecond)
			continue
		}
		m.download(job)
		m.mu.Lock()
		m.current, m.cmd = nil, nil
		if job.remove {
			m.removeJobLocked(job)
		}
		m.saveLocked()
		m.mu.Unlock()
	}
}

func (m *Manager) download(job *Job) {
	m.mu.Lock()
	prefix, ffloc, ok := m.resolveTools()
	m.mu.Unlock()
	if !ok {
		m.mu.Lock()
		job.Status, job.Text = "failed", "Failed: yt-dlp is not installed yet"
		m.mu.Unlock()
		return
	}
	args := append(append([]string{}, prefix[1:]...), buildArgs(job, m.outDir, ffloc)...)
	cmd := exec.Command(prefix[0], args...)
	cmd.Env = append(os.Environ(), "PYTHONIOENCODING=utf-8")
	setProcAttrs(cmd)
	rd, wr, err := os.Pipe()
	if err != nil {
		m.mu.Lock()
		job.Status, job.Text = "failed", "Failed: "+err.Error()
		m.mu.Unlock()
		return
	}
	cmd.Stdout, cmd.Stderr = wr, wr
	if err := cmd.Start(); err != nil {
		wr.Close()
		rd.Close()
		m.mu.Lock()
		job.Status, job.Text = "failed", fmt.Sprintf("Failed: could not start yt-dlp (%v)", err)
		m.mu.Unlock()
		return
	}
	wr.Close()
	m.mu.Lock()
	m.cmd = cmd
	if job.cancel {
		killTree(cmd)
	}
	m.mu.Unlock()

	sc := bufio.NewScanner(rd)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		m.mu.Lock()
		if !job.cancel {
			parseLine(sc.Text(), job)
		}
		m.mu.Unlock()
	}
	rd.Close()
	waitErr := cmd.Wait()
	code := 0
	if waitErr != nil {
		code = -1
		if ee, ok := waitErr.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if job.cancel {
		job.Status, job.Text = "cancelled", "Cancelled"
		return
	}
	if code == 0 {
		job.Status, job.Text, job.Percent = "done", "Done", 100
		final := job.final
		if final == "" {
			low := strings.ToLower(job.dest)
			for _, e := range mediaExt {
				if strings.HasSuffix(low, e) {
					final = job.dest
				}
			}
		}
		job.File = m.relativeLocked(final)
		return
	}
	why := job.Error
	if why == "" {
		why = fmt.Sprintf("exit code %d", code)
	}
	if r := []rune(why); len(r) > 90 {
		why = string(r[:90]) + "..."
	}
	job.Status, job.Text = "failed", "Failed: "+why
}

func (m *Manager) relativeLocked(p string) string {
	if p == "" {
		return ""
	}
	full, err := filepath.Abs(p)
	if err != nil {
		return ""
	}
	rel, err := filepath.Rel(m.outDir, full)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return ""
	}
	return filepath.ToSlash(rel)
}

// ---- files ----------------------------------------------------------------------------

type fileInfo struct {
	Path  string  `json:"path"`
	Name  string  `json:"name"`
	Size  int64   `json:"size"`
	Mtime float64 `json:"mtime"`
}

func (m *Manager) listFiles(limit int) []fileInfo {
	out := []fileInfo{}
	baseDepth := strings.Count(strings.TrimRight(m.outDir, string(filepath.Separator)), string(filepath.Separator))
	_ = filepath.WalkDir(m.outDir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if strings.Count(p, string(filepath.Separator))-baseDepth >= 3 {
				return filepath.SkipDir
			}
			return nil
		}
		low := strings.ToLower(d.Name())
		isMedia := false
		for _, e := range mediaExt {
			if strings.HasSuffix(low, e) {
				isMedia = true
			}
		}
		if !isMedia {
			return nil
		}
		st, err := os.Stat(p)
		if err != nil || st.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(m.outDir, p)
		out = append(out, fileInfo{filepath.ToSlash(rel), d.Name(), st.Size(), float64(st.ModTime().UnixNano()) / 1e9})
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].Mtime > out[j].Mtime })
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

// resolveFile returns the absolute path of a file below the output folder, or "" (blocks ../ tricks and symlinks out).
func (m *Manager) resolveFile(rel string) string {
	rel = strings.ReplaceAll(rel, "\\", "/")
	if strings.ContainsRune(rel, 0) || strings.HasPrefix(rel, "/") {
		return ""
	}
	first := strings.SplitN(rel, "/", 2)[0]
	if strings.Contains(first, ":") {
		return ""
	}
	full, err := filepath.EvalSymlinks(filepath.Join(m.outDir, filepath.FromSlash(rel)))
	if err != nil {
		return ""
	}
	root, err := filepath.EvalSymlinks(m.outDir)
	if err != nil {
		return ""
	}
	r, err := filepath.Rel(root, full)
	if err != nil || r == ".." || strings.HasPrefix(r, ".."+string(filepath.Separator)) {
		return ""
	}
	if st, err := os.Stat(full); err != nil || st.IsDir() {
		return ""
	}
	return full
}

// ---- yt-dlp helpers --------------------------------------------------------------------

func (m *Manager) probeVersion() {
	m.mu.Lock()
	prefix, _, ok := m.resolveTools()
	m.mu.Unlock()
	if !ok {
		return
	}
	out, err := exec.Command(prefix[0], append(append([]string{}, prefix[1:]...), "--version")...).Output()
	if err == nil {
		v := strings.TrimSpace(string(out))
		if len(v) > 40 {
			v = v[:40]
		}
		m.mu.Lock()
		m.ytdlpVer = v
		m.mu.Unlock()
	}
}

func (m *Manager) updateYtdlp() (string, string) {
	m.mu.Lock()
	prefix, _, ok := m.resolveTools()
	m.mu.Unlock()
	if !ok {
		return "yt-dlp is not installed yet.", ""
	}
	cmd := exec.Command(prefix[0], append(append([]string{}, prefix[1:]...), "-U")...)
	done := make(chan []byte, 1)
	go func() { b, _ := cmd.CombinedOutput(); done <- b }()
	var text string
	select {
	case b := <-done:
		text = strings.TrimSpace(string(b))
	case <-time.After(180 * time.Second):
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		text = "The updater timed out."
	}
	m.probeVersion()
	if len(text) > 600 {
		text = text[len(text)-600:]
	}
	m.mu.Lock()
	v := m.ytdlpVer
	m.mu.Unlock()
	return text, v
}
