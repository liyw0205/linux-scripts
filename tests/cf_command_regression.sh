#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=""
TUNNEL_ID="11111111-1111-1111-1111-111111111111"

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
  cat > "$bin/sudo" <<'EOF'
#!/usr/bin/env sh
exec "$@"
EOF
  chmod +x "$bin/sudo"

  cat > "$bin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_RM_FAIL_SERVICE_NAME:-}" ]]; then
  for arg in "$@"; do
    if [[ "$arg" == "${SERVICE_DIR:?}/cf-tunnel-${FAKE_RM_FAIL_SERVICE_NAME}.service" ]]; then
      exit 1
    fi
  done
fi
exec "${REAL_RM:?}" "$@"
EOF
  chmod +x "$bin/rm"

  cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_SYSTEMCTL_LOG:?}"
case "${1:-}" in
  list-unit-files) exit 0 ;;
  is-enabled)
    [[ "${FAKE_SYSTEMCTL_ENABLED:-0}" == "1" ]] && exit 0
    exit 1
    ;;
  is-active) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$bin/systemctl"

  cat > "$bin/mktemp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
template="${1:-}"
if [[ -n "${FAKE_SERVICE_MKTEMP_FAIL_NAME:-}" && "$template" == "${SERVICE_DIR:?}/.${FAKE_SERVICE_MKTEMP_FAIL_NAME}.service."* ]]; then
  exit 1
fi
if [[ "${FAKE_SERVICE_MKTEMP_FAIL:-0}" == "1" && "$template" == "${SERVICE_DIR:?}/."*".service."* ]]; then
  exit 1
fi
exec "${REAL_MKTEMP:?}" "$@"
EOF
  chmod +x "$bin/mktemp"

  cat > "$bin/cloudflared" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CLOUDFLARED_LOG:?}"
case "${1:-}" in
  --version)
    echo "cloudflared version fake"
    ;;
  tunnel)
    case "${2:-}" in
      list)
        if [[ -n "${FAKE_CLOUDFLARED_LIST:-}" ]]; then
          printf '%s\n' "$FAKE_CLOUDFLARED_LIST"
        else
          printf '%s\n' "ID NAME"
          printf '%s %s\n' "${FAKE_TUNNEL_ID:?}" "demo"
          if [[ -n "${FAKE_CLOUDFLARED_CREATE_NAME:-}" && -f "${FAKE_CLOUDFLARED_CREATE_MARKER:?}" ]]; then
            printf '%s %s\n' "${FAKE_CLOUDFLARED_CREATE_ID:?}" "$FAKE_CLOUDFLARED_CREATE_NAME"
          fi
        fi
        ;;
      create)
        if [[ -n "${FAKE_CLOUDFLARED_CREATE_NAME:-}" && "${3:-}" == "$FAKE_CLOUDFLARED_CREATE_NAME" ]]; then
          : > "${FAKE_CLOUDFLARED_CREATE_MARKER:?}"
        fi
        exit 0
        ;;
      delete)
        if [[ "${FAKE_CLOUDFLARED_DELETE_FAIL:-0}" == "1" ]]; then
          echo "delete failed" >&2
          exit 1
        fi
        echo "deleted ${3:-}"
        ;;
      info)
        echo "info ${3:-}"
        ;;
      rename)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$bin/cloudflared"
}

run_cf() {
  env \
    PATH="$TMP_DIR/bin:$PATH" \
    CLOUDFLARED_BIN="$TMP_DIR/bin/cloudflared" \
    CLOUDFLARED_HOME="$TMP_DIR/home" \
    SERVICE_DIR="$TMP_DIR/systemd" \
    TMPDIR="$TMP_DIR" \
    REAL_MKTEMP="$(command -v mktemp)" \
    REAL_RM="$(command -v rm)" \
    FAKE_TUNNEL_ID="$TUNNEL_ID" \
    FAKE_CLOUDFLARED_CREATE_ID="44444444-4444-4444-4444-444444444444" \
    FAKE_CLOUDFLARED_CREATE_MARKER="$TMP_DIR/cloudflared-created.marker" \
    FAKE_CLOUDFLARED_LOG="$TMP_DIR/cloudflared.log" \
    FAKE_SYSTEMCTL_LOG="$TMP_DIR/systemctl.log" \
    "$@"
}

write_standard_config() {
  local url="${1:-http://127.0.0.1:8080}"
  local cred="$TMP_DIR/home/${TUNNEL_ID}.json"
  printf '%s\n' \
    "url: '$url'" \
    "tunnel: '$TUNNEL_ID'" \
    "credentials-file: '$cred'" > "$TMP_DIR/home/demo.yml"
  printf '%s\n' '{}' > "$cred"
  printf '%s\n' '[Service]' > "$TMP_DIR/systemd/cf-tunnel-demo.service"
}

assert_no_real_paths_used() {
  ! grep -q '/etc/systemd/system' "$TMP_DIR/systemctl.log" 2>/dev/null || fail "real systemd path leaked into test"
}

