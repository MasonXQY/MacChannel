#!/usr/bin/env python3
import subprocess
import sys
import time
import os
import signal


if sys.argv[1] == "--group-server":
    ready = sys.argv[2]
    marker = sys.argv[3]
    os.setsid()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    subprocess.Popen([
        sys.executable,
        "-c",
        "import signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
        marker,
    ])
    with open(ready, "w", encoding="ascii") as output:
        output.write("ready\n")
    time.sleep(30)
elif sys.argv[1] == "--leader-exits":
    marker = sys.argv[2]
    ready = sys.argv[3]
    subprocess.Popen([
        sys.executable,
        "-c",
        "import signal,sys,time; signal.signal(signal.SIGHUP, signal.SIG_IGN); "
        "open(sys.argv[1], 'w', encoding='ascii').write('ready\\n'); time.sleep(30)",
        ready,
        marker,
    ])
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and not __import__("os").path.exists(ready):
        time.sleep(0.01)
    if not __import__("os").path.exists(ready):
        raise SystemExit(70)
else:
    marker = sys.argv[1]
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", marker])
    child.wait()
