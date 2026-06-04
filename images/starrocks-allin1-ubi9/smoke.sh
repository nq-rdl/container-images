#!/usr/bin/env bash
# Fast, deterministic smoke gate for the allin1 image (must exit 0). The default
# CMD starts a full cluster (too heavy for smoke); smoke-cmd overrides it.
# Sets LD_LIBRARY_PATH as start_backend.sh does so ldd validates the centos7->UBI9
# glibc link; fails closed on any unresolved library.
set -euo pipefail
bin=/data/deploy/starrocks/be/lib/starrocks_be
test -x "$bin"
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-17}
export LD_LIBRARY_PATH="${JAVA_HOME}/lib/server:${JAVA_HOME}/lib:/data/deploy/starrocks/be/lib/jemalloc${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
if ldd "$bin" 2>&1 | grep -q 'not found'; then
  echo "FAIL: unresolved shared libraries for $bin"; ldd "$bin" | grep 'not found'; exit 1
fi
java -version
command -v supervisord
command -v nginx
test -f /data/deploy/starrocks/fe/lib/starrocks-fe.jar
echo "starrocks-allin1-ubi9 smoke OK"
