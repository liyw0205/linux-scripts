#!/usr/bin/env bash
set -euo pipefail

########################################
# 路径与状态
########################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/webdav_copyto_relay.conf}"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/.webdav_copyto_relay}"
PID_FILE="$STATE_DIR/task.pid"
RCLONE_PID_FILE="$STATE_DIR/rclone.pid"
LOG_FILE="$STATE_DIR/relay.log"
STATS_FILE="$STATE_DIR/stats.env"
LIST_FILE="$STATE_DIR/file_list.txt"

########################################
# 默认配置
########################################

WEBDAV_URL_DEFAULT="http://127.0.0.1:5244/dav"
WEBDAV_USER_DEFAULT="admin"
WEBDAV_PASS_DEFAULT="root"
REMOTE_NAME_DEFAULT="webdav_relay_remote"

SRC_PATH_DEFAULT="gy/Hentai"
DST_PATH_DEFAULT="downloads"

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

info() {
  echo -e "\033[1;32m[INFO]\033[0m $*"
  echo "[INFO] $*" >> "$LOG_FILE"
}

warn() {
  echo -e "\033[1;33m[WARN]\033[0m $*"
  echo "[WARN] $*" >> "$LOG_FILE"
}

err() {
  echo -e "\033[1;31m[ERR ]\033[0m $*" >&2
  echo "[ERR ] $*" >> "$LOG_FILE"
}
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
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] && kill -0 "$pid" 2>/dev/null
}

read_pid_file() {
  local file="$1" pid=""
  [[ -f "$file" ]] || return 1
  pid="$(cat "$file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  echo "$pid"
}

remove_pid_file_if_matches() {
  local file="$1" expected="$2" actual=""
  actual="$(read_pid_file "$file" 2>/dev/null || true)"
  if [[ -n "$actual" && "$actual" == "$expected" ]]; then
    rm -f "$file" 2>/dev/null || true
  fi
}

stop_pid() {
  local pid="${1:-}" label="${2:-进程}"
  [[ -n "$pid" ]] || return 0
  is_pid_alive "$pid" || return 0

  warn "停止${label}: PID=$pid"
  kill "$pid" 2>/dev/null || true
  sleep 1
  is_pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true
}

stop_current_rclone() {
  local rclone_pid=""
  rclone_pid="$(read_pid_file "$RCLONE_PID_FILE" 2>/dev/null || true)"
  stop_pid "$rclone_pid" "当前 rclone 传输"
  rm -f "$RCLONE_PID_FILE" 2>/dev/null || true
}

format_kb_gb_mb() {
  local kb="${1:-0}"
  awk -v kb="$kb" 'BEGIN {
    gb = kb / 1024 / 1024
    mb = kb / 1024
    printf "%.2f GB (%.2f MB)", gb, mb
  }'
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

write_config_kv() {
  local key="$1" value="$2"
  printf '%s=%q\n' "$key" "$value"
}

encode_state_value() {
  local value="$1"
  value="${value//'%'/'%25'}"
  value="${value//$'\r'/'%0D'}"
  value="${value//$'\n'/'%0A'}"
  printf '%s' "$value"
}

decode_state_value() {
  local value="$1"
  value="${value//'%0A'/$'\n'}"
  value="${value//'%0D'/$'\r'}"
  value="${value//'%25'/'%'}"
  printf '%s' "$value"
}

write_state_kv() {
  local key="$1" value="$2"
  printf '%s=%s\n' "$key" "$(encode_state_value "$value")"
}

