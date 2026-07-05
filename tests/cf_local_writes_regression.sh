#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=""

cleanup() {
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d)"
# shellcheck disable=SC1090
. "$ROOT_DIR/cf.sh"

run_root() {
  "$@"
}

CLOUDFLARED_HOME="$TMP_DIR/home"
SERVICE_DIR="$TMP_DIR/systemd"
TMP_ROOT="$TMP_DIR"
mkdir -p "$CLOUDFLARED_HOME" "$SERVICE_DIR"

write_local_tunnel_files demo tunnel-id http://127.0.0.1:8080 || fail "bundle write failed"
grep -qx "url: 'http://127.0.0.1:8080'" "$CLOUDFLARED_HOME/demo.yml" || fail "url not written"
grep -qx "tunnel: 'tunnel-id'" "$CLOUDFLARED_HOME/demo.yml" || fail "tunnel id not written"
grep -q "ExecStart=.*demo.yml run" "$SERVICE_DIR/cf-tunnel-demo.service" || fail "service not written"

printf '%s\n' "old-yml" > "$CLOUDFLARED_HOME/demo.yml"
printf '%s\n' "old-service" > "$SERVICE_DIR/cf-tunnel-demo.service"

write_service_file() {
  printf '%s\n' "broken-service" > "$(service_file "$1")"
  return 1
}

if write_local_tunnel_files demo new-id http://127.0.0.1:9090 2>/dev/null; then
  fail "bundle write should fail when service writer fails"
fi

grep -qx "old-yml" "$CLOUDFLARED_HOME/demo.yml" || fail "yml was not rolled back"
grep -qx "old-service" "$SERVICE_DIR/cf-tunnel-demo.service" || fail "service was not rolled back"
echo "ok - cf local bundle write rollback"
