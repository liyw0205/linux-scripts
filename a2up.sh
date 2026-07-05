#!/usr/bin/env bash
set -euo pipefail

A2UP_VERSION="2026.04.20-lite-r2"

MODDIR="${MODDIR:-/opt/aria2c}"
CONF_FILE="${CONF_FILE:-$MODDIR/aria2c.conf}"
SESSION_FILE="${SESSION_FILE:-$MODDIR/aria2c.session}"
DHT_FILE="${DHT_FILE:-$MODDIR/dht.dat}"
DHT6_FILE="${DHT6_FILE:-$MODDIR/dht6.dat}"
HOOK_SCRIPT="${HOOK_SCRIPT:-$MODDIR/scan-upload.sh}"
HOOK_LOG="${HOOK_LOG:-$MODDIR/upload-hook.log}"

DOWNLOAD_DIR="${DOWNLOAD_DIR:-/data/aria2-staging}"
RCLONE_REMOTE="${RCLONE_REMOTE:-webdav_remote}"
REMOTE_BASE="${REMOTE_BASE:-downloads}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"

RPC_PORT="${RPC_PORT:-6800}"
LISTEN_PORT="${LISTEN_PORT:-6801-6999}"
RPC_LISTEN_ALL="${RPC_LISTEN_ALL:-false}"
RPC_SECRET="${RPC_SECRET:-}"
SECRET_ENV_FILE="${SECRET_ENV_FILE:-$MODDIR/a2up-secret.env}"

SERVICE_NAME="${SERVICE_NAME:-aria2c.service}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

SCAN_SERVICE_NAME="${SCAN_SERVICE_NAME:-a2up-scan.service}"
SCAN_SERVICE_FILE="/etc/systemd/system/${SCAN_SERVICE_NAME}"

PATCH_TARGET="${PATCH_TARGET:-/usr/local/bin/a2up}"

MIN_AGE="${MIN_AGE:-90}"
STABLE_CHECK_GAP="${STABLE_CHECK_GAP:-3}"

ok(){ echo -e "\033[1;32m[信息]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[警告]\033[0m $*"; }
err(){ echo -e "\033[1;31m[错误]\033[0m $*" >&2; }
die(){ err "$*"; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }

run_root(){
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    need_cmd sudo || die "需要 sudo 或 root 权限"
    sudo "$@"
  fi
}

require_systemd(){
  need_cmd systemctl || die "当前系统不是 systemd"
}

get_run_user(){
  echo "${SUDO_USER:-$USER}"
}

get_run_group(){
  local run_user
  run_user="$(get_run_user)"
  id -gn "$run_user"
}

get_run_home(){
  local run_user run_home
  run_user="$(get_run_user)"
  run_home="$(getent passwd "$run_user" | awk -F: '{print $6}')"
  [[ -z "${run_home:-}" ]] && run_home="$HOME"
  echo "$run_home"
}

detect_rclone_conf_path(){
  local conf run_home
  conf="$(rclone config file 2>/dev/null | awk -F': ' '/Configuration file is stored at:/ {print $2}')"
  if [[ -n "${conf:-}" ]]; then
    echo "$conf"
    return 0
  fi
  run_home="$(get_run_home)"
  echo "${run_home}/.config/rclone/rclone.conf"
}

init_rclone_config(){
  if [[ -z "${RCLONE_CONFIG:-}" ]]; then
    RCLONE_CONFIG="$(detect_rclone_conf_path)"
  fi
}

rclone_cmd(){
  init_rclone_config
  rclone --config "$RCLONE_CONFIG" "$@"
}

stop_unit_if_active(){
  local unit="$1"
  run_root systemctl stop "$unit" 2>/dev/null || true
}

start_unit_async(){
  local unit="$1"
  run_root systemctl start "$unit" --no-block
}

install_pkgs(){
  local pkgs=(aria2 rclone curl jq)
  if need_cmd apt-get; then
    run_root apt-get update -y
    run_root apt-get install -y "${pkgs[@]}"
  elif need_cmd dnf; then
    run_root dnf install -y "${pkgs[@]}"
  elif need_cmd yum; then
    run_root yum install -y epel-release || true
    run_root yum install -y "${pkgs[@]}"
  elif need_cmd pacman; then
    run_root pacman -Sy --noconfirm "${pkgs[@]}"
  else
    die "不支持的包管理器"
  fi
}

ask_default(){
  local prompt="$1" default="$2" val
  read -r -p "$prompt [$default]: " val || true
  [[ -z "${val:-}" ]] && val="$default"
  echo "$val"
}

generate_rpc_secret(){
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

is_safe_rpc_secret(){
  local secret="$1"
  [[ "$secret" =~ ^[A-Za-z0-9._-]{8,128}$ ]]
}

read_conf_rpc_secret(){
  [[ -f "$CONF_FILE" ]] || return 0
  awk -F= '/^[[:space:]]*rpc-secret[[:space:]]*=/ {
    value = $2
    sub(/^[[:space:]]*/, "", value)
    sub(/[[:space:]]*$/, "", value)
    print value
    exit
  }' "$CONF_FILE"
}

