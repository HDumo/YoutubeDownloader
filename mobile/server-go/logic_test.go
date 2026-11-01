package main

import (
	"path/filepath"
	"reflect"
	"testing"
)

func TestNamesAndURLs(t *testing.T) {
	cases := []struct{ got, want string }{
		{cleanName(" My: Song?.MP3 "), "My_ Song_"},
		{cleanName("Clip.mp4"), "Clip"},
		{cleanSubfolder("../etc"), "_etc"},
		{cleanSubfolder(".."), ""},
		{cleanSubfolder("a/b\\c"), "a_b_c"},
		{normalizeURL("youtu.be/abc"), "https://youtu.be/abc"},
		{normalizeURL("www.youtube.com/watch?v=1"), "https://www.youtube.com/watch?v=1"},
		{normalizeURL("hello world"), ""},
		{normalizeURL("javascript:alert(1)"), ""},
		{normalizeURL("file:///etc/passwd"), ""},
	}
	for i, c := range cases {
		if c.got != c.want {
			t.Errorf("case %d: got %q want %q", i, c.got, c.want)
		}
	}
	if len([]rune(cleanName(string(make([]rune, 400))))) > 150 {
		t.Error("name not capped")
	}
}

func TestUnitRules(t *testing.T) {
	if !reflect.DeepEqual(unitSmallerThan("days"), []string{"hours", "minutes", "seconds"}) {
		t.Error("days")
	}
	if !reflect.DeepEqual(unitSmallerThan("hours"), []string{"minutes", "seconds"}) {
		t.Error("hours")
	}
	if !reflect.DeepEqual(unitSmallerThan("minutes"), []string{"seconds"}) {
		t.Error("minutes")
	}
	if len(unitSmallerThan("seconds")) != 0 {
		t.Error("seconds")
	}
	type sp struct {
		a  int
		u1 string
		b  int
		u2 string
	}
	check := func(in, want sp) {
		a, u1, b, u2 := normalizeSpan(in.a, in.u1, in.b, in.u2)
		if (sp{a, u1, b, u2}) != want {
			t.Errorf("normalizeSpan(%v) = %v, want %v", in, sp{a, u1, b, u2}, want)
		}
	}
	check(sp{1, "hours", 30, "hours"}, sp{1, "hours", 0, ""})
	check(sp{1, "hours", 30, "days"}, sp{1, "hours", 0, ""})
	check(sp{1, "seconds", 5, "seconds"}, sp{1, "seconds", 0, ""})
	check(sp{2, "days", 6, "hours"}, sp{2, "days", 6, "hours"})
	if spanSeconds(1, "hours", 30, "minutes") != 5400 {
		t.Error("1h30m")
	}
	if spanSeconds(2, "days", 15, "hours") != 2*86400+15*3600 {
		t.Error("2d15h")
	}
	l := normalizeLimit(map[string]interface{}{"count": 5000.0, "a": -3.0, "u1": "weeks"})
	if l.U1 != "hours" || l.Count != 1000 || l.A != 0 {
		t.Errorf("limit clamp: %+v", l)
	}
}

func TestLimitWindow(t *testing.T) {
	lim := normalizeLimit(map[string]interface{}{"count": 3.0, "a": 1.0, "u1": "hours", "b": 30.0, "u2": "minutes"})
	now := 100000.0
	if nextAllowed(nil, lim, now) != 0 {
		t.Error("empty")
	}
	if nextAllowed([]float64{now - 60, now - 30}, lim, now) != 0 {
		t.Error("two of three")
	}
	ts := []float64{now - 4800, now - 3600, now - 600}
	if got := nextAllowed(ts, lim, now); got != ts[0]+5400 {
		t.Errorf("blocked until oldest+90m: %v", got)
	}
	if nextAllowed([]float64{now - 9000, now - 3600, now - 600}, lim, now) != 0 {
		t.Error("oldest fell out of the window")
	}
	if nextAllowed(ts, normalizeLimit(map[string]interface{}{"count": 0.0}), now) != 0 {
		t.Error("0 = unlimited")
	}
}

func TestBuildArgs(t *testing.T) {
	j := &Job{Kind: "mp3", URL: "https://youtu.be/x", Name: "100% Mix", Subfolder: "Trip"}
	a := buildArgs(j, "/out", "/ff")
	if a[0] != "-x" || a[1] != "--audio-format" || a[2] != "mp3" {
		t.Errorf("mp3 args: %v", a)
	}
	want := filepath.Join("/out", "Trip", "100%% Mix.%(ext)s")
	var tmpl, ffl string
	for i, x := range a {
		if x == "-o" {
			tmpl = a[i+1]
		}
		if x == "--ffmpeg-location" {
			ffl = a[i+1]
		}
	}
	if tmpl != want || ffl != "/ff" || a[len(a)-1] != "https://youtu.be/x" {
		t.Errorf("template %q ffmpeg %q last %q", tmpl, ffl, a[len(a)-1])
	}
	v := buildArgs(&Job{Kind: "mp4", URL: "u", Height: 720}, "/out", "")
	joined := ""
	for _, x := range v {
		joined += x + "\n"
	}
	for _, need := range []string{"[height<=?720]", "--merge-output-format", "mp4", filepath.Join("/out", "%(title)s.%(ext)s")} {
		if !contains(splitLines(joined), need) && !stringsContains(joined, need) {
			t.Errorf("mp4 args missing %q: %v", need, v)
		}
	}
	for _, x := range v {
		if x == "-x" {
			t.Error("mp4 must not extract audio")
		}
	}
}

func splitLines(s string) []string {
	var out []string
	cur := ""
	for _, r := range s {
		if r == '\n' {
			out = append(out, cur)
			cur = ""
		} else {
			cur += string(r)
		}
	}
	return out
}

func stringsContains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func TestParseLine(t *testing.T) {
	j := &Job{}
	parseLine("[download] Destination: /o/Nice Song.f137.mp4", j)
	if j.Display != "Nice Song" {
		t.Errorf("display %q", j.Display)
	}
	parseLine("[download]  42.5% of 3MiB", j)
	if j.Percent != 42.5 {
		t.Errorf("percent %v", j.Percent)
	}
	parseLine(`[Merger] Merging formats into "/o/Nice Song.mp4"`, j)
	if j.final != "/o/Nice Song.mp4" {
		t.Errorf("final %q", j.final)
	}
	parseLine("[ExtractAudio] Destination: /o/Nice Song.mp3", j)
	if j.final != "/o/Nice Song.mp3" {
		t.Errorf("final %q", j.final)
	}
	parseLine("ERROR: [youtube] x: Video unavailable", j)
	if j.Error != "[youtube] x: Video unavailable" {
		t.Errorf("error %q", j.Error)
	}
	j2 := &Job{Name: "Mine", Display: "Mine"}
	parseLine("[download] Destination: /o/Other.webm", j2)
	if j2.Display != "Mine" {
		t.Errorf("custom name must stay: %q", j2.Display)
	}
}

func TestAutostartPlist(t *testing.T) {
	p := agentPlist("/Applications/YT & Co/ytdl", []string{"--background"}, "/tmp/log")
	for _, need := range []string{"com.hdumo.youtubedownloader", "YT &amp; Co", "--background", "RunAtLoad"} {
		if !stringsContains(p, need) {
			t.Errorf("plist missing %q", need)
		}
	}
}
