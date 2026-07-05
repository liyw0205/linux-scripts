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
  for cmd in aria2c rclone jq; do
    cat > "$bin/$cmd" <<EOF
#!/usr/bin/env sh
echo "$bin/$cmd"
EOF
    chmod +x "$bin/$cmd"
  done

  cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_SYSTEMCTL_LOG:?}"
case "${1:-}" in
  daemon-reload|status) exit 0 ;;
  *) echo "unexpected systemctl call: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$bin/systemctl"
}

TMP_DIR="$(mktemp -d)"
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/mod" "$TMP_DIR/downloads"
write_fake_bins "$TMP_DIR/bin"
export PATH="$TMP_DIR/bin:$PATH"
export FAKE_SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
: > "$FAKE_SYSTEMCTL_LOG"

# shellcheck disable=SC1090
. "$ROOT_DIR/a2up.sh"

run_root() {
  "$@"
}

get_run_user() {
  printf '%s\n' "$(id -un)"
}

get_run_group() {
  printf '%s\n' "$(id -gn)"
}

MODDIR="$TMP_DIR/mod"
CONF_FILE="$TMP_DIR/mod/aria2c.conf"
SESSION_FILE="$TMP_DIR/mod/aria2c.session"
DHT_FILE="$TMP_DIR/mod/dht.dat"
DHT6_FILE="$TMP_DIR/mod/dht6.dat"
HOOK_SCRIPT="$TMP_DIR/mod/scan-upload.sh"
HOOK_LOG="$TMP_DIR/mod/upload-hook.log"
DOWNLOAD_DIR="$TMP_DIR/downloads"
RCLONE_REMOTE="demo_remote"
RCLONE_CONFIG="$TMP_DIR/rclone.conf"
RPC_PORT="16800"
RPC_LISTEN_ALL="false"
RPC_SECRET="fixedSecret_123"
SECRET_ENV_FILE="$TMP_DIR/mod/a2up-secret.env"
SERVICE_FILE="$TMP_DIR/aria2c.service"
SCAN_SERVICE_FILE="$TMP_DIR/a2up-scan.service"
SERVICE_NAME="aria2c.service"
SCAN_SERVICE_NAME="a2up-scan.service"

write_conf
grep -qx "enable-rpc=true" "$CONF_FILE" || fail "aria2 rpc not enabled"
grep -qx "rpc-listen-all=false" "$CONF_FILE" || fail "aria2 rpc should listen locally by default"
grep -qx "rpc-listen-port=16800" "$CONF_FILE" || fail "aria2 rpc port mismatch"
grep -qx "rpc-secret=fixedSecret_123" "$CONF_FILE" || fail "aria2 rpc secret mismatch"
! grep -qx "rpc-secret=" "$CONF_FILE" || fail "empty rpc-secret should not be written"

RPC_SECRET=""
[[ "$(read_conf_rpc_secret)" == "fixedSecret_123" ]] || fail "read_conf_rpc_secret failed"
ensure_rpc_secret
[[ "$RPC_SECRET" == "fixedSecret_123" ]] || fail "ensure_rpc_secret should reuse existing secret"

write_secret_env
grep -qx "ARIA2_RPC_SECRET=fixedSecret_123" "$SECRET_ENV_FILE" || fail "secret env mismatch"
perm="$(stat -c '%a' "$SECRET_ENV_FILE")"
[[ "$perm" == "600" ]] || fail "secret env permission should be 600, got $perm"

write_service
grep -q "ExecStart=$TMP_DIR/bin/aria2c --conf-path=$CONF_FILE" "$SERVICE_FILE" || fail "main service ExecStart mismatch"
grep -q "Environment=ARIA2_RPC_URL=http://127.0.0.1:16800/jsonrpc" "$SERVICE_FILE" || fail "main service rpc url mismatch"
! grep -q "ARIA2_RPC_SECRET" "$SERVICE_FILE" || fail "main service should not inline rpc secret"
! grep -q "EnvironmentFile=" "$SERVICE_FILE" || fail "main service should not include secret env file"

write_scan_service
grep -q "EnvironmentFile=$SECRET_ENV_FILE" "$SCAN_SERVICE_FILE" || fail "scan service missing EnvironmentFile"
grep -q "Environment=ARIA2_RPC_URL=http://127.0.0.1:16800/jsonrpc" "$SCAN_SERVICE_FILE" || fail "scan service rpc url mismatch"
grep -q "ExecStart=/usr/bin/env bash $HOOK_SCRIPT" "$SCAN_SERVICE_FILE" || fail "scan service ExecStart mismatch"
! grep -q "ARIA2_RPC_SECRET=fixedSecret_123" "$SCAN_SERVICE_FILE" || fail "scan service should not inline rpc secret"

grep -qx "daemon-reload" "$FAKE_SYSTEMCTL_LOG" || fail "service writes should daemon-reload"

doctor_output="$(doctor_cmd 2>&1 || true)"
printf '%s\n' "$doctor_output" | grep -q "\[OK\] RPC 仅监听本机" || fail "doctor should accept local rpc"
printf '%s\n' "$doctor_output" | grep -q "\[OK\] rpc-secret 已配置" || fail "doctor should see rpc secret"
printf '%s\n' "$doctor_output" | grep -q "\[OK\] 扫描服务密钥环境文件存在" || fail "doctor should see secret env"

sed -i 's/^rpc-listen-all=false$/rpc-listen-all=true/' "$CONF_FILE"
doctor_output="$(doctor_cmd 2>&1 || true)"
printf '%s\n' "$doctor_output" | grep -q "\[NO\] rpc-listen-all 不是 false" || fail "doctor should reject rpc-listen-all=true"
rm -f "$SECRET_ENV_FILE"
doctor_output="$(doctor_cmd 2>&1 || true)"
printf '%s\n' "$doctor_output" | grep -q "\[NO\] 扫描服务密钥环境文件不存在" || fail "doctor should report missing secret env"

echo "ok - a2up config and service safety"
