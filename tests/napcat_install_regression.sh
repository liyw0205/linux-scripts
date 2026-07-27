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

write_fake_curl() {
  local bin="$1"

  cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$out" ]] || exit 2

# LinuxQQ package download path
if [[ "${url}" == *"/QQ_"* || "${url}" == *"linuxqq"* || "${FAKE_CURL_TARGET:-}" == "qq" ]]; then
  case "${FAKE_QQ_CURL_MODE:-ok}" in
    fail)
      printf '%s\n' "partial qq package" > "$out"
      exit 23
      ;;
    empty)
      : > "$out"
      exit 0
      ;;
    ok)
      printf '%s\n' "fake-qq-package" > "$out"
      exit 0
      ;;
  esac
fi

case "${FAKE_CURL_MODE:-ok}" in
  fail)
    printf '%s\n' "partial installer" > "$out"
    exit 23
    ;;
  empty)
    : > "$out"
    exit 0
    ;;
  html)
    printf '%s\n' "if then" > "$out"
    exit 0
    ;;
  script_fail)
    cat > "$out" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "installer ran" > "${FAKE_INSTALL_MARKER:?}"
exit 42
SCRIPT
    exit 0
    ;;
  ok)
    cat > "$out" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "installer ran" > "${FAKE_INSTALL_MARKER:?}"
# simulate installer that installs napcat only, without QQ
mkdir -p "${NAPCAT_BASE_DIR:?}/napcat"
printf '%s\n' "so" > "${NAPCAT_BASE_DIR}/libnapcat_launcher.so"
exit 0
SCRIPT
    exit 0
    ;;
esac
exit 2
EOF
  chmod +x "$bin/curl"
}

write_fake_pkg_tools() {
  local bin="$1"

  cat > "$bin/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_APT_LOG:?}"
if [[ "${1:-}" == "install" ]]; then
  pkg=""
  for arg in "$@"; do
    pkg="$arg"
  done
  if [[ "$pkg" == *.deb ]]; then
    if [[ "${FAKE_APT_FAIL:-0}" == "1" ]]; then
      exit 1
    fi
    mkdir -p "$(dirname "${FAKE_QQ_PATH:?}")"
    cat > "${FAKE_QQ_PATH}" <<'QQ'
#!/usr/bin/env bash
exit 0
QQ
    chmod +x "${FAKE_QQ_PATH}"
  fi
fi
exit 0
EOF
  chmod +x "$bin/apt-get"

  cat > "$bin/dpkg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin/dpkg"

  cat > "$bin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then
  echo x86_64
  exit 0
fi
exec /usr/bin/uname "$@"
EOF
  chmod +x "$bin/uname"
}

run_install() {
  local base="$1"
  shift
  env \
    PATH="$TMP_DIR/bin:$PATH" \
    NAPCAT_BASE_DIR="$base" \
    NAPCAT_QQ_BIN="$base/usr/bin/qq" \
    NAPCAT_CLI_CONFIG_DIR="$base/config" \
    NAPCAT_CLI_STATE_DIR="$base/state" \
    FAKE_INSTALL_MARKER="$base/installer.marker" \
    FAKE_APT_LOG="$base/apt.log" \
    FAKE_QQ_PATH="$base/usr/bin/qq" \
    "$@" bash "$ROOT_DIR/napcat.sh" install
}

assert_no_temp_installers() {
  local base="$1"
  if find "$base" -maxdepth 1 \( -name '.napcat-install.*' -o -name '.napcat-qq.*' \) -print -quit | grep -q .; then
    fail "temporary installer/qq directory leaked in $base"
  fi
}

assert_old_installer() {
  local base="$1"
  grep -qx "old installer" "$base/napcat-install.sh" || fail "old installer should be preserved"
}

mkdir -p "$TMP_DIR/bin"
write_fake_curl "$TMP_DIR/bin"
write_fake_pkg_tools "$TMP_DIR/bin"

