#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=""

cleanup() {
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

write_fake_bins() {
  local bin="$1"

  cat > "$bin/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "-un") echo root ;;
  "-u") echo 0 ;;
  "-u alice") echo 1001 ;;
  "-gn alice") echo alicegrp ;;
  *) /usr/bin/id "$@" ;;
esac
EOF
  chmod +x "$bin/id"

  cat > "$bin/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "passwd" && "${2:-}" == "alice" ]]; then
  printf 'alice:x:1001:1001::%s/home/alice:/bin/bash\n' "${FAKE_MOUNT_ROOT:?}"
  exit 0
fi
exit 2
EOF
  chmod +x "$bin/getent"

cat > "$bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sudo|%s\n' "$*" >> "${FAKE_MOUNT_LOG:?}"
if [[ "${1:-}" == "-H" && "${2:-}" == "-u" ]]; then
  shift 3
fi
cmd="${1:-}"
[[ -n "$cmd" ]] || exit 0
shift || true
exec "$cmd" "$@"
EOF
  chmod +x "$bin/sudo"

  cat > "$bin/rclone" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rclone|%s\n' "$*" >> "${FAKE_MOUNT_LOG:?}"
if [[ "${1:-}" == "config" && "${2:-}" == "file" ]]; then
  if [[ "${FAKE_RCLONE_CONFIG_FILE_EMPTY:-0}" == "1" ]]; then
    exit 0
  fi
  echo "Configuration file is stored at: ${FAKE_MOUNT_ROOT:?}/home/alice/.config/rclone/rclone.conf"
  exit 0
fi
if [[ "${1:-}" == "--config" ]]; then
  conf="$2"
  shift 2
  case "${1:-}" in
    config)
      case "${2:-}" in
        delete)
          printf '%s\n' "$*" >> "${FAKE_MOUNT_ROOT:?}/rclone-delete.args"
          exit 0
          ;;
        create)
          if [[ "$conf" == "${FAKE_MOUNT_ROOT:?}/home/alice/.config/rclone/rclone.conf" ]]; then
            printf '%s\n' "$*" >> "${FAKE_MOUNT_ROOT:?}/rclone-create.args"
          else
            printf '%s\n' "$*" >> "${FAKE_MOUNT_ROOT:?}/rclone-probe-create.args"
          fi
          exit 0
          ;;
        update)
          [[ "$conf" == "${FAKE_MOUNT_ROOT:?}/home/alice/.config/rclone/rclone.conf" ]] || exit 3
          printf '%s\n' "$*" >> "${FAKE_MOUNT_ROOT:?}/rclone-update.args"
          [[ "${FAKE_RCLONE_FINAL_UPDATE_FAIL:-0}" == "1" ]] && exit 4
          exit 0
          ;;
      esac
      ;;
    listremotes)
      if [[ "${FAKE_REMOTE_MISSING:-0}" == "1" ]]; then
        exit 0
      fi
      echo "webdav_remote:"
      exit 0
      ;;
    lsd)
      if [[ "${FAKE_RCLONE_PROBE_LSD_FAIL:-0}" == "1" && "$conf" != "${FAKE_MOUNT_ROOT:?}/home/alice/.config/rclone/rclone.conf" ]]; then
        exit 5
      fi
      exit 0
      ;;
  esac
fi
if [[ "${1:-}" == "obscure" ]]; then
  echo "obscured-pass"
  exit 0
fi
if [[ "${1:-}" == "mount" ]]; then
  echo "mount should not be called in regression tests" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$bin/rclone"

  cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl|%s\n' "$*" >> "${FAKE_MOUNT_LOG:?}"
case "${1:-}" in
  daemon-reload|status|restart|stop|disable) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$bin/systemctl"

  cat > "$bin/chown" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  chmod +x "$bin/chown"

  cat > "$bin/fusermount3" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  chmod +x "$bin/fusermount3"

  cat > "$bin/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'apt-get|%s\n' "$*" >> "${FAKE_MOUNT_LOG:?}"
exit 0
EOF
  chmod +x "$bin/apt-get"
}

TMP_DIR="$(mktemp -d)"
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/alice/.config/rclone" "$TMP_DIR/systemd" "$TMP_DIR/mount" "$TMP_DIR/cache" "$TMP_DIR/dev" "$TMP_DIR/etc"
: > "$TMP_DIR/calls.log"
write_fake_bins "$TMP_DIR/bin"

