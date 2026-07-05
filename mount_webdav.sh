#!/usr/bin/env bash
set -euo pipefail

# ========= 可改默认值 =========
RCLONE_BIN="${RCLONE_BIN:-$(command -v rclone || true)}"
REMOTE_NAME="${REMOTE_NAME:-webdav_remote}"
MOUNT_DIR="${MOUNT_DIR:-/mnt/webdav}"
CACHE_DIR="${CACHE_DIR:-/var/cache/rclone-webdav}"
SERVICE_NAME="${SERVICE_NAME:-rclone-webdav.service}"
SERVICE_DIR="${SERVICE_DIR:-/etc/systemd/system}"
SERVICE_FILE="${SERVICE_FILE:-${SERVICE_DIR}/${SERVICE_NAME}}"

# ========= 工具 =========
info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
abort() { error "$*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

run_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    need_cmd sudo || abort "需要 sudo 或 root 权限"
    sudo "$@"
  fi
}

require_systemd() {
  need_cmd systemctl || abort "当前系统非 systemd，无法管理服务"
}

# ========= 用户与配置路径 =========
detect_run_user() {
  # 如果是 sudo 进入脚本，优先用原用户；否则当前用户
  if [[ -n "${SUDO_USER:-}" ]]; then
    echo "$SUDO_USER"
  else
    id -un
  fi
}

detect_home_of_user() {
  local u="$1"
  getent passwd "$u" | awk -F: '{print $6}'
}

run_as_user() {
  local user="$1"
  shift

  if [[ "$(id -u "$user")" -eq "$(id -u)" ]]; then
    "$@"
  elif need_cmd sudo; then
    sudo -H -u "$user" "$@"
  elif need_cmd runuser; then
    runuser -u "$user" -- "$@"
  else
    abort "需要 sudo 或 runuser 才能以 ${user} 执行命令"
  fi
}

detect_rclone_conf_path() {
  local run_user="${1:-$(detect_run_user)}"
  local conf

  conf="$(run_as_user "$run_user" rclone config file 2>/dev/null | awk -F': ' '/Configuration file is stored at:/ {print $2}' || true)"
  if [[ -n "${conf:-}" ]]; then
    echo "$conf"
    return 0
  fi

  local run_home
  run_home="$(detect_home_of_user "$run_user")"
  [[ -z "${run_home:-}" ]] && run_home="$HOME"
  echo "${run_home}/.config/rclone/rclone.conf"
}

detect_fusermount_bin() {
  if need_cmd fusermount3; then
    command -v fusermount3
  elif need_cmd fusermount; then
    command -v fusermount
  elif [[ -x /bin/fusermount ]]; then
    echo /bin/fusermount
  else
    abort "找不到 fusermount3/fusermount"
  fi
}

# ========= 安装 =========
install_rclone() {
  if need_cmd rclone; then
    return 0
  fi

  info "未检测到 rclone，开始安装..."
  if need_cmd apt-get; then
    run_root apt-get update -y
    run_root apt-get install -y rclone fuse3
  elif need_cmd dnf; then
    run_root dnf install -y rclone fuse3
  elif need_cmd yum; then
    run_root yum install -y epel-release || true
    run_root yum install -y rclone fuse3
  elif need_cmd pacman; then
    run_root pacman -Sy --noconfirm rclone fuse3
  else
    abort "不支持的包管理器，请手动安装 rclone + fuse3"
  fi
}

check_fuse() {
  [[ -e /dev/fuse ]] || abort "/dev/fuse 不存在，请确认已启用 FUSE"
  if ! grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null; then
    warn "/etc/fuse.conf 未开启 user_allow_other，正在添加..."
    run_root sh -c "echo 'user_allow_other' >> /etc/fuse.conf"
  fi
}

# ========= remote 配置 =========
config_remote() {
  local run_user conf_path
  run_user="$(detect_run_user)"
  conf_path="$(detect_rclone_conf_path "$run_user")"

  info "开始配置 WebDAV remote: ${REMOTE_NAME}"
  info "配置用户: ${run_user}"
  info "配置文件: ${conf_path}"
  read -r -p "WebDAV URL (如: http://127.0.0.1:5244/dav): " WEBDAV_URL
  read -r -p "vendor [other/nextcloud/owncloud/sharepoint] (默认other): " WEBDAV_VENDOR
  [[ -z "${WEBDAV_VENDOR:-}" ]] && WEBDAV_VENDOR="other"
  read -r -p "用户名: " WEBDAV_USER
  read -r -s -p "密码: " WEBDAV_PASS; echo

  [[ -n "${WEBDAV_URL:-}" && -n "${WEBDAV_USER:-}" && -n "${WEBDAV_PASS:-}" ]] || abort "URL/用户名/密码不能为空"

  run_as_user "$run_user" mkdir -p "$(dirname "$conf_path")"
  run_as_user "$run_user" rclone --config "$conf_path" config delete "$REMOTE_NAME" >/dev/null 2>&1 || true
  run_as_user "$run_user" rclone --config "$conf_path" config create "$REMOTE_NAME" webdav \
    url="$WEBDAV_URL" \
    vendor="$WEBDAV_VENDOR" \
    user="$WEBDAV_USER" \
    pass="$(run_as_user "$run_user" rclone obscure "$WEBDAV_PASS")" >/dev/null

  info "remote 已创建: $REMOTE_NAME"
  run_as_user "$run_user" rclone --config "$conf_path" lsd "${REMOTE_NAME}:" >/dev/null 2>&1 || abort "remote 连接测试失败，请检查参数"
  info "remote 连接测试通过"
}

