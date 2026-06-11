#!/usr/bin/env bash
# Fast, deterministic smoke gate for the jamovi server image (must exit 0).
# Validates that the multi-stage assembly is intact and the Python server package imports
# (the latter exercises the protobuf gencode path — the most likely UBI9-port failure point)
# without actually starting the long-running server.
set -euo pipefail

# Assembled artifacts from each build stage.
test -d /usr/lib/jamovi/client
test -f /usr/lib/jamovi/bin/env.conf
test -x /usr/lib/jamovi/bin/jamovi-engine
test -d /usr/lib/jamovi/modules
test -d /usr/lib/jamovi/i18n/json

# R base + Python 3.12 interpreter the server runs under.
R --version >/dev/null
/usr/bin/python3.12 --version

# The pip-installed runtime deps must be importable. These are C-extension packages that land in
# the platlib tree (/usr/local/lib64/...), so this fails loudly if that tree was not copied. It
# also exercises the nanomsg ctypes/SO binding and the protobuf runtime (the protoc-gencode path).
/usr/bin/python3.12 -c "import numpy, aiohttp, google.protobuf, nanomsg"

# The server package itself must import (resolves jamovi_pb2 against the protobuf runtime).
PYTHONPATH=/usr/lib/jamovi/server /usr/bin/python3.12 -c "import jamovi.server"

echo "jamovi-ubi9 smoke OK"
