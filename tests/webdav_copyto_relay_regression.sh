#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/webdav_copyto_relay.sh"
FIXTURE_BIN="$ROOT_DIR/tests/fixtures/bin"
CURRENT_TMP=""

trap 'cleanup_tmp "$CURRENT_TMP"' EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

wait_for_file() {
  local file="$1"
  local tries="${2:-50}"
  for ((i = 0; i < tries; i++)); do
    [[ -s "$file" ]] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_stat() {
  local stats_file="$1"
  local expected="$2"
  local tries="${3:-50}"
  for ((i = 0; i < tries; i++)); do
    grep -qx "$expected" "$stats_file" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

wait_for_absent() {
  local file="$1"
  local tries="${2:-50}"
  for ((i = 0; i < tries; i++)); do
    [[ ! -e "$file" ]] && return 0
    sleep 0.1
  done
  return 1
}

wait_pid_gone() {
  local pid="$1"
  local tries="${2:-50}"
  for ((i = 0; i < tries; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

write_config() {
  local tmp="$1"
  local url="${2:-http://127.0.0.1:5241/dav}"
  local user="${3:-user}"
  local pass="${4:-pass}"
  local src="${5:-src}"
  local dst="${6:-dst}"
  cat > "$tmp/relay.conf" <<EOF
WEBDAV_URL='$url'
WEBDAV_USER='$user'
WEBDAV_PASS='$pass'
REMOTE_NAME='fake'
SRC_PATH='$src'
DST_PATH='$dst'
TMP_DIR='$tmp/tmpdir'
MIN_FREE_PERCENT='0'
EOF
}

cleanup_tmp() {
  local tmp="${1:-}"
  [[ -n "$tmp" && -d "$tmp" ]] || return 0
  if [[ -f "$tmp/copyto.pids" ]]; then
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      kill "$pid" 2>/dev/null || true
      wait_pid_gone "$pid" 10 || kill -9 "$pid" 2>/dev/null || true
    done < "$tmp/copyto.pids"
  fi
  rm -rf "$tmp"
}

run_relay() {
  local tmp="$1"
  shift
  FAKE_RCLONE_ROOT="$tmp" \
  FAKE_RCLONE_MODE="${FAKE_RCLONE_MODE:-skip}" \
  PATH="$FIXTURE_BIN:$PATH" \
  CONFIG_FILE="$tmp/relay.conf" \
  STATE_DIR="$tmp/state" \
  bash "$SCRIPT" "$@"
}

test_skip() {
  local tmp
  tmp="$(mktemp -d)"
  CURRENT_TMP="$tmp"
  mkdir -p "$tmp/state" "$tmp/tmpdir"
  write_config "$tmp"

  FAKE_RCLONE_MODE=skip run_relay "$tmp" start >/dev/null

  wait_for_stat "$tmp/state/stats.env" "TASK_STATUS=finished" || fail "skip task did not finish"
  grep -qx "SKIP=1" "$tmp/state/stats.env" || fail "skip count mismatch"
  grep -qx "SUCCESS=0" "$tmp/state/stats.env" || fail "success count mismatch"
  grep -qx "FAIL=0" "$tmp/state/stats.env" || fail "fail count mismatch"
  [[ ! -e "$tmp/copyto.started" ]] || fail "copyto should not run for same-size remote file"
  ! grep -Eq '^config (delete|create)|^obscure' "$tmp/rclone.calls" || fail "start should not rewrite rclone config"
  grep -qx "lsd fake:" "$tmp/rclone.calls" || fail "start should check remote availability"
  wait_for_absent "$tmp/state/task.pid" || fail "finished task pid should be cleaned"
  cleanup_tmp "$tmp"
  CURRENT_TMP=""
  echo "ok - webdav skip same-size remote"
}

test_start_remote_fail_no_config_write() {
  local tmp
  tmp="$(mktemp -d)"
  CURRENT_TMP="$tmp"
  mkdir -p "$tmp/state" "$tmp/tmpdir"
  write_config "$tmp"

  if FAKE_RCLONE_MODE=remote_fail run_relay "$tmp" start >/dev/null 2>/dev/null; then
    fail "start should fail when remote is unavailable"
  fi

  [[ -s "$tmp/rclone.calls" ]] || fail "remote failure should still record rclone call"
  grep -qx "lsd fake:" "$tmp/rclone.calls" || fail "start should perform read-only remote check"
  ! grep -Eq '^config (delete|create)|^obscure' "$tmp/rclone.calls" || fail "remote failure should not rewrite rclone config"
  [[ ! -e "$tmp/state/task.pid" ]] || fail "failed start should not leave task pid"

  cleanup_tmp "$tmp"
  CURRENT_TMP=""
  echo "ok - webdav start remote failure is read-only"
}

test_reconfig_probe_fail_preserves_config() {
  local tmp before
  tmp="$(mktemp -d)"
  CURRENT_TMP="$tmp"
  mkdir -p "$tmp/state" "$tmp/tmpdir"
  write_config "$tmp"
  before="$(cat "$tmp/relay.conf")"

  if printf '%s\n' \
    "http://127.0.0.1:9999/dav" \
    "bad-user" \
    "bad-pass" \
    "fake" \
    "bad-src" \
    "bad-dst" \
    "$tmp/tmpdir" \
    "0" | FAKE_RCLONE_MODE=config_probe_fail run_relay "$tmp" reconfig >/dev/null 2>/dev/null; then
    fail "reconfig should fail when probe remote is unavailable"
  fi

  [[ "$(cat "$tmp/relay.conf")" == "$before" ]] || fail "failed reconfig should restore previous config"
  ! grep -Eq '^config (delete|create) fake( |$)|^config update fake( |$)' "$tmp/rclone.calls" || fail "probe failure should not touch real remote"
  grep -q '^--config .* config create fake_probe_' "$tmp/rclone.calls" || fail "reconfig should probe with temporary rclone config"

  cleanup_tmp "$tmp"
  CURRENT_TMP=""
  echo "ok - webdav reconfig probe failure preserves config"
}

test_reconfig_path_fail_preserves_remote() {
  local tmp before
  tmp="$(mktemp -d)"
  CURRENT_TMP="$tmp"
  mkdir -p "$tmp/state" "$tmp/tmpdir"
  write_config "$tmp"
  before="$(cat "$tmp/relay.conf")"

  if printf '%s\n' \
    "http://127.0.0.1:9999/dav" \
    "new-user" \
    "new-pass" \
    "fake" \
    "missing-src" \
    "missing-dst" \
    "$tmp/tmpdir" \
    "0" | FAKE_RCLONE_MODE=config_path_fail run_relay "$tmp" reconfig >/dev/null 2>/dev/null; then
    fail "reconfig should fail when probe path check fails"
  fi

  [[ "$(cat "$tmp/relay.conf")" == "$before" ]] || fail "path check failure should restore previous config"
  grep -q '^--config .* config create fake_probe_' "$tmp/rclone.calls" || fail "reconfig should create probe remote"
  grep -q '^--config .* lsf fake_probe_.*:missing-src' "$tmp/rclone.calls" || fail "reconfig should check paths through probe remote"
  ! grep -Eq '^config (delete|create) fake( |$)|^config update fake( |$)' "$tmp/rclone.calls" || fail "probe path failure should not touch real remote"

  cleanup_tmp "$tmp"
  CURRENT_TMP=""
  echo "ok - webdav reconfig path failure preserves real remote"
}

test_reconfig_success_updates_config() {
  local tmp
  tmp="$(mktemp -d)"
  CURRENT_TMP="$tmp"
  mkdir -p "$tmp/state" "$tmp/tmpdir"
  write_config "$tmp"

  printf '%s\n' \
    "http://127.0.0.1:9999/dav" \
    "new-user" \
    "new-pass" \
    "fake" \
    "new-src" \
    "new-dst" \
    "$tmp/tmpdir" \
    "0" | FAKE_RCLONE_MODE=skip run_relay "$tmp" reconfig >/dev/null

  grep -qx "WEBDAV_URL=http://127.0.0.1:9999/dav" "$tmp/relay.conf" || fail "reconfig should save new URL"
  grep -qx "WEBDAV_USER=new-user" "$tmp/relay.conf" || fail "reconfig should save new user"
  grep -qx "SRC_PATH=new-src" "$tmp/relay.conf" || fail "reconfig should save new source path"
  grep -q '^config update fake ' "$tmp/rclone.config-writes" || fail "existing remote should be updated"
  ! grep -q '^config delete fake' "$tmp/rclone.config-writes" || fail "reconfig should not delete real remote"

  cleanup_tmp "$tmp"
  CURRENT_TMP=""
  echo "ok - webdav reconfig success updates config after probe"
}

test_reconfig_update_fail_restores_config() {
  local tmp before
  tmp="$(mktemp -d)"
  CURRENT_TMP="$tmp"
  mkdir -p "$tmp/state" "$tmp/tmpdir"
  write_config "$tmp"
  before="$(cat "$tmp/relay.conf")"

  if printf '%s\n' \
    "http://127.0.0.1:9999/dav" \
    "new-user" \
    "new-pass" \
    "fake" \
    "new-src" \
    "new-dst" \
    "$tmp/tmpdir" \
    "0" | FAKE_RCLONE_MODE=config_update_fail run_relay "$tmp" reconfig >/dev/null 2>/dev/null; then
    fail "reconfig should fail when final remote update fails"
  fi

  [[ "$(cat "$tmp/relay.conf")" == "$before" ]] || fail "failed final update should restore previous config"
  grep -q '^config update fake ' "$tmp/rclone.config-writes" || fail "final update failure scenario should try update"
  ! grep -q '^config delete fake' "$tmp/rclone.config-writes" || fail "final update failure should not delete real remote"

  cleanup_tmp "$tmp"
  CURRENT_TMP=""
  echo "ok - webdav reconfig update failure restores config"
}

test_stop() {
  local tmp
  tmp="$(mktemp -d)"
  CURRENT_TMP="$tmp"
  mkdir -p "$tmp/state" "$tmp/tmpdir"
  write_config "$tmp"

  FAKE_RCLONE_MODE=stop run_relay "$tmp" start >/dev/null
  wait_for_file "$tmp/state/rclone.pid" || fail "rclone pid was not recorded"
  wait_for_file "$tmp/copyto.pids" || fail "copyto did not start"

  FAKE_RCLONE_MODE=stop run_relay "$tmp" stop >/dev/null

  [[ ! -e "$tmp/state/task.pid" ]] || fail "task pid should be cleaned after stop"
  [[ ! -e "$tmp/state/rclone.pid" ]] || fail "rclone pid should be cleaned after stop"
  grep -qx "TASK_STATUS=stopped" "$tmp/state/stats.env" || fail "task status should be stopped"

  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    wait_pid_gone "$pid" || fail "copyto pid still alive: $pid"
  done < "$tmp/copyto.pids"
  cleanup_tmp "$tmp"
  CURRENT_TMP=""
  echo "ok - webdav stop kills active copyto"
}

case "${1:-all}" in
  skip) test_skip ;;
  remote-fail) test_start_remote_fail_no_config_write ;;
  reconfig-fail) test_reconfig_probe_fail_preserves_config ;;
  reconfig-path-fail) test_reconfig_path_fail_preserves_remote ;;
  reconfig-success) test_reconfig_success_updates_config ;;
  reconfig-update-fail) test_reconfig_update_fail_restores_config ;;
  stop) test_stop ;;
  all)
    test_skip
    test_start_remote_fail_no_config_write
    test_reconfig_probe_fail_preserves_config
    test_reconfig_path_fail_preserves_remote
    test_reconfig_success_updates_config
    test_reconfig_update_fail_restores_config
    test_stop
    ;;
  *)
    fail "usage: $0 [skip|remote-fail|reconfig-fail|reconfig-path-fail|reconfig-success|reconfig-update-fail|stop|all]"
    ;;
esac
