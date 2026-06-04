#!/usr/bin/env bash
# Fast, deterministic smoke gate for the CN image (must exit 0). CN uses the BE binary.
# Sets LD_LIBRARY_PATH as start_backend.sh does (libjvm.so / libjemalloc.so.2 live in
# non-default paths) so ldd sees the real runtime search path; fails closed on any
# unresolved library — the centos7->UBI9 glibc gate.
set -euo pipefail
bin=/opt/starrocks/be/lib/starrocks_be
test -x "$bin"
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-11}
export LD_LIBRARY_PATH="${JAVA_HOME}/lib/server:${JAVA_HOME}/lib:/opt/starrocks/be/lib/jemalloc${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
if ldd "$bin" 2>&1 | grep -q 'not found'; then
  echo "FAIL: unresolved shared libraries for $bin"; ldd "$bin" | grep 'not found'; exit 1
fi
java -version
test -L /opt/starrocks/cn
echo "starrocks-cn-ubi9 smoke OK"
