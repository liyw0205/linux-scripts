#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REAL_FILE="$(command -v file || true)"

cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

write_fake_bins() {
  local bin="$1"

  cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$out" ]] || exit 2
case "${FAKE_CURL_MODE:-html}" in
  html)
    {
      printf '<html><body>'
      printf '%120s' "bad"
      printf '</body></html>'
    } > "$out"
    exit 0
    ;;
  fail)
    printf 'partial' > "$out"
    exit 23
    ;;
esac
EOF
  chmod +x "$bin/curl"

  cat > "$bin/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${FAKE_FILE_TYPE:-html}" in
  html) echo "$1: HTML document" ;;
  *) exec "${REAL_FILE:?}" "$@" ;;
esac
EOF
  chmod +x "$bin/file"
}

reset_mihomo_paths() {
  rm -rf "$TMP_DIR/mihomo" "$TMP_DIR/opt"
  MIHOMO_DIR="$TMP_DIR/mihomo"
  MIHOMO_BIN_DIR="$TMP_DIR/opt"
  MIHOMO_BIN="$MIHOMO_BIN_DIR/mihomo"
  CONFIG_FILE="$MIHOMO_DIR/config.yaml"
  SERVICE_FILE="$TMP_DIR/systemd/mihomo.service"
  UI_DIR="$MIHOMO_DIR/ui"
  SUB_FILE="$MIHOMO_DIR/subscription.yaml"
  COUNTRY_MMDB="$MIHOMO_DIR/Country.mmdb"
  SOCKS5_GROUP_STATE="$MIHOMO_DIR/socks5_group.conf"
  mkdir -p "$MIHOMO_DIR" "$MIHOMO_BIN_DIR" "$TMP_DIR/systemd"
}

assert_old_ui() {
  [[ "$(cat "$UI_DIR/index.html")" == "old ui" ]] || fail "old UI was not preserved"
  if find "$MIHOMO_DIR" -maxdepth 1 -name '.ui-download.*' -print -quit | grep -q .; then
    fail "temporary UI staging directory leaked"
  fi
}

mkdir -p "$TMP_DIR/bin"
write_fake_bins "$TMP_DIR/bin"
export PATH="$TMP_DIR/bin:$PATH"
export REAL_FILE

# shellcheck disable=SC1090
. "$ROOT_DIR/mihomo.sh"

get_github_mirrors() {
  echo ""
}

reset_mihomo_paths
target="$TMP_DIR/download/artifact.bin"
mkdir -p "$(dirname "$target")"
printf '%s\n' "old artifact" > "$target"
if FAKE_CURL_MODE=html FAKE_FILE_TYPE=html download_file "https://example.invalid/artifact" "$target" "artifact" >/dev/null 2>/dev/null; then
  fail "download_file should reject HTML payload"
fi
grep -qx "old artifact" "$target" || fail "download_file should preserve existing output on invalid payload"
if find "$(dirname "$target")" -maxdepth 1 -name '.artifact.bin.download.*' -print -quit | grep -q .; then
  fail "download_file leaked temporary output"
fi

reset_mihomo_paths
printf '%s\n' "old core" > "$MIHOMO_BIN"
chmod 755 "$MIHOMO_BIN"
download_file() {
  printf '%s\n' "not gzip" > "$2"
  return 0
}
if download_and_install_core >/dev/null 2>/dev/null; then
  fail "bad gzip should fail core install"
fi
grep -qx "old core" "$MIHOMO_BIN" || fail "bad core install should preserve existing binary"
[[ -x "$MIHOMO_BIN" ]] || fail "old core executable bit should be preserved"
if find "$MIHOMO_BIN_DIR" -maxdepth 1 -name '.mihomo.*' -print -quit | grep -q .; then
  fail "core install leaked temporary binary"
fi

reset_mihomo_paths
mkdir -p "$UI_DIR"
printf '%s\n' "old ui" > "$UI_DIR/index.html"
download_file() {
  return 1
}
if install_metacubexd >/dev/null 2>/dev/null; then
  fail "frontend download failure should fail"
fi
assert_old_ui

reset_mihomo_paths
mkdir -p "$UI_DIR"
printf '%s\n' "old ui" > "$UI_DIR/index.html"
download_file() {
  printf '%s\n' "not tar" > "$2"
  return 0
}
if install_metacubexd >/dev/null 2>/dev/null; then
  fail "bad MetaCubeXD archive should fail"
fi
assert_old_ui

reset_mihomo_paths
mkdir -p "$UI_DIR"
printf '%s\n' "old ui" > "$UI_DIR/index.html"
download_file() {
  printf '%s\n' "not zip" > "$2"
  return 0
}
if install_zashboard >/dev/null 2>/dev/null; then
  fail "bad Zashboard archive should fail"
fi
assert_old_ui

echo "ok - mihomo install paths preserve existing artifacts"
