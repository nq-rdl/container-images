#!/usr/bin/env bash
# Fast, deterministic smoke gate for the FE image (must exit 0).
set -euo pipefail
java -version
test -f /opt/starrocks/fe/lib/starrocks-fe.jar
test -x /opt/starrocks/fe/bin/start_fe.sh
echo "starrocks-fe-ubi9 smoke OK"
