#!/usr/bin/env bash
set -euo pipefail

########################################
# 路径与状态
########################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/webdav_copyto_relay.conf}"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/.webdav_copyto_relay}"
PID_FILE="$STATE_DIR/task.pid"
LOG_FILE="$STATE_DIR/relay.log"

########################################
# 默认配置
########################################

WEBDAV_URL_DEFAULT="http://127.0.0.1:5245/dav"
WEBDAV_USER_DEFAULT="admin"
WEBDAV_PASS_DEFAULT="root"
REMOTE_NAME_DEFAULT="webdav_relay_remote"

SRC_PATH_DEFAULT="gy/Hentai"
DST_PATH_DEFAULT="openlist/downloads"

TMP_DIR_DEFAULT="/tmp/webdav_copyto_relay"
MIN_FREE_PERCENT_DEFAULT="30"

# 传输相关
RCLONE_TRANSFERS_DEFAULT="1"
RCLONE_CHECKERS_DEFAULT="2"
RCLONE_RETRIES_DEFAULT="5"
RCLONE_LOW_LEVEL_RETRIES_DEFAULT="10"
RCLONE_TIMEOUT_DEFAULT="1m"
RCLONE_CONTIMEOUT_DEFAULT="15s"

########################################
# 日志/工具
########################################

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"
}

info(){ echo -e "\033[1;32m[INFO]\033[0m $*" | tee -a "$LOG_FILE"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*" | tee -a "$LOG_FILE"; }
err(){ echo -e "\033[1;31m[ERR ]\033[0m $*" | tee -a "$LOG_FILE" >&2; }
die(){ err "$*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

run_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    need_cmd sudo || die "需要 sudo 或 root 权限"
    sudo "$@"
  fi
}

is_pid_alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

########################################
# 配置加载/保存
########################################

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi

  WEBDAV_URL="${WEBDAV_URL:-$WEBDAV_URL_DEFAULT}"
  WEBDAV_USER="${WEBDAV_USER:-$WEBDAV_USER_DEFAULT}"
  WEBDAV_PASS="${WEBDAV_PASS:-$WEBDAV_PASS_DEFAULT}"
  REMOTE_NAME="${REMOTE_NAME:-$REMOTE_NAME_DEFAULT}"

  SRC_PATH="${SRC_PATH:-$SRC_PATH_DEFAULT}"
  DST_PATH="${DST_PATH:-$DST_PATH_DEFAULT}"

  TMP_DIR="${TMP_DIR:-$TMP_DIR_DEFAULT}"
  MIN_FREE_PERCENT="${MIN_FREE_PERCENT:-$MIN_FREE_PERCENT_DEFAULT}"

  RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-$RCLONE_TRANSFERS_DEFAULT}"
  RCLONE_CHECKERS="${RCLONE_CHECKERS:-$RCLONE_CHECKERS_DEFAULT}"
  RCLONE_RETRIES="${RCLONE_RETRIES:-$RCLONE_RETRIES_DEFAULT}"
  RCLONE_LOW_LEVEL_RETRIES="${RCLONE_LOW_LEVEL_RETRIES:-$RCLONE_LOW_LEVEL_RETRIES_DEFAULT}"
  RCLONE_TIMEOUT="${RCLONE_TIMEOUT:-$RCLONE_TIMEOUT_DEFAULT}"
  RCLONE_CONTIMEOUT="${RCLONE_CONTIMEOUT:-$RCLONE_CONTIMEOUT_DEFAULT}"
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
WEBDAV_URL="$WEBDAV_URL"
WEBDAV_USER="$WEBDAV_USER"
WEBDAV_PASS="$WEBDAV_PASS"
REMOTE_NAME="$REMOTE_NAME"

SRC_PATH="$SRC_PATH"
DST_PATH="$DST_PATH"

TMP_DIR="$TMP_DIR"
MIN_FREE_PERCENT="$MIN_FREE_PERCENT"

