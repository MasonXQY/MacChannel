// Command runner-lock acquires the host runner's process-scoped advisory lock
// and replaces itself with the protected command.
package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	flags := flag.NewFlagSet("runner-lock", flag.ContinueOnError)
	lockFile := flags.String("lock-file", "", "absolute advisory lock path")
	selfDelete := flags.String("self-delete", "", "temporary helper path to unlink before waiting")
	if err := flags.Parse(os.Args[1:]); err != nil {
		fatal(err)
	}
	command := flags.Args()
	if *lockFile == "" || len(command) == 0 {
		fatal(fmt.Errorf("lock-file and command are required"))
	}
	if err := execWithAdvisoryLock(*lockFile, *selfDelete, command); err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	_, _ = fmt.Fprintln(os.Stderr, "runner-lock:", err)
	os.Exit(1)
}
