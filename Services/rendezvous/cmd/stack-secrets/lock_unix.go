//go:build darwin || linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

type stackSecretsLock struct {
	file *os.File
}

func acquireStackSecretsLock(directory string) (*stackSecretsLock, error) {
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return nil, fmt.Errorf("create stack-secret directory before locking: %w", err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return nil, fmt.Errorf("protect stack-secret directory before locking: %w", err)
	}
	path := filepath.Join(directory, stackSecretsLockName)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open stack-secret lock: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		file.Close()
		return nil, fmt.Errorf("protect stack-secret lock: %w", err)
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX); err != nil {
		file.Close()
		return nil, fmt.Errorf("acquire stack-secret lock: %w", err)
	}
	return &stackSecretsLock{file: file}, nil
}

func (lock *stackSecretsLock) Close() error {
	if lock == nil || lock.file == nil {
		return nil
	}
	unlockError := syscall.Flock(int(lock.file.Fd()), syscall.LOCK_UN)
	closeError := lock.file.Close()
	lock.file = nil
	if unlockError != nil {
		return unlockError
	}
	return closeError
}
