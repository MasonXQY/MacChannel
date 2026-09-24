package main

import (
	"io"
	"os"
	"time"

	"dropmesh.local/privacy-evidence/internal/evidence"
)

const utcLayout = "2006-01-02T15:04:05Z"

var (
	readInputs   = evidence.ReadInputs
	verifyBundle = evidence.Verify
)

func main() { os.Exit(Run(os.Args[1:], os.Stdout)) }

// Run executes the synthetic-only verifier and emits exactly one fixed result line.
func Run(args []string, out io.Writer) int {
	if len(args) != 7 || args[0] != "verify-fixture" {
		return writeResult(out, 2, "PRIVACY_VERIFIER_BLOCKED:usage\n")
	}
	values := make(map[string]string, 3)
	for index := 1; index < len(args); index += 2 {
		flag, value := args[index], args[index+1]
		if value == "" || (flag != "--bundle" && flag != "--test-policy" && flag != "--now") {
			return writeResult(out, 2, "PRIVACY_VERIFIER_BLOCKED:usage\n")
		}
		if _, duplicate := values[flag]; duplicate {
			return writeResult(out, 2, "PRIVACY_VERIFIER_BLOCKED:usage\n")
		}
		values[flag] = value
	}
	if len(values) != 3 {
		return writeResult(out, 2, "PRIVACY_VERIFIER_BLOCKED:usage\n")
	}
	now, err := time.Parse(utcLayout, values["--now"])
	if err != nil || now.Format(utcLayout) != values["--now"] {
		return writeResult(out, 2, "PRIVACY_VERIFIER_BLOCKED:usage\n")
	}
	bundle, policy, failure := readInputs(values["--bundle"], values["--test-policy"])
	if failure == nil {
		failure = verifyBundle(bundle, policy, now)
	}
	if failure == nil {
		return writeResult(out, 0, "FIXTURE_INTEGRITY_OK_NOT_RELEASE_APPROVAL\n")
	}
	return writeFailure(out, failure.Category)
}

func writeFailure(out io.Writer, category evidence.Category) int {
	switch category {
	case evidence.InvalidSchema:
		return writeResult(out, 1, "FIXTURE_REJECTED:schema\n")
	case evidence.InvalidPolicy:
		return writeResult(out, 1, "FIXTURE_REJECTED:policy\n")
	case evidence.InvalidSignature:
		return writeResult(out, 1, "FIXTURE_REJECTED:signature\n")
	case evidence.InvalidInventory:
		return writeResult(out, 1, "FIXTURE_REJECTED:inventory\n")
	case evidence.InvalidReceipt:
		return writeResult(out, 1, "FIXTURE_REJECTED:receipt\n")
	case evidence.InvalidTime:
		return writeResult(out, 1, "FIXTURE_REJECTED:time\n")
	case evidence.UnsafeInput:
		return writeResult(out, 2, "PRIVACY_VERIFIER_BLOCKED:unsafe-input\n")
	case evidence.UnavailableInput:
		return writeResult(out, 2, "PRIVACY_VERIFIER_BLOCKED:unavailable-input\n")
	case evidence.InvalidUsage:
		return writeResult(out, 2, "PRIVACY_VERIFIER_BLOCKED:usage\n")
	default:
		return writeResult(out, 2, "PRIVACY_VERIFIER_BLOCKED:internal\n")
	}
}

func writeResult(out io.Writer, code int, line string) int {
	_, _ = io.WriteString(out, line)
	return code
}