save_config() {
  {
    write_config_kv WEBDAV_URL "$WEBDAV_URL"
    write_config_kv WEBDAV_USER "$WEBDAV_USER"
    write_config_kv WEBDAV_PASS "$WEBDAV_PASS"
    write_config_kv REMOTE_NAME "$REMOTE_NAME"
    echo
    write_config_kv SRC_PATH "$SRC_PATH"
    write_config_kv DST_PATH "$DST_PATH"
    echo
    write_config_kv TMP_DIR "$TMP_DIR"
    write_config_kv MIN_FREE_PERCENT "$MIN_FREE_PERCENT"
    echo
    write_config_kv RCLONE_TRANSFERS "$RCLONE_TRANSFERS"
    write_config_kv RCLONE_CHECKERS "$RCLONE_CHECKERS"
    write_config_kv RCLONE_RETRIES "$RCLONE_RETRIES"
    write_config_kv RCLONE_LOW_LEVEL_RETRIES "$RCLONE_LOW_LEVEL_RETRIES"
    write_config_kv RCLONE_TIMEOUT "$RCLONE_TIMEOUT"
    write_config_kv RCLONE_CONTIMEOUT "$RCLONE_CONTIMEOUT"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
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
# 统计状态
########################################

init_stats() {
  TASK_STATUS="initialized"
  START_TIME="$(date '+%F %T')"
  END_TIME=""
  TOTAL="0"
  DONE="0"
  SUCCESS="0"
  SKIP="0"
  FAIL="0"
  OVERWRITE="0"
  CURRENT_FILE=""
  LAST_MESSAGE="任务已初始化"
  save_stats
}

load_stats() {
  TASK_STATUS="not_started"
  START_TIME=""
  END_TIME=""
  TOTAL="0"
  DONE="0"
  SUCCESS="0"
  SKIP="0"
  FAIL="0"
  OVERWRITE="0"
  CURRENT_FILE=""
  LAST_MESSAGE="暂无任务记录"

  if [[ -f "$STATS_FILE" ]]; then
    local key value
    while IFS='=' read -r key value; do
      value="$(decode_state_value "${value:-}")"
      case "$key" in
        TASK_STATUS) TASK_STATUS="$value" ;;
        START_TIME) START_TIME="$value" ;;
        END_TIME) END_TIME="$value" ;;
        TOTAL) TOTAL="$value" ;;
        DONE) DONE="$value" ;;
        SUCCESS) SUCCESS="$value" ;;
        SKIP) SKIP="$value" ;;
        FAIL) FAIL="$value" ;;
        OVERWRITE) OVERWRITE="$value" ;;
        CURRENT_FILE) CURRENT_FILE="$value" ;;
        LAST_MESSAGE) LAST_MESSAGE="$value" ;;
      esac
    done < "$STATS_FILE"
  fi
}

save_stats() {
  local tmp_file
  tmp_file="$(mktemp "${STATE_DIR}/.stats.env.XXXXXX")"
  {
    write_state_kv TASK_STATUS "${TASK_STATUS:-not_started}"
    write_state_kv START_TIME "${START_TIME:-}"
    write_state_kv END_TIME "${END_TIME:-}"
    write_state_kv TOTAL "${TOTAL:-0}"
    write_state_kv DONE "${DONE:-0}"
    write_state_kv SUCCESS "${SUCCESS:-0}"
    write_state_kv SKIP "${SKIP:-0}"
    write_state_kv FAIL "${FAIL:-0}"
    write_state_kv OVERWRITE "${OVERWRITE:-0}"
    write_state_kv CURRENT_FILE "${CURRENT_FILE:-}"
    write_state_kv LAST_MESSAGE "${LAST_MESSAGE:-}"
  } > "$tmp_file"
  mv "$tmp_file" "$STATS_FILE"
  chmod 600 "$STATS_FILE" 2>/dev/null || true
}

