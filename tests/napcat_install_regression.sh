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
exit 0
SCRIPT
    exit 0
    ;;
esac
exit 2
EOF
  chmod +x "$bin/curl"
}

run_install() {
  local base="$1"
  shift
  env \
    PATH="$TMP_DIR/bin:$PATH" \
    NAPCAT_BASE_DIR="$base" \
    NAPCAT_CLI_CONFIG_DIR="$base/config" \
    NAPCAT_CLI_STATE_DIR="$base/state" \
    FAKE_INSTALL_MARKER="$base/installer.marker" \
    "$@" bash "$ROOT_DIR/napcat.sh" install
}

assert_no_temp_installers() {
  local base="$1"
  if find "$base" -maxdepth 1 -name '.napcat-install.*' -print -quit | grep -q .; then
    fail "temporary installer directory leaked in $base"
  fi
}

assert_old_installer() {
  local base="$1"
  grep -qx "old installer" "$base/napcat-install.sh" || fail "old installer should be preserved"
}

mkdir -p "$TMP_DIR/bin"
write_fake_curl "$TMP_DIR/bin"

for mode in fail empty html script_fail; do
  base="$TMP_DIR/$mode"
  mkdir -p "$base"
  printf '%s\n' "old installer" > "$base/napcat-install.sh"
  if run_install "$base" env FAKE_CURL_MODE="$mode" >/dev/null 2>/dev/null; then
    fail "install should fail for curl mode $mode"
  fi
  assert_old_installer "$base"
  assert_no_temp_installers "$base"
done

base="$TMP_DIR/success"
mkdir -p "$base"
run_install "$base" env FAKE_CURL_MODE=ok >/dev/null
grep -qx "installer ran" "$base/installer.marker" || fail "valid installer should execute"
grep -q "FAKE_INSTALL_MARKER" "$base/napcat-install.sh" || fail "successful install should publish validated installer"
assert_no_temp_installers "$base"

echo "ok - napcat install preserves installer on failure"