ensure_rpc_secret(){
  local existing

  if [[ -n "${RPC_SECRET:-}" ]]; then
    is_safe_rpc_secret "$RPC_SECRET" || die "RPC_SECRET 只能包含 8-128 位字母、数字、点、下划线或连字符"
    return 0
  fi

  existing="$(read_conf_rpc_secret || true)"
  if [[ -n "${existing:-}" ]]; then
    if is_safe_rpc_secret "$existing"; then
      RPC_SECRET="$existing"
      return 0
    fi
    warn "现有 rpc-secret 包含不安全字符，将重新生成"
  fi

  RPC_SECRET="$(generate_rpc_secret)"
  is_safe_rpc_secret "$RPC_SECRET" || die "无法生成可用 RPC 密钥"
  ok "已生成 aria2 RPC 密钥"
}

write_secret_env(){
  ensure_rpc_secret
  run_root tee "$SECRET_ENV_FILE" >/dev/null <<EOF
ARIA2_RPC_SECRET=${RPC_SECRET}
EOF
  run_root chmod 600 "$SECRET_ENV_FILE" 2>/dev/null || true
}

interactive_config(){
  local _sec existing_secret
  echo
  ok "开始交互配置（回车使用默认值）"
  DOWNLOAD_DIR="$(ask_default '本地下载目录' "$DOWNLOAD_DIR")"
  RCLONE_REMOTE="$(ask_default 'rclone remote 名称' "$RCLONE_REMOTE")"
  REMOTE_BASE="$(ask_default '远端目录前缀' "$REMOTE_BASE")"
  RPC_PORT="$(ask_default 'RPC 端口' "$RPC_PORT")"
  LISTEN_PORT="$(ask_default 'BT/DHT 端口(范围可)' "$LISTEN_PORT")"
  MIN_AGE="$(ask_default '文件稳定判定秒数' "$MIN_AGE")"
  STABLE_CHECK_GAP="$(ask_default '二次大小稳定检查间隔秒数' "$STABLE_CHECK_GAP")"
  existing_secret="${RPC_SECRET:-$(read_conf_rpc_secret || true)}"
  read -r -s -p "RPC 密钥(留空保留已有/自动生成): " _sec || true
  echo
  if [[ -n "${_sec:-}" ]]; then
    RPC_SECRET="$_sec"
  else
    RPC_SECRET="$existing_secret"
  fi
  ensure_rpc_secret
}

prepare_dirs(){
  local run_user run_group
  run_user="$(get_run_user)"
  run_group="$(get_run_group)"
  run_root mkdir -p "$MODDIR" "$DOWNLOAD_DIR"
  run_root touch "$SESSION_FILE" "$HOOK_LOG"
  run_root chown -R "$run_user:$run_group" "$MODDIR" "$DOWNLOAD_DIR"
}

patch_cmd(){
  local src
  src="$(readlink -f "$0")"
  [[ -n "$src" && -f "$src" ]] || die "无法定位当前脚本路径"
  run_root cp "$src" "$PATCH_TARGET"
  run_root chmod +x "$PATCH_TARGET"
  ok "已安装到: $PATCH_TARGET"
}

auto_patch_if_needed(){
  local src
  src="$(readlink -f "$0")"
  [[ -n "$src" && -f "$src" ]] || return 0
  if [[ "$src" != "$PATCH_TARGET" ]]; then
    run_root cp "$src" "$PATCH_TARGET"
    run_root chmod +x "$PATCH_TARGET"
    ok "已自动 patch 到: $PATCH_TARGET"
  fi
}

validate_binaries(){
  need_cmd bash || die "缺少 bash"
  need_cmd aria2c || die "缺少 aria2c，请先执行 install"
  need_cmd rclone || die "缺少 rclone，请先安装并配置好 remote"
  need_cmd curl || die "缺少 curl，请先执行 install"
  need_cmd jq || die "缺少 jq，请先执行 install"
}

check_remote(){
  init_rclone_config
  rclone_cmd listremotes | grep -q "^${RCLONE_REMOTE}:$" || die "未找到 remote: ${RCLONE_REMOTE}（配置文件: ${RCLONE_CONFIG}）"
  rclone_cmd lsd "${RCLONE_REMOTE}:" >/dev/null 2>&1 || die "remote 连通失败: ${RCLONE_REMOTE}:"
}

ensure_download_dir(){
  local run_user run_group
  run_user="$(get_run_user)"
  run_group="$(get_run_group)"
  if [[ ! -d "$DOWNLOAD_DIR" ]]; then
    warn "下载目录不存在，自动创建: $DOWNLOAD_DIR"
    run_root mkdir -p "$DOWNLOAD_DIR"
    run_root chown -R "$run_user:$run_group" "$DOWNLOAD_DIR"
  fi
}