set_stats_field() {
  local key="$1" value="$2"
  load_stats
  case "$key" in
    TASK_STATUS) TASK_STATUS="$value" ;;
    START_TIME) START_TIME="$value" ;;
    END_TIME) END_TIME="$value" ;;
    TOTAL) TOTAL="$value" ;;
    DONE) DONE="$value" ;;
    SUCCESS) SUCCESS="$value" ;;
    SKIP) SKIP="$value" ;;
    FAIL) FAIL="$value" ;;
    OVERWRITE) OVERWRITE="$value" ;;
    CURRENT_FILE) CURRENT_FILE="$value" ;;
    LAST_MESSAGE) LAST_MESSAGE="$value" ;;
    *) die "未知统计字段: $key" ;;
  esac
  save_stats
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
  need_cmd wc
  need_cmd date
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
# 远端路径检查
########################################

remote_dir_exists() {
  local remote_dir="$1"
  rclone lsf "$remote_dir" >/dev/null 2>&1
}

ensure_remote_paths_exist() {
  local src_remote="${REMOTE_NAME}:${SRC_PATH}"
  local dst_remote="${REMOTE_NAME}:${DST_PATH}"

  info "检查源路径是否存在: $src_remote"
  remote_dir_exists "$src_remote" || die "云端下载路径不存在: $src_remote"

  info "检查目标路径是否存在: $dst_remote"
  remote_dir_exists "$dst_remote" || die "云端上传路径不存在: $dst_remote"

  info "源路径和目标路径检查通过"
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

  info "磁盘总空间: $(format_kb_gb_mb "$total")"
  info "磁盘已用空间: $(format_kb_gb_mb "$used")"
  info "磁盘剩余空间: $(format_kb_gb_mb "$avail")"
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
  local out size

  out="$(rclone size --json "$remote_file" 2>/dev/null || true)"
  size="$(sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$out" | head -n1)"
  if [[ -n "${size:-}" ]]; then
    echo "$size"
    return 0
  fi

  out="$(rclone lsjson --stat "$remote_file" 2>/dev/null || true)"
  sed -n 's/.*"Size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$out" | head -n1
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

prepare_file_list() {
  ensure_remote_paths_exist

  : > "$LIST_FILE"
  list_source_files > "$LIST_FILE"

  local total_files
  total_files="$(grep -c . "$LIST_FILE" 2>/dev/null || true)"
  total_files="${total_files:-0}"

  load_stats
  TOTAL="$total_files"
  DONE="0"
  SUCCESS="0"
  SKIP="0"
  FAIL="0"
  OVERWRITE="0"
  CURRENT_FILE=""
  LAST_MESSAGE="文件列表已生成"
  save_stats

  info "已预获取全部文件列表，总文件数: $total_files"
}

########################################
# 单文件下载+上传
########################################

RCLONE_CHILD_PID=""

run_rclone_copyto() {
  rclone copyto "$@" $(rclone_base_args) &
  RCLONE_CHILD_PID="$!"
  echo "$RCLONE_CHILD_PID" > "$RCLONE_PID_FILE"

  local status=0
  wait "$RCLONE_CHILD_PID" || status=$?
  rm -f "$RCLONE_PID_FILE" 2>/dev/null || true
  RCLONE_CHILD_PID=""
  return "$status"
}

download_one() {
  local rel="$1"
  local src_remote="${REMOTE_NAME}:${SRC_PATH}/${rel}"
  local local_tmp="$TMP_DIR/$rel"
  local local_dir
  local_dir="$(dirname "$local_tmp")"

  run_root mkdir -p "$local_dir"

  info "下载远端文件 -> 本地临时: $rel"
  run_rclone_copyto "$src_remote" "$local_tmp"
}

upload_one() {
  local rel="$1"
  local local_tmp="$TMP_DIR/$rel"
  local dst_remote="${REMOTE_NAME}:${DST_PATH}/${rel}"

  info "上传本地临时 -> 目标远端: $rel"
  run_rclone_copyto "$local_tmp" "$dst_remote"
}

cleanup_local_file() {
  local rel="$1"
  local local_tmp="$TMP_DIR/$rel"
  rm -f "$local_tmp" 2>/dev/null || true
  find "$TMP_DIR" -type d -empty -delete 2>/dev/null || true
}

