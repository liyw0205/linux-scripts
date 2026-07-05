#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=""

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    if [[ -f "$TMP_DIR/state/napcat.pid" ]]; then
      pid="$(cat "$TMP_DIR/state/napcat.pid" 2>/dev/null || true)"
      [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null || true
    fi
    if [[ -f "$TMP_DIR/qq.pid" ]]; then
      pid="$(cat "$TMP_DIR/qq.pid" 2>/dev/null || true)"
      [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null || true
    fi
    if [[ -f "$TMP_DIR/qq.child.pid" ]]; then
      pid="$(cat "$TMP_DIR/qq.child.pid" 2>/dev/null || true)"
      [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

wait_for_file() {
  local file="$1"
  local i

  for ((i=1; i<=80; i++)); do
    [[ -s "$file" ]] && return 0
    sleep 0.1
  done

  return 1
}

wait_for_dead() {
  local pid="$1"
  local i

  for ((i=1; i<=80; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done

  return 1
}

write_fake_bins() {
  local bin="$1"

  cat > "$bin/Xvfb" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do
  sleep 1
done
EOF
  chmod +x "$bin/Xvfb"

  cat > "$bin/qq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$$" > "${FAKE_QQ_PID_FILE:?}"
sleep 300 &
child_pid="$!"
printf '%s\n' "$child_pid" > "${FAKE_QQ_CHILD_PID_FILE:?}"

trap ':' TERM INT
while :; do
  sleep 1
done
EOF
  chmod +x "$bin/qq"
}

find_preload_library() {
  local candidate

  for candidate in \
    /data/data/com.termux/files/usr/lib/libandroid-glob.so \
    /data/data/com.termux/files/usr/lib/libtermux-exec.so \
    /lib/x86_64-linux-gnu/libc.so.6 \
    /usr/lib/x86_64-linux-gnu/libc.so.6 \
    /system/lib64/libc.so; do
    [[ -f "$candidate" ]] && {
      printf '%s\n' "$candidate"
      return 0
    }
  done

  find /data/data/com.termux/files/usr/lib /usr/lib /lib -type f -name '*.so*' 2>/dev/null | head -n 1
}

TMP_DIR="$(mktemp -d)"
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/base/napcat" "$TMP_DIR/config" "$TMP_DIR/state"
write_fake_bins "$TMP_DIR/bin"
preload_lib="$(find_preload_library)"
[[ -n "$preload_lib" ]] || fail "no shared library available for LD_PRELOAD test"

export PATH="$TMP_DIR/bin:$PATH"
export NAPCAT_BASE_DIR="$TMP_DIR/base"
export NAPCAT_DIR="$TMP_DIR/base/napcat"
export NAPCAT_LAUNCHER_SO="$preload_lib"
export NAPCAT_CLI_CONFIG_DIR="$TMP_DIR/config"
export NAPCAT_CLI_STATE_DIR="$TMP_DIR/state"
export NAPCAT_QQ_BIN="$TMP_DIR/bin/qq"
export NAPCAT_DISPLAY=":88"
export NAPCAT_SCREEN_SESSION="napcat-runtime-test"
export FAKE_QQ_PID_FILE="$TMP_DIR/qq.pid"
export FAKE_QQ_CHILD_PID_FILE="$TMP_DIR/qq.child.pid"

bash "$ROOT_DIR/napcat.sh" _run > "$TMP_DIR/run.log" 2>&1 &
runner_pid="$!"

wait_for_file "$TMP_DIR/state/napcat.pid" || fail "run_napcat did not write pid file"
wait_for_file "$TMP_DIR/qq.pid" || fail "fake QQ did not start"
wait_for_file "$TMP_DIR/qq.child.pid" || fail "fake QQ child did not start"

recorded_pid="$(cat "$TMP_DIR/state/napcat.pid")"
[[ "$recorded_pid" == "$runner_pid" ]] || fail "pid file should point to _run process"

qq_pid="$(cat "$TMP_DIR/qq.pid")"
qq_child_pid="$(cat "$TMP_DIR/qq.child.pid")"

timeout 8 bash -c '. "$1"; stop_napcat' _ "$ROOT_DIR/napcat.sh" > "$TMP_DIR/stop.log" 2>&1 || {
  cat "$TMP_DIR/stop.log" >&2 || true
  fail "stop_napcat should finish promptly when QQ ignores TERM"
}

wait_for_dead "$runner_pid" || fail "_run process should stop"
wait_for_dead "$qq_pid" || fail "fake QQ should be cleaned up"
wait_for_dead "$qq_child_pid" || fail "fake QQ child should be cleaned up"
[[ ! -e "$TMP_DIR/state/napcat.pid" ]] || fail "pid file should be removed"
[[ ! -e "$TMP_DIR/state/stopping" ]] || fail "stop file should be removed"

echo "ok - napcat runtime cleanup"
