package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// "Start at login" on a Mac is a per-user LaunchAgent (no admin rights needed).
const agentLabel = "com.hdumo.youtubedownloader"

func agentPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", agentLabel+".plist")
}

func autostartEnabled() bool { return isFile(agentPath()) }

func xmlEscape(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;")
	return r.Replace(s)
}

func agentPlist(exe string, extraArgs []string, logPath string) string {
	var b strings.Builder
	b.WriteString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
	b.WriteString("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n")
	b.WriteString("\t<key>Label</key>\n\t<string>" + agentLabel + "</string>\n")
	b.WriteString("\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>" + xmlEscape(exe) + "</string>\n")
	for _, a := range extraArgs {
		b.WriteString("\t\t<string>" + xmlEscape(a) + "</string>\n")
	}
	b.WriteString("\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n\t<key>KeepAlive</key>\n\t<false/>\n")
	b.WriteString("\t<key>StandardOutPath</key>\n\t<string>" + xmlEscape(logPath) + "</string>\n")
	b.WriteString("\t<key>StandardErrorPath</key>\n\t<string>" + xmlEscape(logPath) + "</string>\n")
	b.WriteString("</dict>\n</plist>\n")
	return b.String()
}

func setAutostart(enable bool, exe string, extraArgs []string, logPath string) error {
	p := agentPath()
	uid := fmt.Sprint(os.Getuid())
	if enable {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(p, []byte(agentPlist(exe, extraArgs, logPath)), 0o644); err != nil {
			return err
		}
		if runtime.GOOS == "darwin" {
			if err := exec.Command("launchctl", "bootstrap", "gui/"+uid, p).Run(); err != nil {
				_ = exec.Command("launchctl", "load", "-w", p).Run() // older macOS, or already loaded
			}
		}
		return nil
	}
	if runtime.GOOS == "darwin" {
		if err := exec.Command("launchctl", "bootout", "gui/"+uid+"/"+agentLabel).Run(); err != nil {
			_ = exec.Command("launchctl", "unload", p).Run()
		}
	}
	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
