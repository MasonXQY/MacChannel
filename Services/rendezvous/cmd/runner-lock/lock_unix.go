//go:build darwin || linux

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

const runnerLockHeldEnvironment = "MACCHANNEL_RUNNER_ADVISORY_LOCK_HELD"

func execWithAdvisoryLock(lockPath, selfDelete string, command []string) error {
	lockPath = filepath.Clean(lockPath)
	if !filepath.IsAbs(lockPath) {
		return errors.New("advisory lock path must be absolute")
	}
	fd, err := syscall.Open(
		lockPath,
		syscall.O_CREAT|syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOFOLLOW,
		0o600,
	)
	if err != nil {
		return fmt.Errorf("open advisory lock: %w", err)
	}
	defer syscall.Close(fd)
	var info syscall.Stat_t
	if err := syscall.Fstat(fd, &info); err != nil {
		return fmt.Errorf("inspect advisory lock: %w", err)
	}
	if info.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return errors.New("advisory lock is not a regular file")
	}
	if err := syscall.Fchmod(fd, 0o600); err != nil {
		return fmt.Errorf("protect advisory lock: %w", err)
	}
	if selfDelete != "" {
		executable, err := filepath.Abs(os.Args[0])
		if err != nil || filepath.Clean(selfDelete) != filepath.Clean(executable) {
			return errors.New("refusing to unlink an unexpected helper path")
		}
		if err := os.Remove(selfDelete); err != nil {
			return fmt.Errorf("unlink temporary lock helper: %w", err)
		}
	}
	lock := syscall.Flock_t{Type: syscall.F_WRLCK, Whence: 0, Start: 0, Len: 0}
	if err := syscall.FcntlFlock(uintptr(fd), syscall.F_SETLKW, &lock); err != nil {
		return fmt.Errorf("acquire advisory lock: %w", err)
	}
	flags, _, errno := syscall.Syscall(syscall.SYS_FCNTL, uintptr(fd), syscall.F_GETFD, 0)
	if errno != 0 {
		return fmt.Errorf("read advisory lock descriptor flags: %w", errno)
	}
	if _, _, errno := syscall.Syscall(
		syscall.SYS_FCNTL,
		uintptr(fd),
		syscall.F_SETFD,
		flags&^syscall.FD_CLOEXEC,
	); errno != 0 {
		return fmt.Errorf("preserve advisory lock across exec: %w", errno)
	}
	if err := os.Setenv(runnerLockHeldEnvironment, "1"); err != nil {
		return fmt.Errorf("mark advisory lock ownership: %w", err)
	}
	return syscall.Exec(command[0], command, os.Environ())
}