ensure_runtime_files(){
  local run_user run_group
  run_user="$(get_run_user)"
  run_group="$(get_run_group)"

  [[ -d "$MODDIR" ]] || run_root mkdir -p "$MODDIR"
  [[ -f "$SESSION_FILE" ]] || run_root touch "$SESSION_FILE"
  [[ -f "$HOOK_LOG" ]] || run_root touch "$HOOK_LOG"

  run_root chown -R "$run_user:$run_group" "$MODDIR"
}

write_hook(){
  run_root tee "$HOOK_SCRIPT" >/dev/null <<'HOOK_EOF'
#!/usr/bin/env bash
set -euo pipefail

A2UP_VERSION="${A2UP_VERSION:-unknown}"

RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"
RCLONE_REMOTE="${RCLONE_REMOTE:-webdav_remote}"
REMOTE_BASE="${REMOTE_BASE:-downloads}"
LOCAL_ROOT="${LOCAL_ROOT:-/data/aria2-staging}"
HOOK_LOG="${HOOK_LOG:-/opt/aria2c/upload-hook.log}"
HOOK_LOCK="${HOOK_LOCK:-/tmp/aria2-upload.lock}"
MIN_AGE="${MIN_AGE:-90}"
STABLE_CHECK_GAP="${STABLE_CHECK_GAP:-3}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
ARIA2_RPC_URL="${ARIA2_RPC_URL:-http://127.0.0.1:6800/jsonrpc}"
ARIA2_RPC_SECRET="${ARIA2_RPC_SECRET:-}"

TASKS_CACHE_FILE=""

log_i(){ echo "[$(date '+%F %T')] [信息] $*"; }
log_w(){ echo "[$(date '+%F %T')] [警告] $*"; }
log_e(){ echo "[$(date '+%F %T')] [错误] $*"; }

mkdir -p "$(dirname "$HOOK_LOG")" 2>/dev/null || true
touch "$HOOK_LOG" 2>/dev/null || true
exec >>"$HOOK_LOG" 2>&1

log_i "a2up hook 启动 version=$A2UP_VERSION pid=$$"
log_i "LOCAL_ROOT=$LOCAL_ROOT"
log_i "RCLONE_REMOTE=$RCLONE_REMOTE"
log_i "RCLONE_CONFIG=${RCLONE_CONFIG:-"(default)"}"

need_cmd(){ command -v "$1" >/dev/null 2>&1; }

cleanup(){
  [[ -n "${TASKS_CACHE_FILE:-}" && -f "$TASKS_CACHE_FILE" ]] && rm -f "$TASKS_CACHE_FILE" || true
}
trap cleanup EXIT

rclone_run(){
  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    "$RCLONE_BIN" --config "$RCLONE_CONFIG" "$@"
  else
    "$RCLONE_BIN" "$@"
  fi
}

json_rpc(){
  local payload="$1"
  curl -fsS \
    --connect-timeout 3 \
    --max-time 10 \
    "$ARIA2_RPC_URL" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>/dev/null || true
}

fetch_all_tasks_json(){
  local payload resp
  if [[ -n "$ARIA2_RPC_SECRET" ]]; then
    payload='{
      "jsonrpc":"2.0",
      "id":"a2up",
      "method":"system.multicall",
      "params":[[
        {"methodName":"aria2.tellActive","params":["token:'"$ARIA2_RPC_SECRET"'",["gid","status","bittorrent","files"]]},
        {"methodName":"aria2.tellWaiting","params":["token:'"$ARIA2_RPC_SECRET"'",0,1000,["gid","status","bittorrent","files"]]},
        {"methodName":"aria2.tellStopped","params":["token:'"$ARIA2_RPC_SECRET"'",0,1000,["gid","status","bittorrent","files"]]}
      ]]
    }'
  else
    payload='{
      "jsonrpc":"2.0",
      "id":"a2up",
      "method":"system.multicall",
      "params":[[
        {"methodName":"aria2.tellActive","params":[["gid","status","bittorrent","files"]]},
        {"methodName":"aria2.tellWaiting","params":[0,1000,["gid","status","bittorrent","files"]]},
        {"methodName":"aria2.tellStopped","params":[0,1000,["gid","status","bittorrent","files"]]}
      ]]
    }'
  fi

  resp="$(json_rpc "$payload")"
  [[ -n "$resp" ]] || return 1

  echo "$resp" | "$JQ_BIN" -c '
    [(.result[0][0] // []), (.result[1][0] // []), (.result[2][0] // [])]
    | add
    | unique_by(.gid)
  ' 2>/dev/null || return 1
}

refresh_tasks_cache(){
  local tmp
  tmp="$(mktemp)"
  if fetch_all_tasks_json > "$tmp"; then
    TASKS_CACHE_FILE="$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

get_local_size(){
  local f="$1"
  stat -c '%s' "$f" 2>/dev/null || return 1
}

task_file_exists(){
  local src="$1"
  [[ -n "${TASKS_CACHE_FILE:-}" && -f "$TASKS_CACHE_FILE" ]] || return 1
  "$JQ_BIN" -e --arg p "$src" '
    map(.files[]? | select(.path == $p)) | length > 0
  ' "$TASKS_CACHE_FILE" >/dev/null 2>&1
}

task_file_completed(){
  local src="$1"
  local local_size
  [[ -n "${TASKS_CACHE_FILE:-}" && -f "$TASKS_CACHE_FILE" ]] || return 1
  [[ -f "$src" ]] || return 1

  local_size="$(stat -c '%s' "$src" 2>/dev/null || echo 0)"
  [[ -n "${local_size:-}" ]] || local_size=0

  "$JQ_BIN" -e --arg p "$src" --argjson lsize "$local_size" '
    [
      .[]?.files[]?
      | select(.path == $p)
      | (
          ((.length // "0") | tonumber) > 0
          and
          (
            ((.completedLength // "0") | tonumber) >= ((.length // "0") | tonumber)
            or
            ($lsize >= ((.length // "0") | tonumber))
          )
        )
    ] | any
  ' "$TASKS_CACHE_FILE" >/dev/null 2>&1
}

is_skip_file(){
  local f="$1" base
  base="$(basename "$f")"
  [[ ! -f "$f" ]] && return 0
  case "$base" in
    *.aria2|*.torrent|*.tmp|*.part) return 0 ;;
    \[METADATA\]*) return 0 ;;
  esac
  return 1
}

build_rel_path(){
  local src="$1"
  local rel
  rel="${src#${LOCAL_ROOT}/}"
  if [[ "$rel" == "$src" ]]; then
    echo ""
    return 1
  fi
  echo "$rel"
}

build_target_dir(){
  local src="$1" rel dirp
  rel="$(build_rel_path "$src" || true)"
  if [[ -z "$rel" ]]; then
    echo "${RCLONE_REMOTE}:${REMOTE_BASE}/_unknown_path/"
    return
  fi
  dirp="$(dirname "$rel")"
  [[ "$dirp" == "." ]] && dirp=""
  echo "${RCLONE_REMOTE}:${REMOTE_BASE}/${dirp}/"
}

build_target_file(){
  local src="$1" rel
  rel="$(build_rel_path "$src" || true)"
  if [[ -z "$rel" ]]; then
    echo "${RCLONE_REMOTE}:${REMOTE_BASE}/_unknown_path/$(basename "$src")"
    return
  fi
  echo "${RCLONE_REMOTE}:${REMOTE_BASE}/${rel}"
}

is_stable_file(){
  local f="$1"
  local now mtime age size1 size2

  [[ -f "$f" ]] || return 1

  now="$(date +%s)"
  mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  age=$((now - mtime))
  (( age >= MIN_AGE )) || return 1

  size1="$(get_local_size "$f" || echo "")"
  [[ -n "$size1" ]] || return 1

  sleep "$STABLE_CHECK_GAP"

  [[ -f "$f" ]] || return 1
  size2="$(get_local_size "$f" || echo "")"
  [[ -n "$size2" ]] || return 1

  (( size1 > 0 )) || return 1
  (( size2 > 0 )) || return 1
  [[ "$size1" == "$size2" ]]
}

remote_exists(){
  local remote_file="$1"
  rclone_run lsjson "$remote_file" --files-only --no-mimetype --no-modtime 2>/dev/null | "$JQ_BIN" -e 'length > 0' >/dev/null 2>&1
}

get_remote_size(){
  local remote_file="$1"
  local out
  out="$(rclone_run lsjson "$remote_file" --files-only --no-mimetype --no-modtime 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  echo "$out" | "$JQ_BIN" -r '.[0].Size // empty' 2>/dev/null | head -n1
}

handle_zero_byte_file(){
  local src="$1" remote_file="$2"
  local lsize
  lsize="$(get_local_size "$src" || echo "")"
  [[ -n "$lsize" ]] || return 1
  (( lsize == 0 )) || return 1

  if task_file_exists "$src"; then
    log_i "aria2 任务内 0B 文件，跳过: $src"
    return 0
  fi

  rm -f -- "$src" || true
  log_i "已删除本地孤儿 0B 文件: $src"

  local rsize
  rsize="$(get_remote_size "$remote_file" || echo "")"
  if [[ -n "$rsize" && "$rsize" == "0" ]]; then
    rclone_run deletefile "$remote_file" >/dev/null 2>&1 || true
    log_i "已删除远端 0B 文件: $remote_file"
  fi
  return 0
}

should_process_file(){
  local src="$1"
  local lsize

  lsize="$(get_local_size "$src" || echo "")"
  [[ -n "$lsize" ]] || return 1

  if (( lsize == 0 )); then
    return 2
  fi

  if task_file_exists "$src"; then
    if task_file_completed "$src"; then
      log_i "检测到 aria2 任务内已完成文件，允许上传: $src"
      return 0
    else
      log_i "文件仍在 aria2 任务中且未完成，跳过: $src"
      return 1
    fi
  fi

  if is_stable_file "$src"; then
    return 0
  fi

  log_i "文件未稳定或仍在变化，跳过: $src"
  return 1
}

handle_existing_remote(){
  local src="$1" remote_file="$2"
  local local_size remote_size

  local_size="$(get_local_size "$src" || echo "")"
  [[ -n "$local_size" ]] || return 2

  if (( local_size == 0 )); then
    handle_zero_byte_file "$src" "$remote_file"
    return 0
  fi

  remote_size="$(get_remote_size "$remote_file" || echo "")"
  if [[ -z "$remote_size" ]]; then
    log_w "无法获取远端大小，改为覆盖上传: $remote_file"
    return 2
  fi

  log_i "检测到远端同名文件: 本地=$local_size 远端=$remote_size 文件=$remote_file"

  if (( remote_size >= local_size )); then
    rm -f -- "$src" || true
    log_i "远端已存在且不小于本地，已删除本地并跳过上传: $src"
    return 0
  fi

  log_i "本地文件更大，执行覆盖上传: $src"
  return 2
}

pre_upload_check(){
  local src="$1"
  local size1 size2

  [[ -f "$src" ]] || return 1

  size1="$(get_local_size "$src" || echo 0)"
  [[ -n "${size1:-}" ]] || size1=0
  (( size1 > 0 )) || return 1

  sleep 1

  [[ -f "$src" ]] || return 1
  size2="$(get_local_size "$src" || echo 0)"
  [[ -n "${size2:-}" ]] || size2=0
  (( size2 > 0 )) || return 1

  [[ "$size1" == "$size2" ]]
}

upload_one(){
  local src="$1" dst_dir remote_file rc current_size

  [[ -n "$src" && -f "$src" ]] || return 0

  if is_skip_file "$src"; then
    log_w "跳过临时/控制文件: $src"
    return 0
  fi

  dst_dir="$(build_target_dir "$src")"
  remote_file="$(build_target_file "$src")"

  if handle_zero_byte_file "$src" "$remote_file"; then
    return 0
  fi

  should_process_file "$src"
  rc=$?
  if [[ $rc -eq 1 ]]; then
    return 0
  elif [[ $rc -eq 2 ]]; then
    handle_zero_byte_file "$src" "$remote_file" || true
    return 0
  fi

  if ! pre_upload_check "$src"; then
    log_w "上传前二次校验失败，文件可能已消失、变为0B或仍在变化，跳过: $src"
    return 0
  fi

  current_size="$(get_local_size "$src" || echo 0)"
  [[ -n "${current_size:-}" ]] || current_size=0
  if (( current_size == 0 )); then
    log_w "上传前文件大小为0，跳过: $src"
    return 0
  fi

  if remote_exists "$remote_file"; then
    if handle_existing_remote "$src" "$remote_file"; then
      return 0
    else
      rc=$?
      if [[ $rc -ne 2 ]]; then
        return 0
      fi
    fi
  fi

  if [[ ! -f "$src" ]]; then
    log_w "开始上传前文件已不存在，跳过: $src"
    return 0
  fi

  log_i "开始上传: src=$src size=$current_size dst=$dst_dir"
  if rclone_run move "$src" "$dst_dir" \
    --create-empty-src-dirs=false \
    --transfers=1 \
    --checkers=2 \
    --retries=10 \
    --low-level-retries=20 \
    --timeout=1m \
    --contimeout=15s \
    --log-level=INFO; then
    log_i "上传成功并删除本地: $src"
    return 0
  else
    local rc2=$?
    if [[ ! -f "$src" ]]; then
      log_w "上传失败时发现源文件已消失，可能是 aria2 取消/清理导致: $src"
      return 0
    fi
    log_e "上传失败 rc=$rc2: $src"
    return "$rc2"
  fi
}

scan_all(){
  local ok_count=0 fail_count=0 total=0 f

  [[ -d "$LOCAL_ROOT" ]] || {
    log_w "下载目录不存在: $LOCAL_ROOT"
    return 0
  }

  refresh_tasks_cache || true

  if ! find "$LOCAL_ROOT" -type f -print -quit 2>/dev/null | grep -q .; then
    log_i "没有可上传文件，结束本次扫描"
    return 0
  fi

  while IFS= read -r -d '' f; do
    ((total+=1))
    refresh_tasks_cache || true
    if upload_one "$f"; then
      ((ok_count+=1))
    else
      ((fail_count+=1))
    fi
  done < <(find "$LOCAL_ROOT" -type f -print0)

  find "$LOCAL_ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  log_i "扫描统计: 总计=$total 成功=$ok_count 失败=$fail_count"
}

exec 9>"$HOOK_LOCK"
if ! flock -n 9; then
  log_w "已有扫描任务在运行，跳过本次"
  exit 0
fi

if ! need_cmd "$JQ_BIN"; then
  log_e "缺少 jq: $JQ_BIN"
  exit 1
fi

log_i "开始手动扫描上传"
scan_all
log_i "扫描上传执行完成"
exit 0
HOOK_EOF

  run_root sed -i 's/\r$//' "$HOOK_SCRIPT" 2>/dev/null || true
  run_root chmod +x "$HOOK_SCRIPT"
}

ensure_hook_ready(){
  local rewrite=0

  if [[ ! -f "$HOOK_SCRIPT" ]]; then
    warn "扫描脚本不存在，自动重建: $HOOK_SCRIPT"
    rewrite=1
  elif [[ ! -x "$HOOK_SCRIPT" ]]; then
    warn "扫描脚本无执行权限，自动修复: $HOOK_SCRIPT"
    run_root chmod +x "$HOOK_SCRIPT" || rewrite=1
  fi

  if [[ $rewrite -eq 1 ]]; then
    write_hook
  fi

  run_root sed -i 's/\r$//' "$HOOK_SCRIPT" 2>/dev/null || true
  run_root chmod +x "$HOOK_SCRIPT"

  [[ -f "$HOOK_SCRIPT" ]] || die "扫描脚本仍不存在: $HOOK_SCRIPT"
  [[ -x "$HOOK_SCRIPT" ]] || die "扫描脚本不可执行: $HOOK_SCRIPT"
}

write_conf(){
  ensure_rpc_secret
  run_root tee "$CONF_FILE" >/dev/null <<EOF
# aria2 下载目录
dir=${DOWNLOAD_DIR}

# 文件策略
file-allocation=none
continue=true
split=8
disk-cache=8M
min-split-size=1M
max-concurrent-downloads=2
max-connection-per-server=4
max-overall-upload-limit=10K

# 会话保存
input-file=${SESSION_FILE}
save-session=${SESSION_FILE}
save-session-interval=60

# RPC
enable-rpc=true
rpc-listen-all=${RPC_LISTEN_ALL}
rpc-listen-port=${RPC_PORT}
rpc-allow-origin-all=true
rpc-secret=${RPC_SECRET}

# BT / DHT
follow-torrent=true
enable-dht=true
enable-dht6=true
bt-save-metadata=true
bt-enable-lpd=false
dht-file-path=${DHT_FILE}
dht-file-path6=${DHT6_FILE}
dht-listen-port=${LISTEN_PORT}
listen-port=${LISTEN_PORT}

# 下载完成后不做种
seed-time=0
EOF
}

ensure_conf_ready(){
  if [[ ! -f "$CONF_FILE" ]]; then
    warn "aria2 配置不存在，自动重建: $CONF_FILE"
    write_conf
  else
    ensure_rpc_secret
  fi
}

write_service(){
  local run_user run_group aria2_bin rclone_bin jq_bin
  run_user="$(get_run_user)"
  run_group="$(get_run_group)"
  aria2_bin="$(command -v aria2c)"
  rclone_bin="$(command -v rclone)"
  jq_bin="$(command -v jq)"
  init_rclone_config

  run_root tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Aria2c Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
Group=${run_group}
Environment=A2UP_VERSION=${A2UP_VERSION}
Environment=RCLONE_BIN=${rclone_bin}
Environment=RCLONE_CONFIG=${RCLONE_CONFIG}
Environment=RCLONE_REMOTE=${RCLONE_REMOTE}
Environment=REMOTE_BASE=${REMOTE_BASE}
Environment=LOCAL_ROOT=${DOWNLOAD_DIR}
Environment=HOOK_LOG=${HOOK_LOG}
Environment=HOOK_LOCK=/tmp/aria2-upload.lock
Environment=MIN_AGE=${MIN_AGE}
Environment=STABLE_CHECK_GAP=${STABLE_CHECK_GAP}
Environment=ARIA2_RPC_URL=http://127.0.0.1:${RPC_PORT}/jsonrpc
Environment=JQ_BIN=${jq_bin}
ExecStart=${aria2_bin} --conf-path=${CONF_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  run_root systemctl daemon-reload
}

write_scan_service(){
  local run_user run_group rclone_bin jq_bin
  run_user="$(get_run_user)"
  run_group="$(get_run_group)"
  rclone_bin="$(command -v rclone)"
  jq_bin="$(command -v jq)"
  init_rclone_config
  write_secret_env

  run_root tee "$SCAN_SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Manual scan aria2 download dir and upload completed files
After=network-online.target ${SERVICE_NAME}
Wants=network-online.target

[Service]
Type=oneshot
User=${run_user}
Group=${run_group}
TimeoutStartSec=24h
KillMode=mixed
Environment=A2UP_VERSION=${A2UP_VERSION}
Environment=RCLONE_BIN=${rclone_bin}
Environment=RCLONE_CONFIG=${RCLONE_CONFIG}
Environment=RCLONE_REMOTE=${RCLONE_REMOTE}
Environment=REMOTE_BASE=${REMOTE_BASE}
Environment=LOCAL_ROOT=${DOWNLOAD_DIR}
Environment=HOOK_LOG=${HOOK_LOG}
Environment=HOOK_LOCK=/tmp/aria2-upload.lock
Environment=MIN_AGE=${MIN_AGE}
Environment=STABLE_CHECK_GAP=${STABLE_CHECK_GAP}
Environment=ARIA2_RPC_URL=http://127.0.0.1:${RPC_PORT}/jsonrpc
EnvironmentFile=${SECRET_ENV_FILE}
Environment=JQ_BIN=${jq_bin}
ExecStart=/usr/bin/env bash ${HOOK_SCRIPT}
EOF

  run_root systemctl daemon-reload
}

ensure_services_ready(){
  local need_reload=0

  if [[ ! -f "$SERVICE_FILE" ]]; then
    warn "主服务单元不存在，自动重建: $SERVICE_FILE"
    write_service
    need_reload=1
  fi

  if [[ ! -f "$SCAN_SERVICE_FILE" ]]; then
    warn "扫描服务单元不存在，自动重建: $SCAN_SERVICE_FILE"
    write_scan_service
    need_reload=1
  fi

  if [[ $need_reload -eq 1 ]]; then
    run_root systemctl daemon-reload
  fi
}

preflight_check(){
  require_systemd
  validate_binaries
  init_rclone_config
  ensure_rpc_secret
  ensure_runtime_files
  ensure_download_dir
  ensure_conf_ready
  write_secret_env
  ensure_hook_ready
  ensure_services_ready
  check_remote
}

remote_check_cmd(){
  validate_binaries
  init_rclone_config
  check_remote
  ok "remote 正常，使用配置文件: ${RCLONE_CONFIG}"
}

remote_info_cmd(){
  init_rclone_config
  echo "A2UP_VERSION=$A2UP_VERSION"
  echo "RCLONE_REMOTE=$RCLONE_REMOTE"
  echo "RCLONE_CONFIG=$RCLONE_CONFIG"
  echo
  rclone_cmd listremotes 2>/dev/null || true
}

install_cmd(){
  require_systemd
  auto_patch_if_needed
  install_pkgs
  init_rclone_config
  interactive_config

  prepare_dirs
  write_hook
  write_conf
  write_service
  write_scan_service
  preflight_check

  run_root systemctl enable "$SERVICE_NAME"
  run_root systemctl restart "$SERVICE_NAME"

  ok "安装完成"
  ok "版本: $A2UP_VERSION"
  ok "aria2 已启动"
  ok "命令已自动安装到: $PATCH_TARGET"
  ok "rclone 配置文件: $RCLONE_CONFIG"
  ok "上传日志: tail -f $HOOK_LOG"
  warn "rclone remote / mount 不再由本脚本管理，请确保已提前配置好"
  warn "扫描上传改为手动触发，请执行: $(basename "$PATCH_TARGET") scan-run"
}

start_cmd(){
  preflight_check
  run_root systemctl enable "$SERVICE_NAME"
  run_root systemctl restart "$SERVICE_NAME"
  ok "已启动并完成启动前自检"
}

stop_cmd(){
  stop_unit_if_active "$SCAN_SERVICE_NAME"
  stop_unit_if_active "$SERVICE_NAME"
  ok "已停止 aria2 服务，并停止扫描任务"
}

restart_cmd(){
  preflight_check
  run_root systemctl restart "$SERVICE_NAME"
  ok "aria2 已重启并完成重启前自检"
}

status_cmd(){
  run_root systemctl status "$SERVICE_NAME" "$SCAN_SERVICE_NAME" --no-pager -l
}

logs_cmd(){
  local n="${1:-200}"
  run_root journalctl -u "$SERVICE_NAME" -u "$SCAN_SERVICE_NAME" -n "$n" -f --no-pager
}

info_cmd(){
  init_rclone_config
  echo "A2UP_VERSION=$A2UP_VERSION"
  echo "CONF=$CONF_FILE"
  echo "HOOK=$HOOK_SCRIPT"
  echo "LOG=$HOOK_LOG"
  echo "DOWNLOAD_DIR=$DOWNLOAD_DIR"
  echo "RCLONE_REMOTE=$RCLONE_REMOTE"
  echo "RCLONE_CONFIG=$RCLONE_CONFIG"
  echo "REMOTE_BASE=$REMOTE_BASE"
  echo "MIN_AGE=$MIN_AGE"
  echo "STABLE_CHECK_GAP=$STABLE_CHECK_GAP"
  echo "PATCH_TARGET=$PATCH_TARGET"
  echo "SECRET_ENV_FILE=$SECRET_ENV_FILE"
  echo
  sed -E 's/^(rpc-secret=).*/\1<redacted>/' "$CONF_FILE" 2>/dev/null || true
}

reconfig_cmd(){
  init_rclone_config
  interactive_config

  prepare_dirs
  write_hook
  write_conf
  write_service
  write_scan_service
  preflight_check

  run_root systemctl restart "$SERVICE_NAME"
  ok "重配置完成"
}

scan_run_cmd(){
  preflight_check
  start_unit_async "$SCAN_SERVICE_NAME"
  ok "已异步触发一次扫描上传"
}

scan_stop_cmd(){
  stop_unit_if_active "$SCAN_SERVICE_NAME"
  run_root systemctl kill "$SCAN_SERVICE_NAME" 2>/dev/null || true
  run_root pkill -f "$HOOK_SCRIPT" 2>/dev/null || true
  run_root systemctl reset-failed "$SCAN_SERVICE_NAME" 2>/dev/null || true
  ok "已停止扫描上传任务"
}

scan_pause_cmd(){
  scan_stop_cmd
}

scan_status_cmd(){
  run_root systemctl status "$SCAN_SERVICE_NAME" --no-pager -l
}

doctor_cmd(){
  init_rclone_config

  echo "== 版本 =="
  echo "A2UP_VERSION=$A2UP_VERSION"

  echo
  echo "== 基础命令检查 =="
  for c in bash aria2c rclone curl jq systemctl; do
    if command -v "$c" >/dev/null 2>&1; then
      echo "[OK] $c => $(command -v "$c")"
    else
      echo "[NO] $c"
    fi
  done

  echo
  echo "== 路径检查 =="
  for p in \
    "$MODDIR" "$DOWNLOAD_DIR" "$CONF_FILE" "$SESSION_FILE" \
    "$HOOK_SCRIPT" "$HOOK_LOG" \
    "$SERVICE_FILE" "$SCAN_SERVICE_FILE" \
    "$RCLONE_CONFIG"
  do
    [[ -e "$p" ]] && echo "[OK] $p" || echo "[NO] $p"
  done

  echo
  echo "== 权限检查 =="
  [[ -x "$HOOK_SCRIPT" ]] && echo "[OK] hook 可执行" || echo "[NO] hook 不可执行"

  echo
  echo "== RPC 安全检查 =="
  if [[ -f "$CONF_FILE" ]]; then
    grep -qE '^[[:space:]]*rpc-listen-all=false[[:space:]]*$' "$CONF_FILE" \
      && echo "[OK] RPC 仅监听本机" \
      || echo "[NO] rpc-listen-all 不是 false"
    [[ -n "$(read_conf_rpc_secret || true)" ]] \
      && echo "[OK] rpc-secret 已配置" \
      || echo "[NO] rpc-secret 未配置"
  else
    echo "[NO] 配置文件不存在，无法检查 RPC"
  fi
  [[ -f "$SECRET_ENV_FILE" ]] \
    && echo "[OK] 扫描服务密钥环境文件存在: $SECRET_ENV_FILE" \
    || echo "[NO] 扫描服务密钥环境文件不存在: $SECRET_ENV_FILE"

  echo
  echo "== rclone remote 检查 =="
  if rclone_cmd listremotes | grep -q "^${RCLONE_REMOTE}:$" 2>/dev/null; then
    echo "[OK] remote 存在: ${RCLONE_REMOTE}"
  else
    echo "[NO] remote 不存在: ${RCLONE_REMOTE}"
  fi

  echo
  echo "== systemd 状态 =="
  systemctl status "$SERVICE_NAME" "$SCAN_SERVICE_NAME" --no-pager -l || true
}

uninstall_cmd(){
  stop_unit_if_active "$SCAN_SERVICE_NAME"
  run_root systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  run_root systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  run_root rm -f "$SERVICE_FILE" "$SCAN_SERVICE_FILE"
  run_root systemctl daemon-reload
  ok "已卸载服务（保留配置和数据）"
}

usage(){
  cat <<EOF
a2up ${A2UP_VERSION}

用法:
  $0 <命令>

基础:
  install
  patch
  start
  stop
  restart
  status
  logs [N]
  info
  reconfig
  doctor
  uninstall

remote:
  remote-check
  remote-info

scan:
  scan-run
      手动异步触发一次扫描上传
  scan-stop
      停止当前扫描任务
  scan-pause
      等同 scan-stop
  scan-status
      查看扫描任务状态

说明:
  1. 本脚本不再管理 rclone remote / WebDAV mount。
  2. 默认要求 rclone 已安装，且 remote 已由专门脚本提前配置好。
  3. 不再使用定时自动扫描，改为手动执行 scan-run。
  4. 扫描脚本使用 flock 锁，避免重复触发。
  5. 不再包含 BT 裁剪 / gid 重绑定 / 延迟删除等逻辑。
EOF
}

main(){
  local cmd="${1:-}"
  case "$cmd" in
    install) install_cmd ;;
    patch) patch_cmd ;;
    start) start_cmd ;;
    stop) stop_cmd ;;
    restart) restart_cmd ;;
    status) status_cmd ;;
    logs) shift || true; logs_cmd "${1:-200}" ;;
    info) info_cmd ;;
    reconfig) reconfig_cmd ;;
    doctor) doctor_cmd ;;
    uninstall) uninstall_cmd ;;
    remote-check) remote_check_cmd ;;
    remote-info) remote_info_cmd ;;
    scan-run) scan_run_cmd ;;
    scan-stop) scan_stop_cmd ;;
    scan-pause) scan_pause_cmd ;;
    scan-status) scan_status_cmd ;;
    -h|--help|"") usage ;;
    *) die "未知命令: $cmd" ;;
  esac
}

main "$@"
