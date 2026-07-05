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

export ASTR_APP_DIR="$TMP_DIR/app"
export ASTR_VENV_DIR="$TMP_DIR/venv"
export ASTR_LOG_MAX_SIZE_MB=50

. "$ROOT_DIR/astr.sh"

[[ "$APP_DIR" == "$TMP_DIR/app" ]] || fail "ASTR_APP_DIR override not applied"
[[ "$VENV_DIR" == "$TMP_DIR/venv" ]] || fail "ASTR_VENV_DIR override not applied"
[[ "$APP_PID_FILE" == "$TMP_DIR/app/astr.pid" ]] || fail "derived app pid path mismatch"
[[ "$PYTHON" == "$TMP_DIR/venv/bin/python" ]] || fail "derived python path mismatch"

mkdir -p "$APP_DIR" "$VENV_DIR/bin"

printf '%s\n' "12345" > "$APP_PID_FILE"
[[ "$(read_app_pid)" == "12345" ]] || fail "valid app pid not read"

printf '%s\n' "123abc" > "$APP_PID_FILE"
if read_app_pid >/dev/null 2>&1; then
    fail "invalid app pid should be rejected"
fi

printf '%s\n' "22334" > "$SUPERVISOR_PID_FILE"
[[ "$(read_supervisor_pid)" == "22334" ]] || fail "valid supervisor pid not read"

printf '%s\n' "22 334" > "$SUPERVISOR_PID_FILE"
if read_supervisor_pid >/dev/null 2>&1; then
    fail "invalid supervisor pid should be rejected"
fi

log_file="$TMP_DIR/astr.log"
printf '%s\n' "old log line" > "$log_file"
rotate_log_if_needed "$log_file" 0
grep -q "Log rotated:" "$log_file" || fail "log rotation marker missing"
! grep -q "old log line" "$log_file" || fail "log was not truncated"

echo "ok - astr state helpers and source guard"