for mode in fail empty html script_fail; do
  base="$TMP_DIR/$mode"
  mkdir -p "$base"
  printf '%s\n' "old installer" > "$base/napcat-install.sh"
  # pre-create qq so install_linuxqq is not the failure mode under test
  mkdir -p "$base/usr/bin"
  printf '#!/bin/sh\nexit 0\n' > "$base/usr/bin/qq"
  chmod +x "$base/usr/bin/qq"
  if run_install "$base" env FAKE_CURL_MODE="$mode" >/dev/null 2>/dev/null; then
    fail "install should fail for curl mode $mode"
  fi
  assert_old_installer "$base"
  assert_no_temp_installers "$base"
done

# success: installer runs, then linuxqq is installed because no existing qq
base="$TMP_DIR/success"
mkdir -p "$base"
run_install "$base" env FAKE_CURL_MODE=ok FAKE_QQ_CURL_MODE=ok >/dev/null
grep -qx "installer ran" "$base/installer.marker" || fail "valid installer should execute"
grep -q "FAKE_INSTALL_MARKER" "$base/napcat-install.sh" || fail "successful install should publish validated installer"
[[ -x "$base/usr/bin/qq" ]] || fail "install should publish linuxqq binary via package install"
grep -q "\.deb" "$base/apt.log" || fail "install should invoke apt-get with deb package"
assert_no_temp_installers "$base"

# install-qq alone when missing
base="$TMP_DIR/qq-only"
mkdir -p "$base"
env \
  PATH="$TMP_DIR/bin:$PATH" \
  NAPCAT_BASE_DIR="$base" \
  NAPCAT_QQ_BIN="$base/usr/bin/qq" \
  NAPCAT_CLI_CONFIG_DIR="$base/config" \
  NAPCAT_CLI_STATE_DIR="$base/state" \
  FAKE_APT_LOG="$base/apt.log" \
  FAKE_QQ_PATH="$base/usr/bin/qq" \
  FAKE_QQ_CURL_MODE=ok \
  FAKE_CURL_TARGET=qq \
  bash "$ROOT_DIR/napcat.sh" install-qq >/dev/null
[[ -x "$base/usr/bin/qq" ]] || fail "install-qq should create qq binary"
assert_no_temp_installers "$base"

# install-qq should reuse existing binary
reuse_log="$base/reuse.log"
env \
  PATH="$TMP_DIR/bin:$PATH" \
  NAPCAT_BASE_DIR="$base" \
  NAPCAT_QQ_BIN="$base/usr/bin/qq" \
  NAPCAT_CLI_CONFIG_DIR="$base/config" \
  NAPCAT_CLI_STATE_DIR="$base/state" \
  FAKE_APT_LOG="$base/apt-reuse.log" \
  FAKE_QQ_PATH="$base/usr/bin/qq" \
  bash "$ROOT_DIR/napcat.sh" install-qq >"$reuse_log"
grep -q "已检测到 LinuxQQ" "$reuse_log" || fail "install-qq should skip when qq already exists"
[[ ! -e "$base/apt-reuse.log" || ! -s "$base/apt-reuse.log" ]] || fail "existing qq should not reinstall package"

# download failure should not leave temps
base="$TMP_DIR/qq-fail"
mkdir -p "$base"
if env \
  PATH="$TMP_DIR/bin:$PATH" \
  NAPCAT_BASE_DIR="$base" \
  NAPCAT_QQ_BIN="$base/usr/bin/qq" \
  NAPCAT_CLI_CONFIG_DIR="$base/config" \
  NAPCAT_CLI_STATE_DIR="$base/state" \
  FAKE_APT_LOG="$base/apt.log" \
  FAKE_QQ_PATH="$base/usr/bin/qq" \
  FAKE_QQ_CURL_MODE=fail \
  FAKE_CURL_TARGET=qq \
  bash "$ROOT_DIR/napcat.sh" install-qq >/dev/null 2>/dev/null; then
  fail "install-qq should fail when package download fails"
fi
assert_no_temp_installers "$base"
[[ ! -e "$base/usr/bin/qq" ]] || fail "failed qq install should not publish binary"

echo "ok - napcat install preserves installer on failure and installs linuxqq"
