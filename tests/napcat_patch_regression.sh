#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REAL_CHMOD="$(command -v chmod)"

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

  cat > "$bin/arch" <<'EOF'
#!/usr/bin/env sh
echo amd64
EOF
  "$REAL_CHMOD" +x "$bin/arch"

  cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == "-w" ]]; then
    printf '000'
    exit 0
  fi
done
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
    printf 'partial cpp' > "$out"
    exit 23
    ;;
  ok)
    printf 'int main(void) { return 0; }\n' > "$out"
    exit 0
    ;;
esac
EOF
  "$REAL_CHMOD" +x "$bin/curl"

  cat > "$bin/g++" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'g++|%s\n' "$*" >> "${FAKE_NAPCAT_LOG:?}"
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
case "${FAKE_GPP_MODE:-ok}" in
  fail)
    printf 'partial so' > "$out"
    exit 1
    ;;
  ok)
    printf 'new so' > "$out"
    exit 0
    ;;
esac
EOF
  "$REAL_CHMOD" +x "$bin/g++"

  cat > "$bin/chmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_CHMOD_FAIL:-0}" == "1" ]]; then
  exit 1
fi
exec "${REAL_CHMOD:?}" "$@"
EOF
  "$REAL_CHMOD" +x "$bin/chmod"
}

reset_artifacts() {
  rm -rf "$BASE_DIR"
  mkdir -p "$BASE_DIR"
  printf '%s\n' "old cpp" > "$BASE_DIR/launcher.cpp"
  printf '%s\n' "old so" > "$LAUNCHER_SO"
  "$REAL_CHMOD" 755 "$LAUNCHER_SO"
  : > "$FAKE_NAPCAT_LOG"
}

assert_old_artifacts() {
  grep -qx "old cpp" "$BASE_DIR/launcher.cpp" || fail "launcher.cpp should be preserved"
  grep -qx "old so" "$LAUNCHER_SO" || fail "launcher so should be preserved"
  if find "$BASE_DIR" -maxdepth 1 -name '.napcat-patch.*' -print -quit | grep -q .; then
    fail "temporary patch directory leaked"
  fi
  if find "$BASE_DIR" -maxdepth 1 -name '.libnapcat_launcher.so.*' -print -quit | grep -q .; then
    fail "temporary launcher so leaked"
  fi
}

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/base"
write_fake_bins "$TMP_DIR/bin"
export PATH="$TMP_DIR/bin:$PATH"
export REAL_CHMOD
export FAKE_NAPCAT_LOG="$TMP_DIR/napcat.log"
export NAPCAT_BASE_DIR="$TMP_DIR/base"
export NAPCAT_LAUNCHER_SO="$TMP_DIR/base/libnapcat_launcher.so"
export NAPCAT_CLI_CONFIG_DIR="$TMP_DIR/config"
export NAPCAT_CLI_STATE_DIR="$TMP_DIR/state"

# shellcheck disable=SC1090
. "$ROOT_DIR/napcat.sh"

reset_artifacts
if FAKE_CURL_MODE=fail patch_napcat >/dev/null 2>/dev/null; then
  fail "curl failure should fail patch"
fi
assert_old_artifacts
[[ ! -s "$FAKE_NAPCAT_LOG" ]] || fail "g++ should not run after curl failure"

reset_artifacts
if FAKE_CURL_MODE=ok FAKE_GPP_MODE=fail patch_napcat >/dev/null 2>/dev/null; then
  fail "g++ failure should fail patch"
fi
assert_old_artifacts
grep -q '^g++|' "$FAKE_NAPCAT_LOG" || fail "g++ failure scenario should call fake g++"

reset_artifacts
if FAKE_CURL_MODE=ok FAKE_GPP_MODE=ok FAKE_CHMOD_FAIL=1 patch_napcat >/dev/null 2>/dev/null; then
  fail "chmod failure should fail patch"
fi
assert_old_artifacts

echo "ok - napcat patch preserves existing artifacts on failure"
