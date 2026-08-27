package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

const maximumCopiedFileSize = 64 * 1024

type copySpec struct {
	source      string
	destination string
}

type copyFlags []copySpec

func (c *copyFlags) String() string { return fmt.Sprintf("%d files", len(*c)) }

func (c *copyFlags) Set(value string) error {
	source, destination, ok := strings.Cut(value, "=")
	if !ok || !filepath.IsAbs(source) || !filepath.IsAbs(destination) || !strings.HasPrefix(filepath.Clean(destination), "/run/") {
		return errors.New("copy must be ABSOLUTE_SOURCE=/run/ABSOLUTE_DESTINATION")
	}
	*c = append(*c, copySpec{source: filepath.Clean(source), destination: filepath.Clean(destination)})
	return nil
}

func main() {
	var copies copyFlags
	uidText := flag.String("uid", "", "non-root runtime uid")
	gidText := flag.String("gid", "", "non-root runtime gid")
	flag.Var(&copies, "copy", "copy root-readable file to a private runtime path")
	flag.Parse()
	uid, uidError := strconv.Atoi(*uidText)
	gid, gidError := strconv.Atoi(*gidText)
	command := flag.Args()
	if uidError != nil || gidError != nil || uid <= 0 || gid <= 0 || len(copies) == 0 || len(command) == 0 {
		fatal("uid, gid, at least one copy, and a command are required")
	}
	if os.Geteuid() != 0 {
		fatal("launcher must begin as root")
	}
	if err := prepareCopies(copies, uid, gid); err != nil {
		fatal(err.Error())
	}
	if err := syscall.Setgroups([]int{}); err != nil {
		fatal("clear supplementary groups: " + err.Error())
	}
	if err := syscall.Setgid(gid); err != nil {
		fatal("set runtime gid: " + err.Error())
	}
	if err := syscall.Setuid(uid); err != nil {
		fatal("set runtime uid: " + err.Error())
	}
	if err := syscall.Exec(command[0], command, os.Environ()); err != nil {
		fatal("exec runtime: " + err.Error())
	}
}

func prepareCopies(copies []copySpec, uid, gid int) error {
	seenDestinations := make(map[string]bool, len(copies))
	for _, item := range copies {
		if seenDestinations[item.destination] {
			return fmt.Errorf("duplicate runtime destination %q", item.destination)
		}
		seenDestinations[item.destination] = true
		sourceDescriptor, err := syscall.Open(item.source, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
		if err != nil {
			return fmt.Errorf("open source %q: %w", item.source, err)
		}
		source := os.NewFile(uintptr(sourceDescriptor), item.source)
		info, err := source.Stat()
		if err != nil {
			source.Close()
			return fmt.Errorf("inspect source %q: %w", item.source, err)
		}
		if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maximumCopiedFileSize {
			source.Close()
			return fmt.Errorf("source %q must be a non-empty regular file no larger than 64 KiB", item.source)
		}
		parent := filepath.Dir(item.destination)
		if err := os.MkdirAll(parent, 0o700); err != nil {
			source.Close()
			return fmt.Errorf("create runtime directory: %w", err)
		}
		parentInfo, err := os.Lstat(parent)
		if err != nil || !parentInfo.IsDir() || parentInfo.Mode()&os.ModeSymlink != 0 {
			source.Close()
			return fmt.Errorf("runtime parent %q must be a real directory", parent)
		}
		if err := os.Chown(parent, uid, gid); err != nil {
			source.Close()
			return fmt.Errorf("own runtime directory: %w", err)
		}
		if err := os.Chmod(parent, 0o700); err != nil {
			source.Close()
			return fmt.Errorf("protect runtime directory: %w", err)
		}
		// A Docker process restart preserves tmpfs. Unlink the exact prior entry
		// so a valid restart works while never following a service-created link.
		if err := os.Remove(item.destination); err != nil && !errors.Is(err, os.ErrNotExist) {
			source.Close()
			return fmt.Errorf("remove prior runtime copy: %w", err)
		}
		destination, err := os.OpenFile(item.destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			source.Close()
			return fmt.Errorf("create runtime copy: %w", err)
		}
		_, copyError := io.Copy(destination, io.LimitReader(source, maximumCopiedFileSize+1))
		closeDestinationError := destination.Close()
		closeSourceError := source.Close()
		if copyError != nil || closeDestinationError != nil || closeSourceError != nil {
			_ = os.Remove(item.destination)
			return errors.New("copy runtime secret")
		}
		if err := os.Chown(item.destination, uid, gid); err != nil {
			_ = os.Remove(item.destination)
			return fmt.Errorf("own runtime copy: %w", err)
		}
		if err := os.Chmod(item.destination, 0o400); err != nil {
			_ = os.Remove(item.destination)
			return fmt.Errorf("protect runtime copy: %w", err)
		}
	}
	return nil
}

func fatal(message string) {
	_, _ = fmt.Fprintln(os.Stderr, "secret-launcher:", message)
	os.Exit(1)
}