########################################
# 查重/覆盖判断
# 目标同路径文件已存在，且大小相同 => 跳过
# 目标同路径文件已存在，但大小不同 => 记为覆盖
########################################

OVERWRITE_CURRENT=0

should_skip_file() {
  local rel="$1"
  local src_remote="${REMOTE_NAME}:${SRC_PATH}/${rel}"
  local dst_remote="${REMOTE_NAME}:${DST_PATH}/${rel}"
  local src_size dst_size

  OVERWRITE_CURRENT=0

  if ! remote_file_exists "$dst_remote"; then
    return 1
  fi

  src_size="$(remote_file_size "$src_remote" || true)"
  dst_size="$(remote_file_size "$dst_remote" || true)"

  if [[ -n "${src_size:-}" && -n "${dst_size:-}" && "$src_size" == "$dst_size" ]]; then
    info "重复文件，跳过: $rel"
    return 0
  fi

  OVERWRITE_CURRENT=1
  warn "目标存在同名文件但大小不同，将覆盖: $rel"
  return 1
}

########################################
# 主任务
########################################

run_job() {
  local total=0 success=0 skip=0 fail=0 overwrite=0
  local rel local_tmp downloaded_size
  local overwrite_this=0
  local worker_pid="${BASHPID:-$$}"

  trap '
    stop_current_rclone
    load_stats
    TASK_STATUS="stopped"
    END_TIME="$(date "+%F %T")"
    LAST_MESSAGE="任务已停止"
    CURRENT_FILE=""
    save_stats
    remove_pid_file_if_matches "'"$PID_FILE"'" "$worker_pid"
    rm -f "'"$RCLONE_PID_FILE"'" 2>/dev/null || true
    exit 1
  ' INT TERM

  [[ -f "$LIST_FILE" ]] || die "文件列表不存在，请重新 start"

  run_root mkdir -p "$TMP_DIR"

  load_stats
  total="${TOTAL:-0}"
  TASK_STATUS="running"
  START_TIME="$(date '+%F %T')"
  END_TIME=""
  DONE="0"
  SUCCESS="0"
  SKIP="0"
  FAIL="0"
  OVERWRITE="0"
  CURRENT_FILE=""
  LAST_MESSAGE="任务开始执行"
  save_stats

  info "开始扫描执行"
  info "源目录: ${REMOTE_NAME}:${SRC_PATH}"
  info "目标目录: ${REMOTE_NAME}:${DST_PATH}"
  info "本地临时目录: $TMP_DIR"
  info "本次任务总文件数: $total"

  while IFS= read -r rel; do
    [[ -n "${rel:-}" ]] || continue

    info "----------------------------------------"
    info "处理文件: $rel"

    load_stats
    CURRENT_FILE="$rel"
    LAST_MESSAGE="正在处理: $rel"
    save_stats

    check_free_space

    overwrite_this=0
    if should_skip_file "$rel"; then
      ((skip+=1))
      load_stats
      DONE=$((DONE + 1))
      SKIP="$skip"
      CURRENT_FILE="$rel"
      LAST_MESSAGE="已跳过: $rel"
      save_stats
      continue
    fi

    if (( OVERWRITE_CURRENT == 1 )); then
      overwrite_this=1
    fi

    local_tmp="$TMP_DIR/$rel"
    cleanup_local_file "$rel"

    if ! download_one "$rel"; then
      err "下载失败: $rel"
      cleanup_local_file "$rel"
      ((fail+=1))
      load_stats
      DONE=$((DONE + 1))
      FAIL="$fail"
      CURRENT_FILE="$rel"
      LAST_MESSAGE="下载失败: $rel"
      save_stats
      continue
    fi

    downloaded_size="$(local_file_size "$local_tmp")"
    if [[ -z "${downloaded_size:-}" || "$downloaded_size" == "0" ]]; then
      err "下载后本地文件无效或为 0B: $rel"
      cleanup_local_file "$rel"
      ((fail+=1))
      load_stats
      DONE=$((DONE + 1))
      FAIL="$fail"
      CURRENT_FILE="$rel"
      LAST_MESSAGE="下载后本地文件无效: $rel"
      save_stats
      continue
    fi

    check_free_space

    if ! upload_one "$rel"; then
      err "上传失败: $rel"
      cleanup_local_file "$rel"
      ((fail+=1))
      load_stats
      DONE=$((DONE + 1))
      FAIL="$fail"
      CURRENT_FILE="$rel"
      LAST_MESSAGE="上传失败: $rel"
      save_stats
      continue
    fi

    cleanup_local_file "$rel"
    info "完成: $rel"

    ((success+=1))
    if (( overwrite_this == 1 )); then
      ((overwrite+=1))
    fi

    load_stats
    DONE=$((DONE + 1))
    SUCCESS="$success"
    OVERWRITE="$overwrite"
    CURRENT_FILE="$rel"
    LAST_MESSAGE="已完成: $rel"
    save_stats

  done < "$LIST_FILE"

  info "----------------------------------------"
  info "任务完成：总计=$total 成功=$success 跳过=$skip 失败=$fail 覆盖=$overwrite"

  load_stats
  TASK_STATUS="finished"
  END_TIME="$(date '+%F %T')"
  CURRENT_FILE=""
  LAST_MESSAGE="任务完成"
  TOTAL="$total"
  DONE=$((success + skip + fail))
  SUCCESS="$success"
  SKIP="$skip"
  FAIL="$fail"
  OVERWRITE="$overwrite"
  save_stats

  remove_pid_file_if_matches "$PID_FILE" "$worker_pid"
  rm -f "$RCLONE_PID_FILE" 2>/dev/null || true
}