RCLONE_TRANSFERS="$RCLONE_TRANSFERS"
RCLONE_CHECKERS="$RCLONE_CHECKERS"
RCLONE_RETRIES="$RCLONE_RETRIES"
RCLONE_LOW_LEVEL_RETRIES="$RCLONE_LOW_LEVEL_RETRIES"
RCLONE_TIMEOUT="$RCLONE_TIMEOUT"
RCLONE_CONTIMEOUT="$RCLONE_CONTIMEOUT"
EOF
}

ask_default() {
  local prompt="$1" default="$2" val
  read -r -p "$prompt [$default]: " val || true
  [[ -z "${val:-}" ]] && val="$default"
  echo "$val"
}

config_interactive() {
  echo
  info "开始配置（回车用默认值）"

  WEBDAV_URL="$(ask_default "WebDAV URL" "${WEBDAV_URL:-$WEBDAV_URL_DEFAULT}")"
  WEBDAV_USER="$(ask_default "WebDAV 用户名" "${WEBDAV_USER:-$WEBDAV_USER_DEFAULT}")"

  read -r -p "WebDAV 密码 [留空保留当前/默认 root]: " _pass || true
  if [[ -n "${_pass:-}" ]]; then
    WEBDAV_PASS="$_pass"
  else
    WEBDAV_PASS="${WEBDAV_PASS:-$WEBDAV_PASS_DEFAULT}"
  fi

  REMOTE_NAME="$(ask_default "rclone remote 名称" "${REMOTE_NAME:-$REMOTE_NAME_DEFAULT}")"
  SRC_PATH="$(ask_default "源路径(WebDAV内)" "${SRC_PATH:-$SRC_PATH_DEFAULT}")"
  DST_PATH="$(ask_default "目标路径(WebDAV内)" "${DST_PATH:-$DST_PATH_DEFAULT}")"
  TMP_DIR="$(ask_default "本地临时目录" "${TMP_DIR:-$TMP_DIR_DEFAULT}")"
  MIN_FREE_PERCENT="$(ask_default "最低剩余空间百分比" "${MIN_FREE_PERCENT:-$MIN_FREE_PERCENT_DEFAULT}")"

  save_config
  info "配置已保存: $CONFIG_FILE"
}

########################################
# rclone remote
########################################

install_deps() {
  need_cmd bash
  need_cmd rclone
  need_cmd awk
  need_cmd df
  need_cmd find
  need_cmd stat
  need_cmd mkdir
  need_cmd rm
  need_cmd sed
  need_cmd grep
  need_cmd head
  need_cmd tr
}

config_remote() {
  info "配置 rclone remote: $REMOTE_NAME"

  rclone config delete "$REMOTE_NAME" >/dev/null 2>&1 || true
  rclone config create "$REMOTE_NAME" webdav \
    url="$WEBDAV_URL" \
    vendor="other" \
    user="$WEBDAV_USER" \
    pass="$(rclone obscure "$WEBDAV_PASS")" >/dev/null

  rclone lsd "${REMOTE_NAME}:" >/dev/null 2>&1 || die "WebDAV 连接失败，请检查 URL/用户名/密码"
  info "WebDAV 连接测试通过"
}

rclone_base_args() {
  echo \
    --transfers="$RCLONE_TRANSFERS" \
    --checkers="$RCLONE_CHECKERS" \
    --retries="$RCLONE_RETRIES" \
    --low-level-retries="$RCLONE_LOW_LEVEL_RETRIES" \
    --timeout="$RCLONE_TIMEOUT" \
    --contimeout="$RCLONE_CONTIMEOUT" \
    --log-level=INFO
}

########################################
# 空间检查
########################################

check_free_space() {
  local line total used avail usep freep

  run_root mkdir -p "$TMP_DIR"

  line="$(df -P "$TMP_DIR" | awk 'NR==2 {print $2" "$3" "$4" "$5}')"
  [[ -n "$line" ]] || die "无法获取磁盘空间"

  total="$(awk '{print $1}' <<<"$line")"
  used="$(awk '{print $2}' <<<"$line")"
  avail="$(awk '{print $3}' <<<"$line")"
  usep="$(awk '{print $4}' <<<"$line" | tr -d '%')"
  freep=$((100 - usep))

  info "磁盘总空间(KB): $total"
  info "磁盘已用(KB): $used"
  info "磁盘剩余(KB): $avail"
  info "磁盘剩余比例: ${freep}%"

  if (( freep < MIN_FREE_PERCENT )); then
    die "剩余空间低于 ${MIN_FREE_PERCENT}% ，退出"
  fi
}

