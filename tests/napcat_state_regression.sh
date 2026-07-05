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

export NAPCAT_BASE_DIR="$TMP_DIR/base"
export NAPCAT_CLI_CONFIG_DIR="$TMP_DIR/config"
export NAPCAT_CLI_STATE_DIR="$TMP_DIR/state"
export NAPCAT_QQ_BIN="$TMP_DIR/bin/qq"

mkdir -p "$TMP_DIR/bin"

. "$ROOT_DIR/napcat.sh"

[[ "$BASE_DIR" == "$TMP_DIR/base" ]] || fail "NAPCAT_BASE_DIR override not applied"
[[ "$CONFIG_DIR" == "$TMP_DIR/config" ]] || fail "config dir override not applied"
[[ "$STATE_DIR" == "$TMP_DIR/state" ]] || fail "state dir override not applied"

set_qq 123456789 >/dev/null
[[ "$(read_qq)" == "123456789" ]] || fail "valid qq not read"

printf '%s\n' "123abc" > "$QQ_FILE"
if read_qq >/dev/null 2>&1; then
  fail "invalid qq should be rejected"
fi

clear_qq >/dev/null
[[ ! -e "$QQ_FILE" ]] || fail "qq file should be removed"

ensure_dirs
printf '%s\n' "223344" > "$PID_FILE"
[[ "$(pid_from_file)" == "223344" ]] || fail "valid pid not read"

printf '%s\n' "22 3344" > "$PID_FILE"
if pid_from_file >/dev/null 2>&1; then
  fail "invalid pid should be rejected"
fi

log_file="$TMP_DIR/napcat.log"
printf '%s\n' "old log line" > "$log_file"
rotate_log_if_needed "$log_file" 0
grep -q "Log rotated:" "$log_file" || fail "log rotation marker missing"
! grep -q "old log line" "$log_file" || fail "log was not truncated"

echo "ok - napcat state helpers and source guard"
