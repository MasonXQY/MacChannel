#!/usr/bin/env python3
import argparse
import os
import signal
import subprocess
import sys
import time


def wait_for_exit(process: subprocess.Popen[bytes], seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return True
        time.sleep(0.05)
    return process.poll() is not None


parser = argparse.ArgumentParser()
parser.add_argument("--timeout", type=float, required=True)
parser.add_argument("--log", required=True)
parser.add_argument("command", nargs=argparse.REMAINDER)
arguments = parser.parse_args()
if not arguments.command:
    parser.error("a command is required")

with open(arguments.log, "wb") as log:
    process = subprocess.Popen(
        arguments.command,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    if wait_for_exit(process, arguments.timeout):
        sys.exit(process.returncode)

    os.killpg(process.pid, signal.SIGTERM)
    if not wait_for_exit(process, 2.0):
        os.killpg(process.pid, signal.SIGKILL)
        if not wait_for_exit(process, 2.0):
            print("bounded-process failure unreaped-process-group", file=sys.stderr)
            sys.exit(70)
    process.wait()
    sys.exit(124)