########################################
# 远端文件信息
########################################

remote_file_exists() {
  local remote_file="$1"
  rclone lsf "$remote_file" --files-only >/dev/null 2>&1
}

remote_file_size() {
  local remote_file="$1"
  local out
  out="$(rclone size "$remote_file" 2>/dev/null || true)"
  awk -F': ' '/Total size/ {print $2}' <<<"$out" | awk '{print $1}' | head -n1
}

local_file_size() {
  local local_file="$1"
  stat -c '%s' "$local_file" 2>/dev/null || echo ""
}

########################################
# 列出源文件
########################################

list_source_files() {
  local src_remote="${REMOTE_NAME}:${SRC_PATH}"
  rclone lsf "$src_remote" -R --files-only
}

########################################
# 单文件下载+上传
########################################

download_one() {
  local rel="$1"
  local src_remote="${REMOTE_NAME}:${SRC_PATH}/${rel}"
  local local_tmp="$TMP_DIR/$rel"
  local local_dir
  local_dir="$(dirname "$local_tmp")"

  run_root mkdir -p "$local_dir"

  info "下载远端文件 -> 本地临时: $rel"
  rclone copyto "$src_remote" "$local_tmp" $(rclone_base_args)
}

upload_one() {
  local rel="$1"
  local local_tmp="$TMP_DIR/$rel"
  local dst_remote="${REMOTE_NAME}:${DST_PATH}/${rel}"

  info "上传本地临时 -> 目标远端: $rel"
  rclone copyto "$local_tmp" "$dst_remote" $(rclone_base_args)
}

cleanup_local_file() {
  local rel="$1"
  local local_tmp="$TMP_DIR/$rel"
  rm -f "$local_tmp" 2>/dev/null || true
  find "$TMP_DIR" -type d -empty -delete 2>/dev/null || true
}

########################################
# 查重
# 目标同路径文件已存在，且大小相同 => 跳过
########################################

should_skip_file() {
  local rel="$1"
  local src_remote="${REMOTE_NAME}:${SRC_PATH}/${rel}"
  local dst_remote="${REMOTE_NAME}:${DST_PATH}/${rel}"
  local src_size dst_size

  if ! remote_file_exists "$dst_remote"; then
    return 1
  fi

  src_size="$(remote_file_size "$src_remote" || true)"
  dst_size="$(remote_file_size "$dst_remote" || true)"

  if [[ -n "${src_size:-}" && -n "${dst_size:-}" && "$src_size" == "$dst_size" ]]; then
    info "重复文件，跳过: $rel"
    return 0
  fi

  warn "目标存在同名文件但大小不同，将覆盖: $rel"
  return 1
}

########################################
# 主任务
########################################

run_job() {
  local total=0 success=0 skip=0 fail=0
  local rel local_tmp downloaded_size

  run_root mkdir -p "$TMP_DIR"

  info "开始扫描源目录: ${REMOTE_NAME}:${SRC_PATH}"
  info "目标目录: ${REMOTE_NAME}:${DST_PATH}"
  info "本地临时目录: $TMP_DIR"

  while IFS= read -r rel; do
    [[ -n "${rel:-}" ]] || continue
    ((total+=1))

    info "----------------------------------------"
    info "处理文件: $rel"

    check_free_space

    if should_skip_file "$rel"; then
      ((skip+=1))
      continue
    fi

    local_tmp="$TMP_DIR/$rel"
    cleanup_local_file "$rel"

    if ! download_one "$rel"; then
      err "下载失败: $rel"
      cleanup_local_file "$rel"
      ((fail+=1))
      continue
    fi

    downloaded_size="$(local_file_size "$local_tmp")"
    if [[ -z "${downloaded_size:-}" || "$downloaded_size" == "0" ]]; then
      err "下载后本地文件无效或为 0B: $rel"
      cleanup_local_file "$rel"
      ((fail+=1))
      continue
    fi

    check_free_space

    if ! upload_one "$rel"; then
      err "上传失败: $rel"
      cleanup_local_file "$rel"
      ((fail+=1))
      continue
    fi

    cleanup_local_file "$rel"
    info "完成: $rel"
    ((success+=1))

  done < <(list_source_files)

  info "----------------------------------------"
  info "任务完成：总计=$total 成功=$success 跳过=$skip 失败=$fail"

  rm -f "$PID_FILE" 2>/dev/null || true
}

