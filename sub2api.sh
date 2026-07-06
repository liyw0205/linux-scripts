#!/usr/bin/env bash
# Sub2API 管理脚本（单文件备份版）
# 备份: 复制本文件即可
# 部署: bash /root/sub2api.sh deploy
# 或:   /root/sub2api.sh deploy

set -euo pipefail

APP_DIR="/root/sub2api-manual"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
MAIN_SERVICE="sub2api"
POSTGRES_CONTAINER="sub2api-postgres"
DB_USER="sub2api"
DB_NAME="sub2api"
SELF="${BASH_SOURCE[0]}"

usage() {
  cat <<'EOF'
用法:
  sub2api start                 启动 Sub2API 服务栈
  sub2api stop                  停止 Sub2API 服务栈
  sub2api status                查看容器状态
  sub2api log                   查看日志，可传 -f 持续跟随
  sub2api restart               重启 Sub2API 应用容器
  sub2api update                备份数据库、拉取最新镜像并重建应用容器
  sub2api deploy                将本脚本安装到系统命令 (默认 /usr/local/bin/sub2api)

目录: /root/sub2api-manual
EOF
}

die() {
  echo "sub2api: $*" >&2
  exit 1
}

compose() {
  docker compose --project-directory "$APP_DIR" -f "$COMPOSE_FILE" "$@"
}

require_stack() {
  [ -f "$COMPOSE_FILE" ] || die "compose file not found: $COMPOSE_FILE"
}

backup_database() {
  local ts backup_file
  ts="$(date '+%Y%m%d_%H%M%S')"
  backup_file="$APP_DIR/sub2api_backup_${ts}.sql"

  if docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CONTAINER"; then
    echo "Creating database backup: $backup_file"
    docker exec "$POSTGRES_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" > "$backup_file"
  else
    echo "Postgres container is not running; skipping database backup." >&2
  fi
}

deploy_sub2api() {
  local install_path="${SUB2API_INSTALL_PATH:-/usr/local/bin/sub2api}"
  local source_path="${SELF}"

  if [[ ! -f "${source_path}" ]]; then
    echo "无法定位脚本自身: ${source_path}" >&2
    return 1
  fi

  install -m 755 "${source_path}" "${install_path}"
  echo "已部署到: ${install_path}"
  echo "可直接使用: sub2api <command>"
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
    backup_database
    compose pull "$MAIN_SERVICE"
    compose up -d "$MAIN_SERVICE"
    compose ps
    ;;
  deploy|self-install)
    deploy_sub2api
    ;;
  help|-h|--help|"")
    usage
    ;;
  *)
    usage >&2
    die "unknown command: $cmd"
    ;;
esac