export PATH="$TMP_DIR/bin:$PATH"
export FAKE_MOUNT_ROOT="$TMP_DIR"
export FAKE_MOUNT_LOG="$TMP_DIR/calls.log"
export SUDO_USER="alice"
export SERVICE_DIR="$TMP_DIR/systemd"
export SERVICE_NAME="rclone-webdav.service"
export MOUNT_DIR="$TMP_DIR/mount"
export CACHE_DIR="$TMP_DIR/cache"
export REMOTE_NAME="webdav_remote"
export RCLONE_BIN="$TMP_DIR/bin/rclone"
export FUSE_DEVICE="$TMP_DIR/dev/fuse"
export FUSE_CONF="$TMP_DIR/etc/fuse.conf"
export FUSERMOUNT_BIN="$TMP_DIR/bin/fusermount3"
export FUSERMOUNT_FALLBACK_BIN="$TMP_DIR/bin/missing-fusermount"
export TMPDIR="$TMP_DIR"
touch "$FUSE_DEVICE"

# shellcheck disable=SC1090
. "$ROOT_DIR/mount_webdav.sh"

run_root() {
  "$@"
}

if declare -f check_fuse | grep -Eq '/dev/fuse|/etc/fuse.conf'; then
  fail "check_fuse should use overrideable fuse paths"
fi

: > "$TMP_DIR/calls.log"
FUSERMOUNT_BIN="$TMP_DIR/bin/missing-fusermount" install_rclone >/dev/null
grep -qx "apt-get|install -y fuse3" "$TMP_DIR/calls.log" || fail "existing rclone with missing fusermount should install fuse3"
! grep -q "apt-get|install -y rclone" "$TMP_DIR/calls.log" || fail "existing rclone should not be reinstalled"
FUSERMOUNT_BIN="$TMP_DIR/bin/fusermount3"

: > "$TMP_DIR/calls.log"
rm -f "$FUSE_DEVICE" "$FUSE_CONF"
if (check_fuse) >/dev/null 2>/dev/null; then
  fail "check_fuse should fail when fuse device is missing"
fi
[[ ! -e "$FUSE_CONF" ]] || fail "missing fuse device should not write fuse.conf"
touch "$FUSE_DEVICE"

check_fuse >/dev/null
grep -qx "user_allow_other" "$FUSE_CONF" || fail "check_fuse should add user_allow_other"
check_fuse >/dev/null
[[ "$(grep -c '^user_allow_other$' "$FUSE_CONF")" -eq 1 ]] || fail "check_fuse should not duplicate user_allow_other"
printf '%s\n' "# user_allow_other" > "$FUSE_CONF"
check_fuse >/dev/null
grep -qx "user_allow_other" "$FUSE_CONF" || fail "commented user_allow_other should not count as enabled"
FUSE_CONF="$TMP_DIR/etc/fuse conf"
rm -f "$FUSE_CONF"
check_fuse >/dev/null
grep -qx "user_allow_other" "$FUSE_CONF" || fail "check_fuse should support spaces in fuse conf path"
! grep -Eq "rclone\\||systemctl\\|" "$TMP_DIR/calls.log" || fail "check_fuse should not call rclone or systemctl"

conf_path="$(detect_rclone_conf_path alice)"
[[ "$conf_path" == "$TMP_DIR/home/alice/.config/rclone/rclone.conf" ]] || fail "rclone config path should use sudo user"

export FAKE_RCLONE_CONFIG_FILE_EMPTY=1
conf_path="$(detect_rclone_conf_path alice)"
[[ "$conf_path" == "$TMP_DIR/home/alice/.config/rclone/rclone.conf" ]] || fail "fallback config path should use sudo user's home"
unset FAKE_RCLONE_CONFIG_FILE_EMPTY

printf '%s\n%s\n%s\n%s\n' \
  "http://127.0.0.1:5244/dav" \
  "" \
  "alice" \
  "secret" | config_remote >/dev/null

grep -q "rclone|--config $TMP_DIR/mount-webdav-rclone\\.[^ ]* config create webdav_remote_probe_" "$TMP_DIR/calls.log" || fail "config_remote should probe with temporary config"
grep -q "rclone|--config $TMP_DIR/home/alice/.config/rclone/rclone.conf config update webdav_remote" "$TMP_DIR/calls.log" || fail "config_remote should update existing remote with sudo user's config"
grep -q "vendor=other" "$TMP_DIR/rclone-update.args" || fail "default vendor should be other"
grep -q "pass=obscured-pass" "$TMP_DIR/rclone-update.args" || fail "password should be obscured"
! grep -q "config delete webdav_remote" "$TMP_DIR/calls.log" || fail "config_remote should not delete existing remote"
if find "$TMP_DIR" -maxdepth 1 -name 'mount-webdav-rclone.*' -print -quit | grep -q .; then
  fail "config_remote should remove probe config"
