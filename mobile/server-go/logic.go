package main

import (
	"fmt"
	"math"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Everything in this file is pure (no I/O) so it can be unit-tested directly.
// It mirrors mobile/server/ytdl_server.py so both servers behave identically.

var unitOrder = []string{"days", "hours", "minutes", "seconds"}
var unitSeconds = map[string]int{"days": 86400, "hours": 3600, "minutes": 60, "seconds": 1}
var qualities = map[string]int{"best": 0, "1080p": 1080, "720p": 720, "480p": 480, "360p": 360}

var (
	reBadChars = regexp.MustCompile("[\\\\/:*?\"<>|\x00-\x1f]")
	reExt      = regexp.MustCompile(`(?i)\.(mp3|mp4)$`)
	reYTHost   = regexp.MustCompile(`(?i)^(www\.|m\.|music\.)?(youtube\.com|youtu\.be)/`)
	reHTTP     = regexp.MustCompile(`(?i)^https?://\S+$`)
)

func truncRunes(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}

func cleanName(name string) string {
	n := strings.TrimSpace(name)
	n = reExt.ReplaceAllString(n, "")
	n = reBadChars.ReplaceAllString(n, "_")
	n = strings.Trim(n, " .")
	return truncRunes(n, 150)
}

func cleanSubfolder(name string) string {
	n := strings.TrimSpace(name)
	n = reBadChars.ReplaceAllString(n, "_")
	n = strings.Trim(n, " .")
	if n == "" || n == "." || n == ".." {
		return ""
	}
	return truncRunes(n, 80)
}

// normalizeURL returns a clean http(s) URL, or "" when the text is not a link.
func normalizeURL(text string) string {
	u := strings.TrimSpace(text)
	if reYTHost.MatchString(u) {
		u = "https://" + u
	}
	if reHTTP.MatchString(u) && len(u) <= 2000 {
		return u
	}
	return ""
}

func unitSmallerThan(first string) []string {
	for i, u := range unitOrder {
		if u == first {
			return append([]string{}, unitOrder[i+1:]...)
		}
	}
	return []string{}
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// toInt converts a decoded JSON value to an int clamped to [lo, hi] (default when it is not a number).
func toInt(v interface{}, lo, hi, def int) int {
	var n int
	switch t := v.(type) {
	case float64:
		if math.IsNaN(t) || math.IsInf(t, 0) {
			return def
		}
		n = int(t)
	case int:
		n = t
	case string:
		x, err := strconv.Atoi(strings.TrimSpace(t))
		if err != nil {
			return def
		}
		n = x
	default:
		return def
	}
	if n < lo {
		return lo
	}
	if n > hi {
		return hi
	}
	return n
}

func str(v interface{}) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

// Limit is "max Count downloads per A U1 + B U2".
type Limit struct {
	Count int    `json:"count"`
	A     int    `json:"a"`
	U1    string `json:"u1"`
	B     int    `json:"b"`
	U2    string `json:"u2"`
}

// normalizeSpan forces the second unit to be strictly smaller than the first (or drops it).
func normalizeSpan(a int, u1 string, b int, u2 string) (int, string, int, string) {
	if !contains(unitOrder, u1) {
		u1 = "hours"
	}
	if !contains(unitSmallerThan(u1), u2) {
		u2 = ""
	}
	a = toInt(a, 0, 9999, 0)
	if u2 == "" {
		b = 0
	} else {
		b = toInt(b, 0, 9999, 0)
	}
	return a, u1, b, u2
}

func spanSeconds(a int, u1 string, b int, u2 string) int {
	a, u1, b, u2 = normalizeSpan(a, u1, b, u2)
	total := a * unitSeconds[u1]
	if u2 != "" {
		total += b * unitSeconds[u2]
	}
	return total
}

func normalizeLimit(d map[string]interface{}) Limit {
	a := 1
	if v, ok := d["a"]; ok {
		a = toInt(v, math.MinInt32, math.MaxInt32, 0)
	}
	b := toInt(d["b"], math.MinInt32, math.MaxInt32, 0)
	a, u1, b, u2 := normalizeSpan(a, str(d["u1"]), b, str(d["u2"]))
	return Limit{Count: toInt(d["count"], 0, 1000, 0), A: a, U1: u1, B: b, U2: u2}
}

// nextAllowed is 0 when a download may start now, otherwise the epoch second at which it may.
func nextAllowed(starts []float64, l Limit, now float64) float64 {
	window := float64(spanSeconds(l.A, l.U1, l.B, l.U2))
	if l.Count <= 0 || window <= 0 {
		return 0
	}
	var recent []float64
	for _, t := range starts {
		if t > now-window {
			recent = append(recent, t)
		}
	}
	sort.Float64s(recent)
	if len(recent) < l.Count {
		return 0
	}
	return recent[len(recent)-l.Count] + window
}

// buildArgs are the yt-dlp arguments (without the program) for one queue item.
func buildArgs(j *Job, outDir, ffmpegLoc string) []string {
	folder := outDir
	if j.Subfolder != "" {
		folder = filepath.Join(outDir, j.Subfolder)
	}
	leaf := "%(title)s.%(ext)s"
	if j.Name != "" {
		leaf = strings.ReplaceAll(j.Name, "%", "%%") + ".%(ext)s"
	}
	var args []string
	if j.Kind == "mp4" {
		capf := ""
		if j.Height > 0 {
			capf = fmt.Sprintf("[height<=?%d]", j.Height)
		}
		fmtSel := "bv*[vcodec^=avc1]" + capf + "+ba[acodec^=mp4a]/b[ext=mp4]" + capf + "/bv*" + capf + "+ba/b" + capf
		args = append(args, "-f", fmtSel, "--merge-output-format", "mp4")
	} else {
		args = append(args, "-x", "--audio-format", "mp3", "--audio-quality", "0")
	}
	args = append(args, "--no-playlist", "--newline", "--windows-filenames", "--embed-metadata")
	if ffmpegLoc != "" {
		args = append(args, "--ffmpeg-location", ffmpegLoc)
	}
	args = append(args, "-o", filepath.Join(folder, leaf), j.URL)
	return args
}

var (
	rePct     = regexp.MustCompile(`^\[download\]\s+([\d.]+)%`)
	reDest    = regexp.MustCompile(`^\[download\] Destination: (.+)$`)
	reExtract = regexp.MustCompile(`^\[ExtractAudio\] Destination: (.+)$`)
	reNoConv  = regexp.MustCompile(`^\[ExtractAudio\] Not converting audio (.+?); file is already in target format`)
	reMerge   = regexp.MustCompile(`^\[Merger\] Merging formats into "(.+)"$`)
	reHave    = regexp.MustCompile(`^\[download\] (.+) has already been downloaded`)
	reF       = regexp.MustCompile(`\.f\d+$`)
	reErr     = regexp.MustCompile(`^ERROR:\s*`)
)

func titleFrom(p string) string {
	p = strings.ReplaceAll(p, "\\", "/")
	base := path.Base(p)
	base = strings.TrimSuffix(base, path.Ext(base))
	return reF.ReplaceAllString(base, "")
}

// parseLine updates a job from one line of yt-dlp output.
func parseLine(line string, j *Job) {
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return
	}
	if strings.HasPrefix(line, "ERROR") {
		j.Error = reErr.ReplaceAllString(line, "")
		return
	}
	if m := rePct.FindStringSubmatch(line); m != nil {
		j.Percent, _ = strconv.ParseFloat(m[1], 64)
		j.Text = "Downloading " + m[1] + "%"
		return
	}
	if m := reDest.FindStringSubmatch(line); m != nil {
		j.dest = m[1]
		if j.Name == "" {
			j.Display = titleFrom(m[1])
		}
		return
	}
	if m := reMerge.FindStringSubmatch(line); m != nil {
		j.Text = "Joining video and audio..."
		j.Percent = 100
		j.final = m[1]
		if j.Name == "" {
			j.Display = titleFrom(m[1])
		}
		return
	}
	if m := reExtract.FindStringSubmatch(line); m != nil {
		j.Text = "Converting to MP3..."
		j.Percent = 100
		j.final = m[1]
		if j.Name == "" {
			j.Display = titleFrom(m[1])
		}
		return
	}
	if m := reNoConv.FindStringSubmatch(line); m != nil {
		j.final = m[1]
		return
	}
	if m := reHave.FindStringSubmatch(line); m != nil {
		j.Text = "Already downloaded"
		j.dest = m[1]
		if j.Name == "" {
			j.Display = titleFrom(m[1])
		}
	}
}
