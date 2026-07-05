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
    authentication:
      - "nested:keep"
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

write_proxy_auth_credentials "alice" "p:a'ss"

grep -qx "authentication:" "$CONFIG_FILE" || fail "top-level authentication was not added"
grep -qx "  - 'alice:p:a''ss'" "$CONFIG_FILE" || fail "authentication entry was not quoted safely"
grep -qx "    authentication:" "$CONFIG_FILE" || fail "nested authentication should not be removed"
grep -qx "      - \"nested:keep\"" "$CONFIG_FILE" || fail "nested authentication entry should not be touched"
[[ "$(get_proxy_auth_entry)" == "alice:p:a'ss" ]] || fail "proxy auth readback failed"
[[ "$(get_proxy_auth_user)" == "alice" ]] || fail "proxy auth user readback failed"

cat >> "$CONFIG_FILE" <<'EOF'
skip-auth-prefixes:
  - 127.0.0.1/8
EOF

create_subscription_config >/dev/null

grep -qx "authentication:" "$CONFIG_FILE" || fail "subscription config should preserve authentication"
grep -qx "  - 'alice:p:a''ss'" "$CONFIG_FILE" || fail "subscription config should preserve authentication entry"
grep -qx "skip-auth-prefixes:" "$CONFIG_FILE" || fail "subscription config should preserve skip-auth-prefixes"
grep -qx "  - 127.0.0.1/8" "$CONFIG_FILE" || fail "subscription config should preserve skip-auth-prefixes entry"
[[ "$(get_proxy_auth_entry)" == "alice:p:a'ss" ]] || fail "subscription auth readback failed"

clear_proxy_auth_config

! grep -qx "authentication:" "$CONFIG_FILE" || fail "top-level authentication should be cleared"
grep -qx "skip-auth-prefixes:" "$CONFIG_FILE" || fail "clearing authentication should not remove skip-auth-prefixes"

check_root() {
  return 0
}

test_and_restart() {
  return 0
}

auth_output="$(manage_proxy_auth set bob secret-pass 2>&1)"
[[ "$auth_output" != *"secret-pass"* ]] || fail "auth command output should not leak password"
[[ "$(get_proxy_auth_entry)" == "bob:secret-pass" ]] || fail "auth command set failed"

manage_proxy_auth off >/dev/null
! grep -qx "authentication:" "$CONFIG_FILE" || fail "auth command off should clear top-level authentication"

write_proxy_auth_credentials "hashuser" "p #ss"
[[ "$(get_proxy_auth_entry)" == "hashuser:p #ss" ]] || fail "quoted auth with hash should round-trip"
clear_proxy_auth_config

echo "ok - mihomo yaml helper fallback"