TMP_DIR="$(mktemp -d)"
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home" "$TMP_DIR/systemd"
: > "$TMP_DIR/cloudflared.log"
: > "$TMP_DIR/systemctl.log"
printf '%s\n' cert > "$TMP_DIR/home/cert.pem"
write_fake_bins "$TMP_DIR/bin"

write_standard_config "http://127.0.0.1:8000"
run_cf bash "$ROOT_DIR/cf.sh" set-url demo "http://127.0.0.1:8080/path?a=1&b='#x'" >/dev/null
grep -qx "url: 'http://127.0.0.1:8080/path?a=1&b=''#x'''" "$TMP_DIR/home/demo.yml" || fail "set-url did not quote url safely"
grep -qx "tunnel: '$TUNNEL_ID'" "$TMP_DIR/home/demo.yml" || fail "set-url lost tunnel id"
grep -qx "credentials-file: '$TMP_DIR/home/${TUNNEL_ID}.json'" "$TMP_DIR/home/demo.yml" || fail "set-url lost credentials"
[[ ! -s "$TMP_DIR/cloudflared.log" ]] || fail "set-url should not call cloudflared"
[[ ! -s "$TMP_DIR/systemctl.log" ]] || fail "set-url should not call systemctl"

cat > "$TMP_DIR/home/demo.yml" <<EOF
tunnel: '$TUNNEL_ID'
credentials-file: '$TMP_DIR/home/${TUNNEL_ID}.json'
ingress:
  - service: http://127.0.0.1:9090
EOF
run_cf bash "$ROOT_DIR/cf.sh" repair demo >/dev/null
grep -qx "url: 'http://127.0.0.1:9090'" "$TMP_DIR/home/demo.yml" || fail "repair did not recover service url"
grep -qx "tunnel: '$TUNNEL_ID'" "$TMP_DIR/home/demo.yml" || fail "repair lost tunnel id"
[[ ! -s "$TMP_DIR/cloudflared.log" ]] || fail "repair should not call cloudflared"
[[ ! -s "$TMP_DIR/systemctl.log" ]] || fail "repair should not call systemctl"

write_standard_config "http://127.0.0.1:7000"
if run_cf env FAKE_CLOUDFLARED_DELETE_FAIL=1 bash "$ROOT_DIR/cf.sh" delete demo >/dev/null 2>/dev/null; then
  fail "delete should fail when fake cloudflared delete fails"
fi
[[ -f "$TMP_DIR/home/demo.yml" ]] || fail "delete failure should preserve yml"
[[ -f "$TMP_DIR/systemd/cf-tunnel-demo.service" ]] || fail "delete failure should preserve service"
[[ -f "$TMP_DIR/home/${TUNNEL_ID}.json" ]] || fail "delete failure should preserve credentials"
grep -q "tunnel delete $TUNNEL_ID" "$TMP_DIR/cloudflared.log" || fail "delete did not call fake cloudflared"

write_standard_config "http://127.0.0.1:7000"
run_cf bash "$ROOT_DIR/cf.sh" delete demo >/dev/null
[[ ! -e "$TMP_DIR/home/demo.yml" ]] || fail "delete success should remove yml"
[[ ! -e "$TMP_DIR/systemd/cf-tunnel-demo.service" ]] || fail "delete success should remove service"
[[ ! -e "$TMP_DIR/home/${TUNNEL_ID}.json" ]] || fail "delete success should remove credentials"
grep -q '^daemon-reload$' "$TMP_DIR/systemctl.log" || fail "delete success should daemon-reload"
assert_no_real_paths_used

write_standard_config "http://127.0.0.1:7000"
delete_output=""
if delete_output="$(run_cf env FAKE_RM_FAIL_SERVICE_NAME=demo bash "$ROOT_DIR/cf.sh" delete demo 2>&1)"; then
  fail "delete should fail when remote delete succeeds but local service cleanup fails"
fi
printf '%s\n' "$delete_output" | grep -q "远端已删除，但本地 service 删除失败: $TMP_DIR/systemd/cf-tunnel-demo.service" || fail "delete cleanup failure should report service cleanup failure"
printf '%s\n' "$delete_output" | grep -q "恢复建议: 手动删除残留文件后执行 systemctl daemon-reload" || fail "delete cleanup failure should suggest manual recovery"
printf '%s\n' "$delete_output" | grep -q "远端已删除，本地清理不完整" || fail "delete cleanup failure should report incomplete local cleanup"
[[ -f "$TMP_DIR/systemd/cf-tunnel-demo.service" ]] || fail "failed service cleanup should leave service for manual recovery"
[[ ! -e "$TMP_DIR/home/demo.yml" ]] || fail "delete cleanup failure should still remove yml when possible"
[[ ! -e "$TMP_DIR/home/${TUNNEL_ID}.json" ]] || fail "delete cleanup failure should still remove credentials when possible"
grep -q "tunnel delete $TUNNEL_ID" "$TMP_DIR/cloudflared.log" || fail "delete cleanup failure should have deleted remote first"

