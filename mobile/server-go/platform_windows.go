//go:build windows

package main

import (
	"os/exec"
	"strconv"
)

func setProcAttrs(cmd *exec.Cmd) {}

func killTree(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = exec.Command("taskkill", "/PID", strconv.Itoa(cmd.Process.Pid), "/T", "/F").Run()
	_ = cmd.Process.Kill()
}
