sudo tee /bin/astr > /dev/null <<'EOF'
#!/bin/bash

set -e

APP_NAME="AstrBot"
APP_DIR="/root/AstrBot"
VENV_DIR="$APP_DIR/.venv"
PYTHON_BIN="$VENV_DIR/bin/python"
PIP_BIN="$VENV_DIR/bin/pip"
MAIN_FILE="$APP_DIR/main.py"
SERVICE_NAME="astrbot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_LINES=100

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 权限运行，例如：sudo astr $1"
        exit 1
    fi
}

check_app_dir() {
    if [ ! -d "$APP_DIR" ]; then
        error "项目目录不存在：$APP_DIR"
        exit 1
    fi

    if [ ! -f "$MAIN_FILE" ]; then
        error "主程序不存在：$MAIN_FILE"
        exit 1
    fi
}

install_system_deps() {
    info "安装系统依赖..."

    if command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y python3 python3-venv python3-pip python3-dev git build-essential
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 python3-pip python3-devel git gcc gcc-c++ make
    elif command -v yum >/dev/null 2>&1; then
        yum install -y python3 python3-pip python3-devel git gcc gcc-c++ make
    else
        warn "未识别的包管理器，请手动安装 python3 python3-venv python3-pip git gcc make"
    fi
}

create_venv() {
    check_app_dir

    info "创建 Python 虚拟环境..."

    if [ -d "$VENV_DIR" ]; then
        warn "检测到已有虚拟环境：$VENV_DIR"
        read -p "是否重建虚拟环境？[y/N]: " choice
        choice=${choice:-N}

        if [[ "$choice" =~ ^[Yy]$ ]]; then
            rm -rf "$VENV_DIR"
            python3 -m venv "$VENV_DIR"
        else
            info "保留现有虚拟环境"
        fi
    else
        python3 -m venv "$VENV_DIR"
    fi

    if [ ! -x "$PYTHON_BIN" ]; then
        error "虚拟环境创建失败：$PYTHON_BIN 不存在"
        exit 1
    fi

    info "升级 pip setuptools wheel..."
    "$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
    "$PYTHON_BIN" -m pip install --upgrade pip setuptools wheel

    if [ -f "$APP_DIR/requirements.txt" ]; then
        info "安装 requirements.txt 依赖..."
        "$PIP_BIN" install -r "$APP_DIR/requirements.txt"
    else
        warn "未找到 requirements.txt，跳过依赖安装"
    fi

    success "Python 环境安装完成"
}

create_service() {
    info "创建 systemd 服务：$SERVICE_NAME"

    cat > "$SERVICE_FILE" <<SERVICE_EOF
[Unit]
Description=AstrBot Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$PYTHON_BIN $MAIN_FILE
Restart=always
RestartSec=5
User=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"

    success "systemd 服务创建完成：$SERVICE_FILE"
}

install_app() {
    check_root
    check_app_dir
    install_system_deps
    create_venv
    create_service

    success "$APP_NAME 安装完成"
    echo ""
    echo "你现在可以使用："
    echo "  astr start      启动"
    echo "  astr stop       停止"
    echo "  astr status     查看状态"
    echo "  astr log        查看日志"
    echo "  astr update     更新"
    echo "  astr uninstall  卸载"
}

start_app() {
    check_root

    if [ ! -f "$SERVICE_FILE" ]; then
        error "服务不存在，请先执行：astr install"
        exit 1
    fi

    info "启动 $APP_NAME..."
    systemctl start "$SERVICE_NAME"
    success "$APP_NAME 已启动"
    systemctl status "$SERVICE_NAME" --no-pager
}

stop_app() {
    check_root

    info "停止 $APP_NAME..."
    systemctl stop "$SERVICE_NAME" || true
    success "$APP_NAME 已停止"
}

restart_app() {
    check_root

    info "重启 $APP_NAME..."
    systemctl restart "$SERVICE_NAME"
    success "$APP_NAME 已重启"
    systemctl status "$SERVICE_NAME" --no-pager
}

status_app() {
    if [ ! -f "$SERVICE_FILE" ]; then
        warn "systemd 服务不存在：$SERVICE_FILE"
        echo "请先执行：astr install"
        exit 1
    fi

    systemctl status "$SERVICE_NAME" --no-pager
}

log_app() {
    if [ ! -f "$SERVICE_FILE" ]; then
        warn "systemd 服务不存在：$SERVICE_FILE"
        echo "请先执行：astr install"
        exit 1
    fi

    journalctl -u "$SERVICE_NAME" -n "$LOG_LINES" -f
}

