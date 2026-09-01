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


def process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_for_group_exit(
    process: subprocess.Popen[bytes], process_group: int, seconds: float
) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        process.poll()
        if not process_group_exists(process_group):
            return True
        time.sleep(0.05)
    process.poll()
    return not process_group_exists(process_group)


def terminate_process_group(
    process: subprocess.Popen[bytes], process_group: int
) -> bool:
    if process_group_exists(process_group):
        os.killpg(process_group, signal.SIGTERM)
    if not wait_for_group_exit(process, process_group, 2.0):
        if process_group_exists(process_group):
            os.killpg(process_group, signal.SIGKILL)
        if not wait_for_group_exit(process, process_group, 2.0):
            return False
    process.poll()
    return process.returncode is not None


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
        leader_status = process.returncode
        if process_group_exists(process.pid) and not terminate_process_group(process, process.pid):
            print("bounded-process failure unreaped-process-group", file=sys.stderr)
            sys.exit(70)
        sys.exit(leader_status)

    if not terminate_process_group(process, process.pid):
        print("bounded-process failure unreaped-process-group", file=sys.stderr)
        sys.exit(70)
    sys.exit(124)