########################################
# 命令
########################################

install_cmd() {
  ensure_state_dir
  load_config
  install_deps
  init_stats
  config_interactive
  load_config
  config_remote
  ensure_remote_paths_exist
  info "安装完成"
  info "接下来可执行：start / stop / restart / status / reconfig / uninstall"
}

start_cmd() {
  ensure_state_dir
  load_config
  install_deps
  config_remote
  ensure_remote_paths_exist

  if [[ -f "$PID_FILE" ]]; then
    local oldpid
    oldpid="$(read_pid_file "$PID_FILE" 2>/dev/null || true)"
    if is_pid_alive "$oldpid"; then
      die "任务已在运行中，PID=$oldpid"
    else
      rm -f "$PID_FILE"
    fi
  fi

  init_stats
  prepare_file_list

  (
    echo "${BASHPID:-$$}" > "$PID_FILE"
    run_job
  ) </dev/null >/dev/null 2>>"$LOG_FILE" &
  local started_pid="$!" visible_pid=""
  for _ in {1..20}; do
    visible_pid="$(read_pid_file "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$visible_pid" ]] && break
    is_pid_alive "$started_pid" || break
    sleep 0.1
  done
  [[ -z "$visible_pid" ]] && visible_pid="$started_pid"
  info "后台任务已启动，PID=$visible_pid"
  info "日志文件: $LOG_FILE"
}