########################################
# 命令
########################################

install_cmd() {
  ensure_state_dir
  load_config
  install_deps
  config_interactive
  load_config
  config_remote
  info "安装完成"
  info "接下来可执行：start / stop / restart / status / reconfig / uninstall"
}

start_cmd() {
  ensure_state_dir
  load_config
  install_deps
  config_remote

  if [[ -f "$PID_FILE" ]]; then
    local oldpid
    oldpid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_pid_alive "$oldpid"; then
      die "任务已在运行中，PID=$oldpid"
    else
      rm -f "$PID_FILE"
    fi
  fi

  (
    run_job
  ) >>"$LOG_FILE" 2>&1 &

  echo $! > "$PID_FILE"
  info "后台任务已启动，PID=$(cat "$PID_FILE")"
  info "日志文件: $LOG_FILE"
}

stop_cmd() {
  ensure_state_dir

  if [[ ! -f "$PID_FILE" ]]; then
    warn "没有运行中的任务"
    return 0
  fi

  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"

  if is_pid_alive "$pid"; then
    info "停止任务 PID=$pid"
    kill "$pid" 2>/dev/null || true
    sleep 1
    is_pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true
  else
    warn "PID 文件存在，但进程已退出"
  fi

  rm -f "$PID_FILE"
  info "任务已停止"

  if [[ -d "$TMP_DIR" ]]; then
    warn "保留本地临时目录: $TMP_DIR"
    warn "如需清理可手动执行: rm -rf '$TMP_DIR'"
  fi
}

restart_cmd() {
  stop_cmd || true
  sleep 1
  start_cmd
}

status_cmd() {
  ensure_state_dir
  load_config

  echo
  echo "========= 状态 ========="
  echo "配置文件: $CONFIG_FILE"
  echo "日志文件: $LOG_FILE"
  echo "临时目录: $TMP_DIR"
  echo "源路径: ${REMOTE_NAME}:${SRC_PATH}"
  echo "目标路径: ${REMOTE_NAME}:${DST_PATH}"
  echo

  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_pid_alive "$pid"; then
      echo "[任务] 运行中 PID=$pid"
    else
      echo "[任务] PID 文件存在，但进程已退出"
    fi
  else
    echo "[任务] 未运行"
  fi

  echo "========================"
}

reconfig_cmd() {
  ensure_state_dir
  load_config
  config_interactive
  load_config
  config_remote
  info "重配置完成"
}

uninstall_cmd() {
  stop_cmd || true
  rm -f "$CONFIG_FILE" "$PID_FILE"
  warn "已删除配置和状态文件"
  warn "日志文件保留: $LOG_FILE"
  warn "临时目录保留: $TMP_DIR"
}

usage() {
  cat <<EOF
用法: $0 <命令>

命令:
  install      初始化配置
  start        后台开始逐文件下载/上传
  stop         停止当前任务
  restart      重启任务
  status       查看状态
  reconfig     重新配置
  uninstall    删除配置和状态文件

说明:
  1. 不使用 systemd
  2. 不需要 mount，直接使用 rclone copyto
  5. 逐个文件处理，处理完即删除本地临时文件
  6. 保留子目录结构
  7. 目标同路径同大小文件直接跳过
  8. 本地剩余空间低于 ${MIN_FREE_PERCENT_DEFAULT}% 直接退出
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    install) install_cmd ;;
    start) start_cmd ;;
    stop) stop_cmd ;;
    restart) restart_cmd ;;
    status) status_cmd ;;
    reconfig) reconfig_cmd ;;
    uninstall) uninstall_cmd ;;
    -h|--help|"") usage ;;
    *) die "未知命令: $cmd" ;;
  esac
}

main "$@"