check_remote_exists() {
  local conf_path="$1"
  local run_user="${2:-$(detect_run_user)}"
  run_as_user "$run_user" rclone --config "$conf_path" listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$" \
    || abort "在配置文件 $conf_path 中未找到 remote: ${REMOTE_NAME}"
}

# ========= 服务 =========
write_service() {
  local run_user run_group run_home conf_path fusermount_bin
  local tmp_service
  run_user="$(detect_run_user)"
  run_group="$(id -gn "$run_user")"
  run_home="$(detect_home_of_user "$run_user")"
  [[ -z "${run_home:-}" ]] && run_home="$HOME"

  conf_path="$(detect_rclone_conf_path "$run_user")"
  fusermount_bin="$(detect_fusermount_bin)"

  [[ -n "${RCLONE_BIN:-}" ]] || RCLONE_BIN="$(command -v rclone || true)"
  [[ -x "${RCLONE_BIN:-}" ]] || abort "找不到 rclone 可执行文件"

  # 提前检查 remote 是否在这个 conf 里，避免服务启动后才报错
  check_remote_exists "$conf_path" "$run_user"

  run_root mkdir -p "$MOUNT_DIR" "$CACHE_DIR"
  run_root chown -R "$run_user:$run_group" "$MOUNT_DIR" "$CACHE_DIR"

  tmp_service="$(mktemp)"
  cat > "$tmp_service" <<EOF
[Unit]
Description=Rclone WebDAV Mount
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
Group=${run_group}
Environment=HOME=${run_home}
ExecStart=${RCLONE_BIN} mount ${REMOTE_NAME}:/ ${MOUNT_DIR} \\
  --config=${conf_path} \\
  --umask=002 \\
  --allow-other \\
  --dir-cache-time=30s \\
  --vfs-cache-mode=writes \\
  --vfs-cache-max-age=12h \\
  --vfs-cache-max-size=20G \\
  --cache-dir=${CACHE_DIR} \\
  --buffer-size=32M \\
  --log-level=INFO
ExecStop=${fusermount_bin} -uz ${MOUNT_DIR}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  run_root install -m 0644 "$tmp_service" "$SERVICE_FILE" || {
    rm -f "$tmp_service"
    abort "写入服务文件失败: $SERVICE_FILE"
  }
  rm -f "$tmp_service"

  run_root systemctl daemon-reload
  info "服务文件已写入: $SERVICE_FILE"
  info "运行用户: $run_user"
  info "配置文件: $conf_path"
  info "卸载命令: $fusermount_bin"
}

start_service() {
  run_root systemctl enable "$SERVICE_NAME"
  run_root systemctl restart "$SERVICE_NAME"
  sleep 2
  if ! mountpoint -q "$MOUNT_DIR"; then
    warn "挂载未成功，输出最近日志："
    run_root journalctl -u "$SERVICE_NAME" -n 60 --no-pager || true
    abort "挂载失败：$MOUNT_DIR 不是挂载点"
  fi
  info "挂载成功: $MOUNT_DIR"
}

stop_service() {
  local fusermount_bin
  run_root systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  if mountpoint -q "$MOUNT_DIR"; then
    fusermount_bin="$(detect_fusermount_bin)"
    run_root "$fusermount_bin" -uz "$MOUNT_DIR" || true
  fi
  info "已停止并卸载"
}

status_service() {
  run_root systemctl status "$SERVICE_NAME" --no-pager -l
}

logs_service() {
  local n="${1:-200}"
  run_root journalctl -u "$SERVICE_NAME" -n "$n" -f --no-pager
}

restart_service() {
  run_root systemctl restart "$SERVICE_NAME"
  sleep 1
  status_service
}

uninstall_service() {
  stop_service || true
  run_root systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  run_root rm -f "$SERVICE_FILE"
  run_root systemctl daemon-reload
  info "已卸载服务（保留 rclone 配置与缓存目录）"
}

tip_cmd() {
  cat <<EOF
建议把 aria2 下载目录设为：
  ${MOUNT_DIR}/downloads

并重启 aria2 服务使其生效。
注意：vfs-cache-mode=writes 会占用少量本地缓存（在 ${CACHE_DIR}）。
EOF
}

usage() {
  cat <<EOF
用法: $0 <命令>

命令:
  install      安装依赖 + 配置 remote + 生成并启动服务
  reconfig     重新配置 WebDAV remote
  start        启动挂载
  stop         停止并卸载
  restart      重启服务
  status       查看状态
  logs [N]     查看日志（默认200行）
  tip          显示 aria2 配置建议
  uninstall    删除服务（保留配置和缓存）

示例:
  $0 install
  $0 status
  $0 logs 100
EOF
}

main() {
  require_systemd
  local cmd="${1:-}"
  case "$cmd" in
    install)
      install_rclone
      check_fuse
      config_remote
      write_service
      start_service
      tip_cmd
      ;;
    reconfig)
      install_rclone
      config_remote
      write_service
      restart_service
      ;;
    start) start_service ;;
    stop) stop_service ;;
    restart) restart_service ;;
    status) status_service ;;
    logs) shift || true; logs_service "${1:-200}" ;;
    tip) tip_cmd ;;
    uninstall) uninstall_service ;;
    -h|--help|"") usage ;;
    *) abort "未知命令: $cmd" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
