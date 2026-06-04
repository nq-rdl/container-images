#!/usr/bin/env bash
# Fast, deterministic smoke gate for the BE image (must exit 0).
# Exercises the centos7-compiled native binary against UBI9 glibc: assert every
# shared library resolves (no "not found"), which fails closed on a glibc/SONAME
# mismatch — the #1 repackaging risk.
#
# libjvm.so and libjemalloc.so.2 live in non-default paths; start_backend.sh
# adds them to LD_LIBRARY_PATH at runtime.  We replicate that here so that ldd
# sees exactly the same search path as the running process would.
set -euo pipefail
bin=/opt/starrocks/be/lib/starrocks_be
test -x "$bin"

# Mirror start_backend.sh LD_LIBRARY_PATH logic (JAVA_HOME/lib/server for libjvm,
# be/lib/jemalloc for libjemalloc.so.2).
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-11}
export LD_LIBRARY_PATH="${JAVA_HOME}/lib/server:${JAVA_HOME}/lib:/opt/starrocks/be/lib/jemalloc${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

if ldd "$bin" 2>&1 | grep -q 'not found'; then
  echo "FAIL: unresolved shared libraries for $bin"; ldd "$bin" | grep 'not found'; exit 1
fi
java -version
test -L /opt/starrocks/cn
echo "starrocks-be-ubi9 smoke OK"
