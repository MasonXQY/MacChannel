//go:build linux

package main

import "os"

func syncOpenFile(file *os.File) error {
	return file.Sync()
}