update_app() {
    check_root
    check_app_dir

    info "开始更新 $APP_NAME..."

    local was_active="no"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        was_active="yes"
        info "检测到服务正在运行，先停止服务..."
        systemctl stop "$SERVICE_NAME"
    fi

    cd "$APP_DIR"

    if [ -d "$APP_DIR/.git" ]; then
        info "拉取 Git 更新..."
        git pull
    else
        warn "当前目录不是 Git 仓库，跳过 git pull"
    fi

    if [ ! -x "$PYTHON_BIN" ]; then
        warn "虚拟环境不存在或损坏，重新创建..."
        rm -rf "$VENV_DIR"
        python3 -m venv "$VENV_DIR"
    fi

    info "更新 pip..."
    "$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
    "$PYTHON_BIN" -m pip install --upgrade pip setuptools wheel

    if [ -f "$APP_DIR/requirements.txt" ]; then
        info "更新 Python 依赖..."
        "$PIP_BIN" install -r "$APP_DIR/requirements.txt" --upgrade
    fi

    systemctl daemon-reload

    if [ "$was_active" = "yes" ]; then
        info "恢复启动服务..."
        systemctl start "$SERVICE_NAME"
    fi

    success "$APP_NAME 更新完成"

    if [ "$was_active" = "yes" ]; then
        systemctl status "$SERVICE_NAME" --no-pager
    fi
}

uninstall_app() {
    check_root

    echo -e "${YELLOW}警告：即将卸载 $APP_NAME 服务管理配置${NC}"
    echo ""
    echo "将会执行："
    echo "  1. 停止 $SERVICE_NAME 服务"
    echo "  2. 禁用开机自启"
    echo "  3. 删除 systemd 服务文件"
    echo "  4. 可选择删除虚拟环境 .venv"
    echo "  5. 可选择删除 /bin/astr 命令"
    echo ""
    echo "默认不会删除项目源码目录：$APP_DIR"
    echo ""

    read -p "确定继续卸载？[y/N]: " confirm
    confirm=${confirm:-N}

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消卸载"
        exit 0
    fi

    info "停止服务..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    info "禁用服务..."
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    if [ -f "$SERVICE_FILE" ]; then
        rm -f "$SERVICE_FILE"
        success "已删除服务文件：$SERVICE_FILE"
    fi

    systemctl daemon-reload

    if [ -d "$VENV_DIR" ]; then
        read -p "是否删除虚拟环境 $VENV_DIR？[y/N]: " del_venv
        del_venv=${del_venv:-N}

        if [[ "$del_venv" =~ ^[Yy]$ ]]; then
            rm -rf "$VENV_DIR"
            success "已删除虚拟环境"
        fi
    fi

    read -p "是否删除 /bin/astr 命令本身？[y/N]: " del_cmd
    del_cmd=${del_cmd:-N}

    if [[ "$del_cmd" =~ ^[Yy]$ ]]; then
        rm -f /bin/astr
        success "已删除 /bin/astr"
        exit 0
    fi

    success "$APP_NAME 卸载完成"
}

show_help() {
    echo "用法：astr {install|start|stop|restart|status|log|update|uninstall}"
    echo ""
    echo "命令："
    echo "  astr install     安装依赖、创建虚拟环境、创建 systemd 服务"
    echo "  astr start       启动 AstrBot"
    echo "  astr stop        停止 AstrBot"
    echo "  astr restart     重启 AstrBot"
    echo "  astr status      查看运行状态"
    echo "  astr log         查看实时日志"
    echo "  astr update      拉取代码并更新依赖"
    echo "  astr uninstall   卸载服务配置"
    echo ""
    echo "当前配置："
    echo "  项目目录：$APP_DIR"
    echo "  虚拟环境：$VENV_DIR"
    echo "  服务名称：$SERVICE_NAME"
}

case "$1" in
    install)
        install_app
        ;;
    start)
        start_app
        ;;
    stop)
        stop_app
        ;;
    restart)
        restart_app
        ;;
    status)
        status_app
        ;;
    log)
        log_app
        ;;
    update)
        update_app
        ;;
    uninstall)
        uninstall_app
        ;;
    help|-h|--help|"")
        show_help
        ;;
    *)
        error "未知命令：$1"
        show_help
        exit 1
        ;;
esac
EOF

sudo chmod +x /bin/astr