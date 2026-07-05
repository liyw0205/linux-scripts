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
. "$ROOT_DIR/mihomo.sh"

MIHOMO_DIR="$TMP_DIR/mihomo"
CONFIG_FILE="$MIHOMO_DIR/config.yaml"
mkdir -p "$MIHOMO_DIR"

has_mikefarah_yq() {
  return 1
}

has_python_yaml() {
  return 1
}

cat > "$CONFIG_FILE" <<'EOF'
port: 7890 # old http
proxies:
  - name: local
    port: 1234
socks-port: 7891
external-controller: '127.0.0.1:9090'
secret: oldsecret
port: 7777
rules:
  - MATCH,DIRECT
EOF

[[ "$(get_config_value port)" == "7890" ]] || fail "fallback read port failed"
[[ "$(get_config_value external-controller)" == "127.0.0.1:9090" ]] || fail "fallback read quoted controller failed"

set_config_value port 8888
set_config_value socks-port 8889
set_config_value external-controller 127.0.0.1:8890
set_config_value secret newsecret

[[ "$(grep -c '^port:' "$CONFIG_FILE")" -eq 1 ]] || fail "duplicate top-level port was not collapsed"
grep -qx "port: 8888" "$CONFIG_FILE" || fail "port was not updated"
grep -qx "socks-port: 8889" "$CONFIG_FILE" || fail "socks-port was not updated"
grep -qx "external-controller: 127.0.0.1:8890" "$CONFIG_FILE" || fail "controller was not updated"
grep -qx "secret: newsecret" "$CONFIG_FILE" || fail "secret was not updated"
grep -qx "    port: 1234" "$CONFIG_FILE" || fail "nested port should not be touched"

echo "ok - mihomo yaml helper fallback"
