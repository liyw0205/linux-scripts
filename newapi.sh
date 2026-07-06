#!/usr/bin/env bash
# New API 管理脚本（单文件备份版）
# 备份: 复制本文件即可
# 部署: bash /root/newapi.sh deploy
# 或:   /root/newapi.sh deploy

set -euo pipefail

APP_DIR="/root/newapi-manual"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
MAIN_SERVICE="new-api"
DATA_DIR="$APP_DIR/data"
BACKUP_DIR="$APP_DIR/backups"
SELF="${BASH_SOURCE[0]}"

usage() {
  cat <<'EOF'
用法:
  newapi start                  启动 New API 服务栈
  newapi stop                   停止 New API 服务栈
  newapi status                 查看容器状态
  newapi log                    查看日志，可传 -f 持续跟随
  newapi restart                重启 New API 应用容器
  newapi update                 备份数据、拉取最新镜像并重建应用容器
  newapi deploy                 将本脚本安装到系统命令 (默认 /usr/local/bin/newapi)

目录: /root/newapi-manual
EOF
}

die() {
  echo "newapi: $*" >&2
  exit 1
}

compose() {
  docker compose --project-directory "$APP_DIR" -f "$COMPOSE_FILE" "$@"
}

require_stack() {
  [ -f "$COMPOSE_FILE" ] || die "compose file not found: $COMPOSE_FILE"
}

backup_data() {
  local ts backup_file
  ts="$(date '+%Y%m%d_%H%M%S')"
  mkdir -p "$BACKUP_DIR"
  backup_file="$BACKUP_DIR/newapi_backup_${ts}.tar.gz"

  if [ -d "$DATA_DIR" ]; then
    echo "Creating data backup: $backup_file"
    tar -czf "$backup_file" -C "$APP_DIR" data logs
  else
    echo "Data directory not found; skipping backup." >&2
  fi
}

deploy_newapi() {
  local install_path="${NEWAPI_INSTALL_PATH:-/usr/local/bin/newapi}"
  local source_path="${SELF}"

  if [[ ! -f "${source_path}" ]]; then
    echo "无法定位脚本自身: ${source_path}" >&2
    return 1
  fi

  install -m 755 "${source_path}" "${install_path}"
  echo "已部署到: ${install_path}"
  echo "可直接使用: newapi <command>"
}

cmd="${1:-}"
case "$cmd" in
  start|stop|status|log|logs|restart|update)
    require_stack
    ;;
esac

case "$cmd" in
  start)
    compose up -d
    ;;
  stop)
    compose stop
    ;;
  status)
    compose ps
    ;;
  log|logs)
    shift || true
    if [ "$#" -eq 0 ]; then
      compose logs --tail=200 "$MAIN_SERVICE"
    else
      compose logs --tail=200 "$@" "$MAIN_SERVICE"
    fi
    ;;
  restart)
    compose restart "$MAIN_SERVICE"
    ;;
  update)
    backup_data
    compose pull "$MAIN_SERVICE"
    compose up -d "$MAIN_SERVICE"
    compose ps
    ;;
  deploy|self-install)
    deploy_newapi
    ;;
  help|-h|--help|"")
    usage
    ;;
  *)
    usage >&2
    die "unknown command: $cmd"
    ;;
esac
