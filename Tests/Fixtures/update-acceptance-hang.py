#!/usr/bin/env python3
import subprocess
import sys


marker = sys.argv[1]
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", marker])
child.wait()
