#!/usr/bin/env bash
# Shared MITM forward-proxy fixture using mitmproxy. Brings up a TLS-inspecting
# forward proxy with its own throwaway CA, mirroring a corporate proxy.
# Pinned by digest so CI/local match.
set -euo pipefail
MITM_IMAGE="docker.io/mitmproxy/mitmproxy@sha256:00b77b5d8804c8ad18cb6caefbf9d5849e895e8986c5ce011f4ae30f4385962f"
MITM_NAME="${MITM_NAME:-proxy-ca-mitm}"
MITM_PORT="${MITM_PORT:-8080}"
CA_DIR="${CA_DIR:-tests/proxy-ca/.ca}"   # gitignored

mitm_up() {
  local runtime="$1"
  mkdir -p "$CA_DIR"
  "$runtime" rm -f "$MITM_NAME" >/dev/null 2>&1 || true
  "$runtime" run -d --name "$MITM_NAME" -p "${MITM_PORT}:8080" \
    -v "$(pwd)/${CA_DIR}:/home/mitmproxy/.mitmproxy" \
    "$MITM_IMAGE" mitmdump --mode regular --listen-port 8080 >/dev/null
  # wait for the CA to be generated
  for _ in $(seq 1 30); do
    [ -f "${CA_DIR}/mitmproxy-ca-cert.pem" ] && break; sleep 1
  done
  [ -f "${CA_DIR}/mitmproxy-ca-cert.pem" ] || { echo "mitm CA not generated"; return 1; }
  cp "${CA_DIR}/mitmproxy-ca-cert.pem" "${CA_DIR}/corp-ca.crt"
}
mitm_fingerprint() {
  openssl x509 -in "${CA_DIR}/corp-ca.crt" -noout -fingerprint -sha256 \
    | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f'
}
mitm_down() { "${1:-docker}" rm -f "$MITM_NAME" >/dev/null 2>&1 || true; }
