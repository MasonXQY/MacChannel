//go:build !darwin

package accountauth

import "os/exec"

func configureNativeGroupReadProcess(_ *exec.Cmd) {}

func terminateNativeGroupReadProcess(_ *exec.Cmd) error { return nil }