fi
! grep -q "rclone|mount" "$TMP_DIR/calls.log" || fail "config_remote should not mount"
! grep -q "systemctl|" "$TMP_DIR/calls.log" || fail "config_remote should not call systemctl"

: > "$TMP_DIR/calls.log"
rm -f "$TMP_DIR/rclone-create.args"
printf '%s\n%s\n%s\n%s\n' \
  "http://127.0.0.1:5244/dav" \
  "" \
  "alice" \
  "secret" | FAKE_REMOTE_MISSING=1 config_remote >/dev/null
grep -q "rclone|--config $TMP_DIR/home/alice/.config/rclone/rclone.conf config create webdav_remote webdav" "$TMP_DIR/calls.log" || fail "missing remote should be created after probe"
grep -q "vendor=other" "$TMP_DIR/rclone-create.args" || fail "created remote should keep default vendor"

: > "$TMP_DIR/calls.log"
config_output=""
if config_output="$(printf '%s\n%s\n%s\n%s\n' \
  "http://127.0.0.1:5244/dav" \
  "" \
  "alice" \
  "secret" | FAKE_RCLONE_PROBE_LSD_FAIL=1 config_remote 2>&1)"; then
  fail "config_remote should fail when probe lsd fails"
fi
printf '%s\n' "$config_output" | grep -q "真实 remote 未修改" || fail "probe failure should report real remote unchanged"
! grep -q "config update webdav_remote" "$TMP_DIR/calls.log" || fail "probe failure should not update real remote"
! grep -q "config create webdav_remote webdav" "$TMP_DIR/calls.log" || fail "probe failure should not create real remote"
! grep -q "config delete webdav_remote" "$TMP_DIR/calls.log" || fail "probe failure should not delete real remote"
if find "$TMP_DIR" -maxdepth 1 -name 'mount-webdav-rclone.*' -print -quit | grep -q .; then
  fail "probe failure should remove probe config"
fi

: > "$TMP_DIR/calls.log"
config_output=""
if config_output="$(printf '%s\n%s\n%s\n%s\n' \
  "http://127.0.0.1:5244/dav" \
  "" \
  "alice" \
  "secret" | FAKE_RCLONE_FINAL_UPDATE_FAIL=1 config_remote 2>&1)"; then
  fail "config_remote should fail when final update fails"
fi
printf '%s\n' "$config_output" | grep -q "未主动删除旧 remote" || fail "final update failure should report old remote was not deleted"
grep -q "config update webdav_remote" "$TMP_DIR/calls.log" || fail "final update failure should attempt update"
! grep -q "config delete webdav_remote" "$TMP_DIR/calls.log" || fail "final update failure should not delete old remote"
if find "$TMP_DIR" -maxdepth 1 -name 'mount-webdav-rclone.*' -print -quit | grep -q .; then
  fail "final update failure should remove probe config"
fi

: > "$TMP_DIR/calls.log"
write_service >/dev/null
service_file="$TMP_DIR/systemd/rclone-webdav.service"
[[ -s "$service_file" ]] || fail "service file should be written"
grep -qx "User=alice" "$service_file" || fail "service user mismatch"
grep -qx "Group=alicegrp" "$service_file" || fail "service group mismatch"
grep -qx "Environment=HOME=$TMP_DIR/home/alice" "$service_file" || fail "service home mismatch"
grep -q "ExecStart=$TMP_DIR/bin/rclone mount webdav_remote:/ $TMP_DIR/mount" "$service_file" || fail "service ExecStart mismatch"
grep -q -- "--config=$TMP_DIR/home/alice/.config/rclone/rclone.conf" "$service_file" || fail "service config path mismatch"
grep -q -- "--cache-dir=$TMP_DIR/cache" "$service_file" || fail "service cache path mismatch"
grep -q "ExecStop=$TMP_DIR/bin/fusermount3 -uz $TMP_DIR/mount" "$service_file" || fail "service ExecStop mismatch"
grep -qx "systemctl|daemon-reload" "$TMP_DIR/calls.log" || fail "write_service should daemon-reload"
! grep -q "systemctl|enable" "$TMP_DIR/calls.log" || fail "write_service should not enable service"
! grep -q "systemctl|restart" "$TMP_DIR/calls.log" || fail "write_service should not restart service"

rm -f "$service_file"
: > "$TMP_DIR/calls.log"
if (FAKE_REMOTE_MISSING=1 write_service) >/dev/null 2>/dev/null; then
  fail "write_service should fail when remote is missing"
fi
[[ ! -e "$service_file" ]] || fail "missing remote should not write service"
! grep -q "systemctl|daemon-reload" "$TMP_DIR/calls.log" || fail "missing remote should not daemon-reload"

echo "ok - mount_webdav user context and service generation"