stop_cmd() {
  ensure_state_dir
  load_config

  if [[ ! -f "$PID_FILE" ]]; then
    warn "没有运行中的任务"
    load_stats
    TASK_STATUS="stopped"
    END_TIME="$(date '+%F %T')"
    LAST_MESSAGE="任务未运行"
    CURRENT_FILE=""
    save_stats
    return 0
  fi

  local pid
  pid="$(read_pid_file "$PID_FILE" 2>/dev/null || true)"

  if is_pid_alive "$pid"; then
    info "停止任务 PID=$pid"
    stop_current_rclone
    stop_pid "$pid" "后台任务"
  else
    warn "PID 文件存在，但进程已退出"
    stop_current_rclone
  fi

  rm -f "$PID_FILE" "$RCLONE_PID_FILE"

  load_stats
  TASK_STATUS="stopped"
  END_TIME="$(date '+%F %T')"
  LAST_MESSAGE="任务已停止"
  CURRENT_FILE=""
  save_stats

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
  load_stats

  local pid=""
  local progress_percent="0.00"
  local remaining="0"

  if [[ -f "$PID_FILE" ]]; then
    pid="$(read_pid_file "$PID_FILE" 2>/dev/null || true)"
  fi

  [[ "${TOTAL:-0}" =~ ^[0-9]+$ ]] || TOTAL="0"
  [[ "${DONE:-0}" =~ ^[0-9]+$ ]] || DONE="0"
  [[ "${SUCCESS:-0}" =~ ^[0-9]+$ ]] || SUCCESS="0"
  [[ "${SKIP:-0}" =~ ^[0-9]+$ ]] || SKIP="0"
  [[ "${FAIL:-0}" =~ ^[0-9]+$ ]] || FAIL="0"
  [[ "${OVERWRITE:-0}" =~ ^[0-9]+$ ]] || OVERWRITE="0"

  if [[ "${TOTAL:-0}" -gt 0 ]]; then
    progress_percent="$(awk -v d="${DONE:-0}" -v t="${TOTAL:-0}" 'BEGIN { printf "%.2f", (d/t)*100 }')"
    remaining=$(( TOTAL - DONE ))
  fi

  echo
  echo "========= 状态 ========="
  echo "配置文件: $CONFIG_FILE"
  echo "日志文件: $LOG_FILE"
  echo "临时目录: $TMP_DIR"
  echo "源路径: ${REMOTE_NAME}:${SRC_PATH}"
  echo "目标路径: ${REMOTE_NAME}:${DST_PATH}"
  echo

  if [[ -n "$pid" ]] && is_pid_alive "$pid"; then
    echo "[任务] 运行中 PID=$pid"
  elif [[ -f "$PID_FILE" ]]; then
    echo "[任务] PID 文件存在，但进程已退出"
  else
    echo "[任务] 未运行"
  fi

  echo "任务状态: ${TASK_STATUS:-not_started}"
  echo "开始时间: ${START_TIME:-}"
  echo "结束时间: ${END_TIME:-}"
  echo "当前文件: ${CURRENT_FILE:-}"
  echo "最后信息: ${LAST_MESSAGE:-}"
  echo
  echo "本次任务进度:"
  echo "  总数: ${TOTAL:-0}"
  echo "  已完成: ${DONE:-0}"
  echo "  成功: ${SUCCESS:-0}"
  echo "  跳过: ${SKIP:-0}"
  echo "  失败: ${FAIL:-0}"
  echo "  覆盖: ${OVERWRITE:-0}"
  echo "  剩余: ${remaining:-0}"
  echo "  进度: ${progress_percent}%"
  echo "========================"
}

reconfig_cmd() {
  ensure_state_dir
  load_config
  install_deps
  config_interactive
  load_config
  config_remote
  ensure_remote_paths_exist
  info "重配置完成"
}

uninstall_cmd() {
  stop_cmd || true
  rm -f "$CONFIG_FILE" "$PID_FILE" "$RCLONE_PID_FILE" "$STATS_FILE" "$LIST_FILE"
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
  status       查看状态与本次任务进度
  reconfig     重新配置
  uninstall    删除配置和状态文件

说明:
  1. 不使用 systemd
  2. 不需要 mount，直接使用 rclone copyto
  3. start 时先获取全部文件列表用于统计总数
  4. 云端源路径或目标路径不存在时直接退出
  5. 逐个文件处理，处理完即删除本地临时文件
  6. 保留子目录结构
  7. 目标同路径同大小文件直接跳过
  8. 目标同路径不同大小文件记为覆盖
  9. 本地剩余空间低于 ${MIN_FREE_PERCENT_DEFAULT}% 直接退出
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
