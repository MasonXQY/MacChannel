#!/usr/bin/env bash
set -euo pipefail

# Signing must not stage inside a Documents/iCloud output folder. Ignore TMPDIR:
# callers may point it at the repository or another synchronized directory.
# mktemp creates a unique directory; umask protects it from its first creation.
umask 077
/usr/bin/mktemp -d /private/tmp/dropmesh-store.XXXXXX
