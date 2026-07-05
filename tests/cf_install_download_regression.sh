#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

write_cloudflared_candidate() {
  local out="$1"
  case "${FAKE_DOWNLOAD_MODE:-ok}" in
    invalid)
      printf '%s\n' "not executable payload" > "$out"
      ;;
    ok)
      cat > "$out" <<'EOF'
#!/usr/bin/env sh
case "${1:-}" in
  --version)
    echo "cloudflared version new"
    exit 0
    ;;
esac
exit 0
EOF
      chmod +x "$out"
      ;;
  esac
}

# shellcheck disable=SC1090
. "$ROOT_DIR/cf.sh"

run_root() {
  if [[ "${FAKE_RUN_ROOT_INSTALL_FAIL:-0}" == "1" && "${1:-}" == "install" ]]; then
    printf '%s\n' "polluted target" > "$CLOUDFLARED_BIN"
    return 1
  fi
  "$@"
}

download_with_proxies() {
  local _url="$1"
  local out="$2"
  case "${FAKE_DOWNLOAD_MODE:-ok}" in
    fail)
      printf '%s\n' "partial download" > "$out"
      return 1
      ;;
    invalid|ok)
      write_cloudflared_candidate "$out"
      return 0
      ;;
  esac
}

reset_binary() {
  mkdir -p "$(dirname "$CLOUDFLARED_BIN")"
  cat > "$CLOUDFLARED_BIN" <<'EOF'
#!/usr/bin/env sh
case "${1:-}" in
  --version)
    echo "cloudflared version old"
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$CLOUDFLARED_BIN"
}

assert_old_binary() {
  grep -q "version old" "$CLOUDFLARED_BIN" || fail "old cloudflared binary should be preserved"
  "$CLOUDFLARED_BIN" --version | grep -qx "cloudflared version old" || fail "old cloudflared should still run"
}

assert_no_cf_temps() {
  if find "$TMP_DIR" -maxdepth 2 \( -name 'cloudflared-linux-*.*' -o -name '.cloudflared.*' -o -name 'cloudflared.backup.*' \) -print -quit | grep -q .; then
    fail "cloudflared temporary artifact leaked"
  fi
}

CLOUDFLARED_BIN="$TMP_DIR/bin/cloudflared"
CLOUDFLARED_HOME="$TMP_DIR/home"
SERVICE_DIR="$TMP_DIR/systemd"
TMP_ROOT="$TMP_DIR"

reset_binary
if (FAKE_DOWNLOAD_MODE=invalid install_cloudflared >/dev/null 2>/dev/null); then
  fail "install should fail for invalid downloaded binary"
fi
assert_old_binary
assert_no_cf_temps

reset_binary
if (FAKE_DOWNLOAD_MODE=ok FAKE_RUN_ROOT_INSTALL_FAIL=1 install_cloudflared >/dev/null 2>/dev/null); then
  fail "install should fail when staging install fails"
fi
assert_old_binary
assert_no_cf_temps

reset_binary
FAKE_DOWNLOAD_MODE=ok install_cloudflared >/dev/null
"$CLOUDFLARED_BIN" --version | grep -qx "cloudflared version new" || fail "successful install should publish new binary"
assert_no_cf_temps

partial="$TMP_DIR/partial.bin"
# Restore the real helper after the install-specific fake above.
# shellcheck disable=SC1090
. "$ROOT_DIR/cf.sh"
CLOUDFLARED_BIN="$TMP_DIR/bin/cloudflared"
CLOUDFLARED_HOME="$TMP_DIR/home"
SERVICE_DIR="$TMP_DIR/systemd"
TMP_ROOT="$TMP_DIR"
http_get() {
  printf '%s\n' "partial" > "$2"
  return 1
}
sorted_proxies() {
  printf '%s\n' "https://proxy.invalid/"
}
proxy_latency_ms() {
  echo 1
}
if download_with_proxies "https://example.invalid/cloudflared" "$partial" >/dev/null 2>/dev/null; then
  fail "download_with_proxies should fail when all downloads fail"
fi
[[ ! -e "$partial" ]] || fail "download_with_proxies should remove failed partial output"

echo "ok - cf install and download preserve artifacts on failure"
