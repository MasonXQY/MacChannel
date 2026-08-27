//go:build darwin

package main

import (
	"os"
	"syscall"
)

const fullFileSync = 51

func syncOpenFile(file *os.File) error {
	_, _, errno := syscall.Syscall(syscall.SYS_FCNTL, file.Fd(), fullFileSync, 0)
	if errno == 0 {
		return nil
	}
	return file.Sync()
}
