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
case "${FAKE_FILE_TYPE:-real}" in
  html) echo "$1: HTML document" ;;
  *) exec "${REAL_FILE:?}" "$@" ;;
esac
EOF
  chmod +x "$bin/file"
}

make_large_binary() {
  local file="$1"
  dd if=/dev/zero bs=1024 count=128 of="$file" >/dev/null 2>&1
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
  SUB_URL_FILE="$MIHOMO_DIR/subscription.url"
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

assert_no_mihomo_temp() {
  local dir="$1" pattern="$2" label="$3"
  if find "$dir" -maxdepth 1 -name "$pattern" -print -quit | grep -q .; then
    fail "$label leaked temporary file"
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
printf '%s\n' "old core" > "$MIHOMO_BIN"
download_file() {
  printf '%s\n' "new core" | gzip > "$2"
  return 0
}
download_and_install_core >/dev/null
grep -qx "new core" "$MIHOMO_BIN" || fail "successful core install should publish new binary"
[[ -x "$MIHOMO_BIN" ]] || fail "successful core install should publish executable binary"
assert_no_mihomo_temp "$MIHOMO_BIN_DIR" ".mihomo.*" "core install"

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

reset_mihomo_paths
mkdir -p "$UI_DIR"
printf '%s\n' "old ui" > "$UI_DIR/index.html"
download_file() {
  local tar_root
  tar_root="$(mktemp -d "$TMP_DIR/meta-ui.XXXXXX")"
  mkdir -p "$tar_root/dist"
  printf '%s\n' "new meta ui" > "$tar_root/dist/index.html"
  tar -czf "$2" -C "$tar_root" dist
  rm -rf "$tar_root"
  return 0
}
install_metacubexd >/dev/null
grep -qx "new meta ui" "$UI_DIR/index.html" || fail "MetaCubeXD success should publish new UI"
grep -qx "metacubexd" "$UI_DIR/.frontend_info" || fail "MetaCubeXD frontend info missing"
grep -qx "MetaCubeXD ${METACUBEXD_VERSION}" "$UI_DIR/.frontend_version" || fail "MetaCubeXD version missing"
assert_no_mihomo_temp "$MIHOMO_DIR" ".ui-download.*" "MetaCubeXD install"

reset_mihomo_paths
mkdir -p "$UI_DIR"
printf '%s\n' "old ui" > "$UI_DIR/index.html"
download_file() {
  local zip_root
  zip_root="$(mktemp -d "$TMP_DIR/zash-ui.XXXXXX")"
  mkdir -p "$zip_root/dist"
  printf '%s\n' "new zash ui" > "$zip_root/dist/index.html"
  (cd "$zip_root" && zip -q -r "$2" dist)
  rm -rf "$zip_root"
  return 0
}
install_zashboard >/dev/null
grep -qx "new zash ui" "$UI_DIR/index.html" || fail "Zashboard success should publish new UI"
grep -qx "zashboard" "$UI_DIR/.frontend_info" || fail "Zashboard frontend info missing"
grep -qx "Zashboard ${ZASHBOARD_VERSION}" "$UI_DIR/.frontend_version" || fail "Zashboard version missing"
assert_no_mihomo_temp "$MIHOMO_DIR" ".ui-download.*" "Zashboard install"

reset_mihomo_paths
make_large_binary "$COUNTRY_MMDB"
printf '%s\n' "legacy lower" > "$MIHOMO_DIR/country.mmdb"
printf '%s\n' "legacy geoip" > "$MIHOMO_DIR/geoip.metadb"
check_root() { return 0; }
download_file() {
  return 1
}
if download_country_mmdb --force >/dev/null 2>/dev/null; then
  fail "mmdb download failure should fail"
fi
check_country_mmdb || fail "old Country.mmdb should be preserved on download failure"
grep -qx "legacy lower" "$MIHOMO_DIR/country.mmdb" || fail "legacy lower mmdb should be preserved on failure"
grep -qx "legacy geoip" "$MIHOMO_DIR/geoip.metadb" || fail "legacy geoip should be preserved on failure"
assert_no_mihomo_temp "$MIHOMO_DIR" ".Country.mmdb.*" "mmdb failed download"

reset_mihomo_paths
make_large_binary "$COUNTRY_MMDB"
download_file() {
  {
    printf '<html>'
    printf '%120000s' "bad"
    printf '</html>'
  } > "$2"
  return 0
}
if download_country_mmdb --force >/dev/null 2>/dev/null; then
  fail "invalid mmdb payload should fail"
fi
check_country_mmdb || fail "old Country.mmdb should be preserved on invalid payload"
assert_no_mihomo_temp "$MIHOMO_DIR" ".Country.mmdb.*" "mmdb invalid payload"

reset_mihomo_paths
make_large_binary "$COUNTRY_MMDB"
printf '%s\n' "legacy lower" > "$MIHOMO_DIR/country.mmdb"
printf '%s\n' "legacy geoip" > "$MIHOMO_DIR/geoip.metadb"
download_file() {
  make_large_binary "$2"
  return 0
}
download_country_mmdb --force >/dev/null
check_country_mmdb || fail "new Country.mmdb should be valid"
mode="$(stat -c '%a' "$COUNTRY_MMDB" 2>/dev/null || true)"
[[ "$mode" == "644" ]] || fail "Country.mmdb mode should be 644"
[[ ! -e "$MIHOMO_DIR/country.mmdb" ]] || fail "legacy lower mmdb should be removed after success"
[[ ! -e "$MIHOMO_DIR/geoip.metadb" ]] || fail "legacy geoip should be removed after success"
assert_no_mihomo_temp "$MIHOMO_DIR" ".Country.mmdb.*" "mmdb success"

echo "ok - mihomo install paths preserve existing artifacts"
