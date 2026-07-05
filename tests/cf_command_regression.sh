#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=""
TUNNEL_ID="11111111-1111-1111-1111-111111111111"

cleanup() {
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

write_fake_bins() {
  local bin="$1"
  cat > "$bin/sudo" <<'EOF'
#!/usr/bin/env sh
exec "$@"
EOF
  chmod +x "$bin/sudo"

  cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_SYSTEMCTL_LOG:?}"
case "${1:-}" in
  list-unit-files) exit 0 ;;
  is-enabled) exit 1 ;;
  is-active) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$bin/systemctl"

  cat > "$bin/cloudflared" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CLOUDFLARED_LOG:?}"
case "${1:-}" in
  --version)
    echo "cloudflared version fake"
    ;;
  tunnel)
    case "${2:-}" in
      list)
        printf '%s %s\n' "${FAKE_TUNNEL_ID:?}" "demo"
        ;;
      delete)
        if [[ "${FAKE_CLOUDFLARED_DELETE_FAIL:-0}" == "1" ]]; then
          echo "delete failed" >&2
          exit 1
        fi
        echo "deleted ${3:-}"
        ;;
      info)
        echo "info ${3:-}"
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$bin/cloudflared"
}

run_cf() {
  env \
    PATH="$TMP_DIR/bin:$PATH" \
    CLOUDFLARED_BIN="$TMP_DIR/bin/cloudflared" \
    CLOUDFLARED_HOME="$TMP_DIR/home" \
    SERVICE_DIR="$TMP_DIR/systemd" \
    FAKE_TUNNEL_ID="$TUNNEL_ID" \
    FAKE_CLOUDFLARED_LOG="$TMP_DIR/cloudflared.log" \
    FAKE_SYSTEMCTL_LOG="$TMP_DIR/systemctl.log" \
    "$@"
}

write_standard_config() {
  local url="${1:-http://127.0.0.1:8080}"
  local cred="$TMP_DIR/home/${TUNNEL_ID}.json"
  printf '%s\n' \
    "url: '$url'" \
    "tunnel: '$TUNNEL_ID'" \
    "credentials-file: '$cred'" > "$TMP_DIR/home/demo.yml"
  printf '%s\n' '{}' > "$cred"
  printf '%s\n' '[Service]' > "$TMP_DIR/systemd/cf-tunnel-demo.service"
}

assert_no_real_paths_used() {
  ! grep -q '/etc/systemd/system' "$TMP_DIR/systemctl.log" 2>/dev/null || fail "real systemd path leaked into test"
}

TMP_DIR="$(mktemp -d)"
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home" "$TMP_DIR/systemd"
: > "$TMP_DIR/cloudflared.log"
: > "$TMP_DIR/systemctl.log"
printf '%s\n' cert > "$TMP_DIR/home/cert.pem"
write_fake_bins "$TMP_DIR/bin"

write_standard_config "http://127.0.0.1:8000"
run_cf bash "$ROOT_DIR/cf.sh" set-url demo "http://127.0.0.1:8080/path?a=1&b='#x'" >/dev/null
grep -qx "url: 'http://127.0.0.1:8080/path?a=1&b=''#x'''" "$TMP_DIR/home/demo.yml" || fail "set-url did not quote url safely"
grep -qx "tunnel: '$TUNNEL_ID'" "$TMP_DIR/home/demo.yml" || fail "set-url lost tunnel id"
grep -qx "credentials-file: '$TMP_DIR/home/${TUNNEL_ID}.json'" "$TMP_DIR/home/demo.yml" || fail "set-url lost credentials"
[[ ! -s "$TMP_DIR/cloudflared.log" ]] || fail "set-url should not call cloudflared"
[[ ! -s "$TMP_DIR/systemctl.log" ]] || fail "set-url should not call systemctl"

cat > "$TMP_DIR/home/demo.yml" <<EOF
tunnel: '$TUNNEL_ID'
credentials-file: '$TMP_DIR/home/${TUNNEL_ID}.json'
ingress:
  - service: http://127.0.0.1:9090
EOF
run_cf bash "$ROOT_DIR/cf.sh" repair demo >/dev/null
grep -qx "url: 'http://127.0.0.1:9090'" "$TMP_DIR/home/demo.yml" || fail "repair did not recover service url"
grep -qx "tunnel: '$TUNNEL_ID'" "$TMP_DIR/home/demo.yml" || fail "repair lost tunnel id"
[[ ! -s "$TMP_DIR/cloudflared.log" ]] || fail "repair should not call cloudflared"
[[ ! -s "$TMP_DIR/systemctl.log" ]] || fail "repair should not call systemctl"

write_standard_config "http://127.0.0.1:7000"
if run_cf env FAKE_CLOUDFLARED_DELETE_FAIL=1 bash "$ROOT_DIR/cf.sh" delete demo >/dev/null 2>/dev/null; then
  fail "delete should fail when fake cloudflared delete fails"
fi
[[ -f "$TMP_DIR/home/demo.yml" ]] || fail "delete failure should preserve yml"
[[ -f "$TMP_DIR/systemd/cf-tunnel-demo.service" ]] || fail "delete failure should preserve service"
[[ -f "$TMP_DIR/home/${TUNNEL_ID}.json" ]] || fail "delete failure should preserve credentials"
grep -q "tunnel delete $TUNNEL_ID" "$TMP_DIR/cloudflared.log" || fail "delete did not call fake cloudflared"

write_standard_config "http://127.0.0.1:7000"
run_cf bash "$ROOT_DIR/cf.sh" delete demo >/dev/null
[[ ! -e "$TMP_DIR/home/demo.yml" ]] || fail "delete success should remove yml"
[[ ! -e "$TMP_DIR/systemd/cf-tunnel-demo.service" ]] || fail "delete success should remove service"
[[ ! -e "$TMP_DIR/home/${TUNNEL_ID}.json" ]] || fail "delete success should remove credentials"
grep -q '^daemon-reload$' "$TMP_DIR/systemctl.log" || fail "delete success should daemon-reload"
assert_no_real_paths_used

echo "ok - cf command fake cloudflared/systemctl"