write_standard_config "http://127.0.0.1:7100"
rename_output=""
if rename_output="$(run_cf env FAKE_SERVICE_MKTEMP_FAIL=1 FAKE_SYSTEMCTL_ENABLED=1 bash "$ROOT_DIR/cf.sh" rename demo renamed 2>&1)"; then
  fail "rename should fail when local service write fails"
fi
printf '%s\n' "$rename_output" | grep -q "远端已重命名成功: demo -> renamed" || fail "rename failure should report remote success"
printf '%s\n' "$rename_output" | grep -q "本地旧配置仍保留: $TMP_DIR/home/demo.yml" || fail "rename failure should report old local config"
printf '%s\n' "$rename_output" | grep -q "恢复建议: 修复本地写入/权限问题后执行 cf sync" || fail "rename failure should suggest sync"
printf '%s\n' "$rename_output" | grep -q "cf set-url renamed http://127.0.0.1:7100" || fail "rename failure should suggest restoring url"
printf '%s\n' "$rename_output" | grep -q "cf enable renamed" || fail "rename failure should suggest enabling renamed service"
[[ -f "$TMP_DIR/home/demo.yml" ]] || fail "rename local failure should preserve old yml"
[[ ! -e "$TMP_DIR/home/renamed.yml" ]] || fail "rename local failure should roll back new yml"
[[ -f "$TMP_DIR/systemd/cf-tunnel-demo.service" ]] || fail "rename local failure should preserve old service"
[[ ! -e "$TMP_DIR/systemd/cf-tunnel-renamed.service" ]] || fail "rename local failure should not leave new service"
grep -q "tunnel rename $TUNNEL_ID renamed" "$TMP_DIR/cloudflared.log" || fail "rename did not call fake cloudflared"

rm -f "$TMP_DIR/cloudflared-created.marker" "$TMP_DIR/home/fresh.yml" "$TMP_DIR/systemd/cf-tunnel-fresh.service"
create_output=""
if create_output="$(run_cf env FAKE_CLOUDFLARED_CREATE_NAME=fresh FAKE_SERVICE_MKTEMP_FAIL_NAME=fresh bash "$ROOT_DIR/cf.sh" create fresh http://127.0.0.1:7200 2>&1)"; then
  fail "create should fail when local service write fails after remote create"
fi
printf '%s\n' "$create_output" | grep -q "远端隧道已创建成功: fresh" || fail "create failure should report remote success"
printf '%s\n' "$create_output" | grep -q "远端 ID: 44444444-4444-4444-4444-444444444444" || fail "create failure should report remote id"
printf '%s\n' "$create_output" | grep -q "恢复建议: 修复本地写入/权限问题后执行 cf sync" || fail "create failure should suggest sync"
printf '%s\n' "$create_output" | grep -q "如果不保留该远端隧道，执行: cf delete fresh" || fail "create failure should suggest delete"
[[ ! -e "$TMP_DIR/home/fresh.yml" ]] || fail "create local failure should roll back yml"
[[ ! -e "$TMP_DIR/systemd/cf-tunnel-fresh.service" ]] || fail "create local failure should not leave service"
grep -q "tunnel create fresh" "$TMP_DIR/cloudflared.log" || fail "create did not call fake cloudflared"

sync_list="$(printf '%s\n%s %s\n%s %s' \
  "ID NAME" \
  "22222222-2222-2222-2222-222222222222" "remote-a" \
  "33333333-3333-3333-3333-333333333333" "remote-b")"
sync_output=""
if sync_output="$(run_cf env FAKE_CLOUDFLARED_LIST="$sync_list" FAKE_SERVICE_MKTEMP_FAIL_NAME=remote-b bash "$ROOT_DIR/cf.sh" sync 2>&1)"; then
  fail "sync should fail when one local service write fails"
fi
printf '%s\n' "$sync_output" | grep -q "远端未被修改，失败项本地文件已尝试回滚: remote-b" || fail "sync failure should report remote unchanged"
printf '%s\n' "$sync_output" | grep -q "前面已成功同步的隧道不会自动回滚" || fail "sync failure should report partial local success"
printf '%s\n' "$sync_output" | grep -q "恢复建议: 修复本地写入/权限问题后重新执行 cf sync" || fail "sync failure should suggest rerun"
[[ -f "$TMP_DIR/home/remote-a.yml" ]] || fail "sync should keep earlier successful yml"
[[ -f "$TMP_DIR/systemd/cf-tunnel-remote-a.service" ]] || fail "sync should keep earlier successful service"
[[ ! -e "$TMP_DIR/home/remote-b.yml" ]] || fail "sync should roll back failed yml"
[[ ! -e "$TMP_DIR/systemd/cf-tunnel-remote-b.service" ]] || fail "sync should not leave failed service"
if find "$TMP_DIR" -maxdepth 1 -name 'cf_sync_list.*' -print -quit | grep -q .; then
  fail "sync failure should remove temporary list"
fi

echo "ok - cf command fake cloudflared/systemctl"
