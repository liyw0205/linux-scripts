#!/usr/bin/env bash

# Mihomo Linux 一体化管理脚本
# 功能：
# 安装、卸载、启动、停止、重启、状态、日志
# 前端切换、订阅导入
# 修改 external-controller 管理端口
# 修改 HTTP 代理端口 port
# 修改 SOCKS5 代理端口 socks-port
# 启用/移除 SOCKS5 多端口组
# 自动代理组：AUTO / FALLBACK / LOAD-BALANCE
# Country.mmdb 自动检测、下载、修复

set -e

# =========================
# 基础配置
# =========================

MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.12}"

MIHOMO_DIR="/etc/mihomo"
MIHOMO_BIN_DIR="/opt/mihomo"
MIHOMO_BIN="$MIHOMO_BIN_DIR/mihomo"
CONFIG_FILE="$MIHOMO_DIR/config.yaml"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
UI_DIR="$MIHOMO_DIR/ui"
SUB_FILE="$MIHOMO_DIR/subscription.yaml"
COUNTRY_MMDB="$MIHOMO_DIR/Country.mmdb"
SOCKS5_GROUP_STATE="$MIHOMO_DIR/socks5_group.conf"

COUNTRY_MMDB_URL="${COUNTRY_MMDB_URL:-https://github.com/Dreamacro/maxmind-geoip/releases/latest/download/Country.mmdb}"

METACUBEXD_VERSION="${METACUBEXD_VERSION:-v1.189.0}"
METACUBEXD_DOWNLOAD_URL="${METACUBEXD_DOWNLOAD_URL:-https://github.com/MetaCubeX/metacubexd/releases/download/v1.189.0/compressed-dist.tgz}"

ZASHBOARD_VERSION="${ZASHBOARD_VERSION:-latest}"
ZASHBOARD_DOWNLOAD_URL="${ZASHBOARD_DOWNLOAD_URL:-https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip}"

DEFAULT_HTTP_PORT="7890"
DEFAULT_SOCKS_PORT="7891"
DEFAULT_CONTROLLER="0.0.0.0:9090"

HEALTH_CHECK_URL="${HEALTH_CHECK_URL:-http://www.gstatic.com/generate_204}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-300}"

# =========================
# 颜色
# =========================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# =========================
# 通用函数
# =========================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行，例如：sudo bash mihomo.sh"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev 2>&1
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

install_dependencies() {
    log_info "检查并安装依赖..."

    local os
    os="$(detect_os)"

    case "$os" in
        ubuntu|debian)
            apt-get update
            apt-get install -y curl wget unzip tar gzip file net-tools ca-certificates
            ;;
        centos|rhel|rocky|almalinux)
            if command_exists dnf; then
                dnf install -y curl wget unzip tar gzip file net-tools ca-certificates
            else
                yum install -y curl wget unzip tar gzip file net-tools ca-certificates
            fi
            ;;
        fedora)
            dnf install -y curl wget unzip tar gzip file net-tools ca-certificates
            ;;
        *)
            log_warn "未知系统，跳过自动依赖安装"
            log_warn "请确保已安装：curl wget unzip tar gzip file"
            ;;
    esac
}

detect_arch_file() {
    local arch
    arch="$(uname -m)"

    case "$arch" in
        x86_64|amd64)
            echo "mihomo-linux-amd64-compatible-${MIHOMO_VERSION}.gz"
            ;;
        aarch64|arm64)
            echo "mihomo-linux-arm64-${MIHOMO_VERSION}.gz"
            ;;
        armv7l|armv7)
            echo "mihomo-linux-armv7-${MIHOMO_VERSION}.gz"
            ;;
        *)
            log_error "不支持的架构：$arch"
            log_error "支持架构：x86_64 / aarch64 / arm64 / armv7l"
            exit 1
            ;;
    esac
}

get_github_mirrors() {
    echo "https://ghfast.top/"
    echo "https://gh.llkk.cc/"
    echo "https://gh-proxy.com/"
    echo "https://hub.gitmirror.com/"
    echo ""
}

download_file() {
    local original_url="$1"
    local output="$2"
    local description="${3:-$(basename "$output")}"

    local mirrors
    mapfile -t mirrors < <(get_github_mirrors)

    rm -f "$output"

    for mirror in "${mirrors[@]}"; do
        local url

        if [ -z "$mirror" ]; then
            url="$original_url"
            log_info "尝试原始地址下载：$description"
        else
            url="${mirror}${original_url}"
            log_info "尝试镜像下载：$mirror"
        fi

        for i in 1 2 3; do
            log_info "下载尝试 $i/3：$description"

            if curl -fL --connect-timeout 8 --max-time 180 -o "$output" "$url" 2>/dev/null; then
                if [ -f "$output" ]; then
                    local size
                    size="$(stat -c%s "$output" 2>/dev/null || echo 0)"
                    local type
                    type="$(file "$output" 2>/dev/null || echo unknown)"

                    if [ "$size" -lt 100 ]; then
                        log_warn "文件过小，可能下载失败：${size} bytes"
                        rm -f "$output"
                        continue
                    fi

                    if echo "$type" | grep -qiE "HTML|XML"; then
                        log_warn "下载到的是网页，不是目标文件：$type"
                        rm -f "$output"
                        continue
                    fi

                    log_success "下载成功：$output (${size} bytes)"
                    return 0
                fi
            fi

            sleep 1
        done
    done

    log_error "下载失败：$description"
    log_error "原始地址：$original_url"
    return 1
}

backup_file() {
    local file="$1"

    if [ -f "$file" ]; then
        local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup"
        log_info "已备份：$backup"
    fi
}

restart_if_running() {
    if systemctl is-active --quiet mihomo 2>/dev/null; then
        log_info "重启 Mihomo 服务..."
        systemctl restart mihomo
        log_success "Mihomo 服务已重启"
    fi
}

get_server_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

get_config_value() {
    local key="$1"

    if [ -f "$CONFIG_FILE" ]; then
        grep -E "^[[:space:]]*${key}:" "$CONFIG_FILE" | head -n1 | awk -F': ' '{print $2}' | tr -d '"'
    fi
}

get_controller_from_config() {
    local value
    value="$(get_config_value "external-controller")"
    echo "${value:-$DEFAULT_CONTROLLER}"
}

get_controller_port() {
    local controller
    controller="$(get_controller_from_config)"
    echo "$controller" | awk -F':' '{print $NF}'
}

get_http_port() {
    local value
    value="$(get_config_value "port")"
    echo "${value:-$DEFAULT_HTTP_PORT}"
}

get_socks_port() {
    local value
    value="$(get_config_value "socks-port")"
    echo "${value:-$DEFAULT_SOCKS_PORT}"
}

normalize_port_only() {
    local input="$1"
    input="$(echo "$input" | tr -d ' ')"

    if ! echo "$input" | grep -qE '^[0-9]+$'; then
        log_error "端口格式错误：$input"
        log_info "请输入纯数字端口，例如：7890"
        exit 1
    fi

    if [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then
        log_error "端口范围错误：$input"
        log_info "端口范围应为 1-65535"
        exit 1
    fi

    echo "$input"
}

normalize_controller() {
    local input="$1"
    input="$(echo "$input" | tr -d ' ')"

    if [ -z "$input" ]; then
        log_error "端口不能为空"
        exit 1
    fi

    if echo "$input" | grep -qE '^[0-9]+$'; then
        echo "0.0.0.0:${input}"
        return 0
    fi

    if echo "$input" | grep -qE '^:[0-9]+$'; then
        echo "0.0.0.0${input}"
        return 0
    fi

    if echo "$input" | grep -qE '^[^:]+:[0-9]+$'; then
        echo "$input"
        return 0
    fi

    log_error "管理端口格式错误：$input"
    log_info "正确示例：8899 / :8899 / 0.0.0.0:8899 / 127.0.0.1:8899"
    exit 1
}

ensure_config_exists() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_warn "配置文件不存在，将创建默认配置"
        create_default_config
    fi
}

# =========================
# Country.mmdb 管理
# =========================

check_country_mmdb() {
    if [ ! -f "$COUNTRY_MMDB" ]; then return 1; fi
    local size
    size="$(stat -c%s "$COUNTRY_MMDB" 2>/dev/null || echo 0)"
    [ "$size" -ge 100000 ] || return 1
    local type
    type="$(file "$COUNTRY_MMDB" 2>/dev/null || echo unknown)"
    echo "$type" | grep -qiE "HTML|XML|text|empty" && return 1
    return 0
}

download_country_mmdb() {
    check_root
    mkdir -p "$MIHOMO_DIR"

    if check_country_mmdb; then
        local size
        size="$(stat -c%s "$COUNTRY_MMDB" 2>/dev/null || echo 0)"
        log_success "Country.mmdb 正常：$COUNTRY_MMDB (${size} bytes)"
        return 0
    fi

    log_warn "Country.mmdb 不存在或无效，开始下载..."

    rm -f "$COUNTRY_MMDB" "$MIHOMO_DIR/country.mmdb" "$MIHOMO_DIR/geoip.metadb"

    if download_file "$COUNTRY_MMDB_URL" "$COUNTRY_MMDB" "Country.mmdb"; then
        chmod 644 "$COUNTRY_MMDB"
        if check_country_mmdb; then
            local size
            size="$(stat -c%s "$COUNTRY_MMDB" 2>/dev/null || echo 0)"
            log_success "Country.mmdb 下载完成：$COUNTRY_MMDB (${size} bytes)"
            return 0
        fi
    fi

    log_error "Country.mmdb 下载失败或文件无效"
    return 1
}

repair_mmdb() {
    check_root
    log_info "开始修复 Country.mmdb..."
    rm -f "$COUNTRY_MMDB" "$MIHOMO_DIR/country.mmdb" "$MIHOMO_DIR/geoip.metadb"
    download_country_mmdb
    test_and_restart
    log_success "Country.mmdb 修复完成"
}

# =========================
# SOCKS5 多端口组
# =========================

remove_socks5_group_blocks() {
    if [ -f "$CONFIG_FILE" ]; then
        sed -i '/MIHOMO SOCKS5 GROUPS BEGIN/,/MIHOMO SOCKS5 GROUPS END/d' "$CONFIG_FILE"
        sed -i '/MIHOMO SOCKS5 LISTENERS BEGIN/,/MIHOMO SOCKS5 LISTENERS END/d' "$CONFIG_FILE"
    fi
}

generate_socks5_blocks() {
    local count="$1"
    local base_port="$2"
    local output="$3"

    {
        echo "  # MIHOMO SOCKS5 GROUPS BEGIN"
        local i
        for ((i=1; i<=count; i++)); do
            local port=$((base_port + i))
            cat <<EOF
  - name: "SOCKS5-${port}"
    type: select
    proxies:
      - PROXY
      - AUTO
      - FALLBACK
      - LOAD-BALANCE
      - DIRECT
    use:
      - subscription

EOF
        done
        echo "  # MIHOMO SOCKS5 GROUPS END"
        echo ""
        echo "# MIHOMO SOCKS5 LISTENERS BEGIN"
        echo "listeners:"
        for ((i=1; i<=count; i++)); do
            local port=$((base_port + i))
            cat <<EOF
  - name: "SOCKS5-${port}"
    type: socks
    listen: 0.0.0.0
    port: ${port}
    proxy: "SOCKS5-${port}"
    udp: true

EOF
        done
        echo "# MIHOMO SOCKS5 LISTENERS END"
        echo ""
    } > "$output"
}

insert_blocks_before_rules() {
    local block_file="$1"
    local tmp_file
    tmp_file="$(mktemp)"

    awk -v block="$(cat "$block_file")" '
        BEGIN { inserted = 0 }
        /^[[:space:]]*rules:/ {
            if (inserted == 0) { print block; inserted = 1 }
        }
        { print }
        END {
            if (inserted == 0) {
                print ""
                print block
            }
        }
    ' "$CONFIG_FILE" > "$tmp_file"

    mv "$tmp_file" "$CONFIG_FILE"
}

enable_socks5_group() {
    check_root
    ensure_config_exists

    local count="${1:-}"
    if [ -z "$count" ]; then
        echo ""
        echo "当前主 SOCKS5 端口：$(get_socks_port)"
        read -r -p "请输入要新增的 SOCKS5 端口数量，例如 10：" count
    fi

    if ! echo "$count" | grep -qE '^[0-9]+$'; then
        log_error "数量格式错误：$count"
        exit 1
    fi

    if [ "$count" -lt 1 ] || [ "$count" -gt 100 ]; then
        log_error "数量范围错误：$count"
        log_info "建议范围：1-100"
        exit 1
    fi

    local base_port
    base_port="$(normalize_port_only "$(get_socks_port)")"

    local last_port
    last_port=$((base_port + count))

    if [ "$last_port" -gt 65535 ]; then
        log_error "端口超过 65535"
        exit 1
    fi

    backup_file "$CONFIG_FILE"
    remove_socks5_group_blocks

    if grep -qE '^[[:space:]]*listeners:' "$CONFIG_FILE"; then
        log_error "检测到 config.yaml 中已存在 listeners 配置"
        log_info "为了避免破坏你已有的配置，脚本暂停自动写入。"
        log_info "请先手动处理 listeners 后再启用 SOCKS5 多端口组。"
        exit 1
    fi

    local block_file
    block_file="$(mktemp)"
    generate_socks5_blocks "$count" "$base_port" "$block_file"
    insert_blocks_before_rules "$block_file"
    rm -f "$block_file"

    cat > "$SOCKS5_GROUP_STATE" <<EOF
SOCKS5_GROUP_ENABLED="1"
SOCKS5_GROUP_COUNT="${count}"
SOCKS5_GROUP_BASE_PORT="${base_port}"
SOCKS5_GROUP_LAST_PORT="${last_port}"
EOF

    test_and_restart

    local ip
    ip="$(get_server_ip)"

    echo ""
    echo -e "${CYAN}SOCKS5 独立端口组已启用：${NC}"
    echo "主 SOCKS5 端口：${ip}:${base_port}"
    echo ""
    echo "新增 SOCKS5 端口："
    local i
    for ((i=1; i<=count; i++)); do
        local port=$((base_port + i))
        echo "  SOCKS5-${port} -> ${ip}:${port}"
    done
    echo ""
    log_info "现在可以在 Web 面板分别给 SOCKS5-端口组选择不同节点"
}

disable_socks5_group() {
    check_root
    ensure_config_exists
    backup_file "$CONFIG_FILE"
    remove_socks5_group_blocks
    rm -f "$SOCKS5_GROUP_STATE"
    test_and_restart
    log_success "已移除 SOCKS5 独立端口组"
}

show_socks5_group_status() {
    echo ""
    echo -e "${CYAN}SOCKS5 多端口组状态：${NC}"

    if [ -f "$SOCKS5_GROUP_STATE" ]; then
        # shellcheck disable=SC1090
        . "$SOCKS5_GROUP_STATE"
        echo "  状态：已启用"
        echo "  主端口：${SOCKS5_GROUP_BASE_PORT:-未知}"
        echo "  数量：${SOCKS5_GROUP_COUNT:-未知}"
        echo "  最后端口：${SOCKS5_GROUP_LAST_PORT:-未知}"
        echo ""
        local ip
        ip="$(get_server_ip)"
        local count="${SOCKS5_GROUP_COUNT:-0}"
        local base_port="${SOCKS5_GROUP_BASE_PORT:-$(get_socks_port)}"
        if echo "$count" | grep -qE '^[0-9]+$'; then
            echo "  端口列表："
            local i
            for ((i=1; i<=count; i++)); do
                local port=$((base_port + i))
                echo "    SOCKS5-${port} -> ${ip}:${port}"
            done
        fi
    else
        echo "  状态：未启用"
        echo "  当前主 SOCKS5 端口：$(get_socks_port)"
    fi
    echo ""
}

# =========================
# 配置生成
# =========================

create_default_config() {
    mkdir -p "$MIHOMO_DIR"
    if [ -f "$CONFIG_FILE" ]; then
        log_warn "配置文件已存在，跳过生成：$CONFIG_FILE"
        return 0
    fi

    cat > "$CONFIG_FILE" <<EOF
port: ${DEFAULT_HTTP_PORT}
socks-port: ${DEFAULT_SOCKS_PORT}
allow-lan: true
mode: rule
log-level: info
external-controller: ${DEFAULT_CONTROLLER}
external-ui: ui

dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
    - 8.8.8.8
    - 1.1.1.1

proxies: []

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - DIRECT

rules:
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,localhost,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF

    log_success "已生成默认配置：$CONFIG_FILE"
}

create_subscription_config() {
    local controller
    local http_port
    local socks_port

    controller="$(get_controller_from_config)"
    controller="${controller:-$DEFAULT_CONTROLLER}"

    http_port="$(get_http_port)"
    http_port="${http_port:-$DEFAULT_HTTP_PORT}"

    socks_port="$(get_socks_port)"
    socks_port="${socks_port:-$DEFAULT_SOCKS_PORT}"

    backup_file "$CONFIG_FILE"

    cat > "$CONFIG_FILE" <<EOF
port: ${http_port}
socks-port: ${socks_port}
allow-lan: true
mode: rule
log-level: info
external-controller: ${controller}
external-ui: ui

dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
    - 8.8.8.8
    - 1.1.1.1
  fallback:
    - tls://8.8.8.8
    - tls://1.1.1.1
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "localhost"
    - "localhost.*"
    - "time.*"
    - "ntp.*"

proxy-providers:
  subscription:
    type: file
    path: ./subscription.yaml
    health-check:
      enable: true
      interval: ${HEALTH_CHECK_INTERVAL}
      url: ${HEALTH_CHECK_URL}

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - AUTO
      - FALLBACK
      - LOAD-BALANCE
      - DIRECT
    use:
      - subscription

  - name: "AUTO"
    type: url-test
    use:
      - subscription
    url: ${HEALTH_CHECK_URL}
    interval: ${HEALTH_CHECK_INTERVAL}
    tolerance: 50
    lazy: true

  - name: "FALLBACK"
    type: fallback
    use:
      - subscription
    url: ${HEALTH_CHECK_URL}
    interval: ${HEALTH_CHECK_INTERVAL}
    lazy: true

  - name: "LOAD-BALANCE"
    type: load-balance
    use:
      - subscription
    url: ${HEALTH_CHECK_URL}
    interval: ${HEALTH_CHECK_INTERVAL}
    strategy: round-robin
    lazy: true

rules:
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,localhost,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF

    if [ -f "$SOCKS5_GROUP_STATE" ]; then
        # shellcheck disable=SC1090
        . "$SOCKS5_GROUP_STATE"
        if [ -n "${SOCKS5_GROUP_COUNT:-}" ]; then
            enable_socks5_group "$SOCKS5_GROUP_COUNT"
            return 0
        fi
    fi

    log_success "已生成自动选择 / 故障转移 / 负载均衡代理组配置"
}

# =========================
# 安装 / 前端 / 订阅
# =========================

download_and_install_core() {
    local arch_file
    arch_file="$(detect_arch_file)"
    local url="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${arch_file}"

    log_info "Mihomo 版本：$MIHOMO_VERSION"
    log_info "核心文件：$arch_file"

    download_file "$url" "/tmp/mihomo.gz" "Mihomo 核心"
    gunzip -c "/tmp/mihomo.gz" > "$MIHOMO_BIN"
    chmod +x "$MIHOMO_BIN"
    rm -f "/tmp/mihomo.gz"

    log_success "Mihomo 核心已安装：$MIHOMO_BIN"
}

create_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=${MIHOMO_BIN} -d ${MIHOMO_DIR}
WorkingDirectory=${MIHOMO_DIR}
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    log_success "systemd 服务已创建：$SERVICE_FILE"
}

install_metacubexd() {
    log_info "安装 MetaCubeXD 前端..."
    mkdir -p "$MIHOMO_DIR"
    rm -rf "$UI_DIR"
    mkdir -p "$UI_DIR"
    download_file "$METACUBEXD_DOWNLOAD_URL" "/tmp/metacubexd.tgz" "MetaCubeXD"
    tar -xzf "/tmp/metacubexd.tgz" -C "$UI_DIR"
    rm -f "/tmp/metacubexd.tgz"
    echo "metacubexd" > "$UI_DIR/.frontend_info"
    echo "MetaCubeXD ${METACUBEXD_VERSION}" > "$UI_DIR/.frontend_version"
    log_success "MetaCubeXD 安装完成"
}

install_zashboard() {
    log_info "安装 Zashboard 前端..."
    mkdir -p "$MIHOMO_DIR"
    rm -rf "$UI_DIR"
    mkdir -p "$UI_DIR"
    download_file "$ZASHBOARD_DOWNLOAD_URL" "/tmp/zashboard.zip" "Zashboard"
    unzip -q "/tmp/zashboard.zip" -d "$UI_DIR"
    rm -f "/tmp/zashboard.zip"
    echo "zashboard" > "$UI_DIR/.frontend_info"
    echo "Zashboard ${ZASHBOARD_VERSION}" > "$UI_DIR/.frontend_version"
    log_success "Zashboard 安装完成"
}

install_frontend() {
    check_root
    local frontend="${1:-}"
    if [ -z "$frontend" ]; then
        echo ""
        echo -e "${CYAN}请选择前端：${NC}"
        echo "1) MetaCubeXD"
        echo "2) Zashboard"
        echo ""
        read -r -p "请输入选择 [1-2]，默认 1：" choice
        choice="${choice:-1}"
        case "$choice" in
            1) frontend="metacubexd" ;;
            2) frontend="zashboard" ;;
            *) log_error "无效选择"; exit 1 ;;
        esac
    fi

    case "$frontend" in
        metacubexd|meta|1) install_metacubexd ;;
        zashboard|zash|2) install_zashboard ;;
        *) log_error "不支持的前端：$frontend"; exit 1 ;;
    esac

    restart_if_running
}

show_frontend_info() {
    local current="unknown"
    local version="unknown"
    [ -f "$UI_DIR/.frontend_info" ] && current="$(cat "$UI_DIR/.frontend_info")"
    [ -f "$UI_DIR/.frontend_version" ] && version="$(cat "$UI_DIR/.frontend_version")"
    echo -e "${CYAN}当前前端：${NC}${current}"
    echo -e "${CYAN}前端版本：${NC}${version}"
    echo -e "${CYAN}前端目录：${NC}${UI_DIR}"
}

import_subscription() {
    check_root
    mkdir -p "$MIHOMO_DIR"

    local url="${1:-}"
    if [ -z "$url" ]; then
        read -r -p "请输入订阅链接：" url
    fi

    if [ -z "$url" ]; then
        log_error "订阅链接不能为空"
        exit 1
    fi

    log_info "开始下载订阅..."
    backup_file "$SUB_FILE"

    if ! curl -fL --connect-timeout 10 --max-time 120 -A "Clash Verge" -H "User-Agent: Clash Verge" -o "$SUB_FILE.tmp" "$url"; then
        log_error "订阅下载失败"
        rm -f "$SUB_FILE.tmp"
        exit 1
    fi

    local size
    size="$(stat -c%s "$SUB_FILE.tmp" 2>/dev/null || echo 0)"
    if [ "$size" -lt 20 ]; then
        log_error "订阅文件过小，可能无效"
        rm -f "$SUB_FILE.tmp"
        exit 1
    fi

    if grep -qiE "<html|<!doctype html" "$SUB_FILE.tmp"; then
        log_error "下载到的是网页，不是订阅 YAML"
        rm -f "$SUB_FILE.tmp"
        exit 1
    fi

    mv "$SUB_FILE.tmp" "$SUB_FILE"
    log_success "订阅已保存：$SUB_FILE"

    create_subscription_config
    test_and_restart
    log_success "订阅导入完成，Mihomo 已重启"
    show_access_info
}

regenerate_proxy_groups() {
    check_root
    if [ ! -f "$SUB_FILE" ]; then
        log_error "订阅文件不存在：$SUB_FILE"
        exit 1
    fi
    create_subscription_config
    test_and_restart
    log_success "已重新生成代理组并重启 Mihomo"
}

# =========================
# 端口修改
# =========================

change_controller_port() {
    check_root
    local input="${1:-}"
    if [ -z "$input" ]; then
        local current
        current="$(get_controller_from_config)"
        echo ""
        echo "当前 external-controller：${current:-未设置}"
        read -r -p "请输入新的管理端口，例如 8899 或 0.0.0.0:8899：" input
    fi

    local controller
    controller="$(normalize_controller "$input")"

    ensure_config_exists
    backup_file "$CONFIG_FILE"

    if grep -qE '^[[:space:]]*external-controller:' "$CONFIG_FILE"; then
        sed -i -E "s#^[[:space:]]*external-controller:.*#external-controller: ${controller}#g" "$CONFIG_FILE"
    else
        echo "external-controller: ${controller}" >> "$CONFIG_FILE"
    fi

    log_success "external-controller 已修改为：$controller"
    test_and_restart
    show_access_info
}

change_http_port() {
    check_root
    local input="${1:-}"
    if [ -z "$input" ]; then
        local current
        current="$(get_http_port)"
        echo ""
        echo "当前 HTTP 代理端口 port：${current:-未设置}"
        read -r -p "请输入新的 HTTP 代理端口，例如 7890：" input
    fi

    local port
    port="$(normalize_port_only "$input")"

    ensure_config_exists
    backup_file "$CONFIG_FILE"

    if grep -qE '^[[:space:]]*port:' "$CONFIG_FILE"; then
        sed -i -E "s#^[[:space:]]*port:.*#port: ${port}#g" "$CONFIG_FILE"
    else
        sed -i "1i port: ${port}" "$CONFIG_FILE"
    fi

    log_success "HTTP 代理端口 port 已修改为：$port"
    test_and_restart
    log_info "HTTP 代理地址：http://$(get_server_ip):${port}"
}

change_socks_port() {
    check_root
    local input="${1:-}"
    if [ -z "$input" ]; then
        local current
        current="$(get_socks_port)"
        echo ""
        echo "当前 SOCKS5 代理端口 socks-port：${current:-未设置}"
        read -r -p "请输入新的 SOCKS5 端口，例如 7891：" input
    fi

    local port
    port="$(normalize_port_only "$input")"

    ensure_config_exists
    backup_file "$CONFIG_FILE"

    if grep -qE '^[[:space:]]*socks-port:' "$CONFIG_FILE"; then
        sed -i -E "s#^[[:space:]]*socks-port:.*#socks-port: ${port}#g" "$CONFIG_FILE"
    else
        sed -i "/^[[:space:]]*port:/a socks-port: ${port}" "$CONFIG_FILE"
    fi

    log_success "SOCKS5 代理端口 socks-port 已修改为：$port"
    test_and_restart
    log_info "SOCKS5 代理地址：$(get_server_ip):${port}"
}

# =========================
# 服务管理
# =========================

test_and_restart() {
    download_country_mmdb
    if [ -x "$MIHOMO_BIN" ]; then
        log_info "测试 Mihomo 配置..."
        if "$MIHOMO_BIN" -t -d "$MIHOMO_DIR" >/tmp/mihomo_test.log 2>&1; then
            log_success "配置测试通过"
        else
            log_error "配置测试失败："
            cat /tmp/mihomo_test.log
            exit 1
        fi
    else
        log_warn "Mihomo 核心不存在，跳过配置测试：$MIHOMO_BIN"
    fi
    systemctl restart mihomo 2>/dev/null || true
}

show_access_info() {
    local ip http_port socks_port controller_port
    ip="$(get_server_ip)"
    http_port="$(get_http_port)"
    socks_port="$(get_socks_port)"
    controller_port="$(get_controller_port)"

    echo ""
    echo -e "${CYAN}访问与代理信息：${NC}"
    echo "  Web 管理界面: http://${ip}:${controller_port}"
    echo "  HTTP 代理    : http://${ip}:${http_port}"
    echo "  SOCKS5 代理  : ${ip}:${socks_port}"
    echo ""
}

start_mihomo() {
    check_root
    download_country_mmdb
    systemctl start mihomo
    log_success "Mihomo 已启动"
    show_access_info
}

stop_mihomo() {
    check_root
    systemctl stop mihomo
    log_success "Mihomo 已停止"
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY || true
    log_info "当前会话代理环境变量已清理"
}

restart_mihomo() {
    check_root
    download_country_mmdb
    systemctl restart mihomo
    log_success "Mihomo 已重启"
    show_access_info
}

status_mihomo() {
    systemctl status mihomo --no-pager || true
    echo ""
    echo -e "${CYAN}端口监听：${NC}"
    if command_exists ss; then
        ss -tlnp | grep -E "mihomo|:$(get_http_port)|:$(get_socks_port)|:$(get_controller_port)" || true
    elif command_exists netstat; then
        netstat -tlnp | grep -E "mihomo|:$(get_http_port)|:$(get_socks_port)|:$(get_controller_port)" || true
    else
        log_warn "未找到 ss 或 netstat"
    fi

    show_access_info

    echo -e "${CYAN}Country.mmdb：${NC}"
    if check_country_mmdb; then
        ls -lh "$COUNTRY_MMDB"
    else
        echo "无效或不存在，可运行：sudo bash mihomo.sh mmdb"
    fi

    echo ""
    echo -e "${CYAN}当前代理组：${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        grep -E '^[[:space:]]*- name:' "$CONFIG_FILE" || true
    fi

    show_socks5_group_status
}

log_mihomo() {
    journalctl -u mihomo -f
}

test_config() {
    check_root
    if [ ! -x "$MIHOMO_BIN" ]; then
        log_error "Mihomo 核心不存在：$MIHOMO_BIN"
        exit 1
    fi
    download_country_mmdb
    "$MIHOMO_BIN" -t -d "$MIHOMO_DIR"
}

# =========================
# 卸载
# =========================

uninstall_mihomo() {
    check_root
    echo -e "${YELLOW}警告：即将卸载 Mihomo，并删除以下内容：${NC}"
    echo "  - $MIHOMO_DIR"
    echo "  - $MIHOMO_BIN_DIR"
    echo "  - $SERVICE_FILE"
    echo "  - /usr/local/bin/mihomoctl"
    echo "  - /usr/local/bin/mihomo.sh"
    echo "  - /usr/local/bin/clashon 等快捷命令"
    echo ""
    read -r -p "确定卸载？[y/N]: " choice
    choice="${choice:-N}"
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        log_info "已取消卸载"
        exit 0
    fi

    systemctl stop mihomo 2>/dev/null || true
    systemctl disable mihomo 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    rm -rf "$MIHOMO_DIR" "$MIHOMO_BIN_DIR"
    rm -f /usr/local/bin/mihomoctl /usr/local/bin/mihomo.sh
    rm -f /usr/local/bin/clashon /usr/local/bin/clashoff /usr/local/bin/clashstatus /usr/local/bin/clashlog
    rm -f /usr/local/bin/clashrestart /usr/local/bin/clashfrontend /usr/local/bin/clashuninstall

    log_success "Mihomo 已卸载完成"
}

# =========================
# 菜单
# =========================

show_menu() {
    clear || true
    echo -e "${CYAN}================================${NC}"
    echo -e "${CYAN}       Mihomo 一体化管理脚本${NC}"
    echo -e "${CYAN}================================${NC}"
    echo ""
    echo "  1) 安装 Mihomo"
    echo "  2) 启动 Mihomo"
    echo "  3) 停止 Mihomo"
    echo "  4) 重启 Mihomo"
    echo "  5) 查看状态"
    echo "  6) 查看日志"
    echo "  7) 导入订阅"
    echo "  8) 修改 Web 管理端口 external-controller"
    echo "  9) 修改 HTTP 代理端口 port"
    echo " 10) 修改 SOCKS5 代理端口 socks-port"
    echo " 11) 切换前端"
    echo " 12) 查看前端信息"
    echo " 13) 测试配置"
    echo " 14) 重新生成自动/均衡代理组"
    echo " 15) 修复/下载 Country.mmdb"
    echo " 16) 启用 SOCKS5 多端口组"
    echo " 17) 移除 SOCKS5 多端口组"
    echo " 18) 查看 SOCKS5 多端口组状态"
    echo " 19) 卸载 Mihomo"
    echo "  0) 退出"
    echo ""
}

interactive_menu() {
    while true; do
        show_menu
        read -r -p "请输入选项：" choice
        case "$choice" in
            1) install_mihomo ;;
            2) start_mihomo ;;
            3) stop_mihomo ;;
            4) restart_mihomo ;;
            5) status_mihomo ;;
            6) log_mihomo ;;
            7) import_subscription ;;
            8) change_controller_port ;;
            9) change_http_port ;;
            10) change_socks_port ;;
            11) install_frontend ;;
            12) show_frontend_info ;;
            13) test_config ;;
            14) regenerate_proxy_groups ;;
            15) repair_mmdb ;;
            16) enable_socks5_group ;;
            17) disable_socks5_group ;;
            18) show_socks5_group_status ;;
            19) uninstall_mihomo ;;
            0) exit 0 ;;
            *) log_error "无效选项" ;;
        esac
        echo ""
        read -r -p "按回车继续..."
    done
}

show_help() {
    cat <<EOF
Mihomo 一体化管理脚本

用法：
  sudo bash mihomo.sh [命令] [参数]

安装/卸载：
  install                    安装 Mihomo
  uninstall                  卸载 Mihomo

服务：
  start|on                   启动服务
  stop|off                   停止服务
  restart                    重启服务
  status                     查看状态
  log|logs                   查看实时日志
  test                       测试配置

订阅：
  sub [订阅链接]              导入订阅并生成自动代理组
  subscription [订阅链接]     同 sub
  groups                      重新生成自动选择、故障转移、负载均衡代理组

端口：
  port [端口或地址]           修改 Web 管理端口 external-controller
  http [端口]                 修改 HTTP 代理端口 port
  socks [端口]                修改 SOCKS5 代理端口 socks-port

SOCKS5 多端口组：
  socks-group on [数量]       启用多个 SOCKS5 独立端口
  socks-group off             移除新增的 SOCKS5 独立端口
  socks-group status          查看 SOCKS5 多端口组状态

前端：
  frontend [名称]             切换前端
  frontend-info               查看当前前端

数据库：
  mmdb                        修复/下载 Country.mmdb

菜单：
  menu                        打开交互菜单
  help                        显示帮助

安装后的快捷命令：
  mihomoctl status
  mihomoctl sub
  mihomoctl port 8899
  mihomoctl http 7890
  mihomoctl socks 7891
  mihomoctl socks-group on 10
  mihomoctl socks-group off
  mihomoctl mmdb
  mihomoctl frontend zashboard

兼容命令：
  clashon
  clashoff
  clashstatus
  clashlog
  clashrestart
  clashfrontend
  clashuninstall

EOF
}

# =========================
# 安装总流程
# =========================

install_mihomo() {
    check_root
    log_info "开始安装 Mihomo..."
    install_dependencies
    mkdir -p "$MIHOMO_DIR" "$MIHOMO_BIN_DIR"

    if [ -f "$MIHOMO_BIN" ]; then
        log_warn "检测到已安装 Mihomo：$MIHOMO_BIN"
        read -r -p "是否覆盖安装核心？[y/N]: " choice
        choice="${choice:-N}"
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            systemctl stop mihomo 2>/dev/null || true
            download_and_install_core
        else
            log_info "跳过核心覆盖安装"
        fi
    else
        download_and_install_core
    fi

    create_default_config
    download_country_mmdb
    install_frontend "metacubexd"
    create_systemd_service
    create_shortcuts

    systemctl daemon-reload
    systemctl enable mihomo
    systemctl restart mihomo

    show_access_info
    log_success "Mihomo 安装完成"
}

create_shortcuts() {
    cp "$(realpath "$0")" /usr/local/bin/mihomo.sh
    chmod +x /usr/local/bin/mihomo.sh

    cat > /usr/local/bin/mihomoctl <<'EOF'
#!/usr/bin/env bash
SELF_NAME="$(basename "$0")"

case "$SELF_NAME" in
    clashon) sudo bash /usr/local/bin/mihomo.sh start "$@" ;;
    clashoff) sudo bash /usr/local/bin/mihomo.sh stop "$@" ;;
    clashstatus) sudo bash /usr/local/bin/mihomo.sh status "$@" ;;
    clashlog) sudo bash /usr/local/bin/mihomo.sh log "$@" ;;
    clashrestart) sudo bash /usr/local/bin/mihomo.sh restart "$@" ;;
    clashfrontend) sudo bash /usr/local/bin/mihomo.sh frontend "$@" ;;
    clashuninstall) sudo bash /usr/local/bin/mihomo.sh uninstall "$@" ;;
    *) sudo bash /usr/local/bin/mihomo.sh "$@" ;;
esac
EOF

    chmod +x /usr/local/bin/mihomoctl
    ln -sf /usr/local/bin/mihomoctl /usr/local/bin/clashon
    ln -sf /usr/local/bin/mihomoctl /usr/local/bin/clashoff
    ln -sf /usr/local/bin/mihomoctl /usr/local/bin/clashstatus
    ln -sf /usr/local/bin/mihomoctl /usr/local/bin/clashlog
    ln -sf /usr/local/bin/mihomoctl /usr/local/bin/clashrestart
    ln -sf /usr/local/bin/mihomoctl /usr/local/bin/clashfrontend
    ln -sf /usr/local/bin/mihomoctl /usr/local/bin/clashuninstall

    log_success "快捷命令已创建"
}

main() {
    local cmd="${1:-menu}"

    case "$cmd" in
        install) install_mihomo ;;
        uninstall|remove) uninstall_mihomo ;;

        start|on|clashon) start_mihomo ;;
        stop|off|clashoff) stop_mihomo ;;
        restart|reload|clashrestart) restart_mihomo ;;
        status|clashstatus) status_mihomo ;;
        log|logs|clashlog) log_mihomo ;;
        test) test_config ;;

        mmdb|geoip|country|repair-mmdb) repair_mmdb ;;

        sub|subscription|import-sub) import_subscription "${2:-}" ;;
        groups|proxy-groups|regenerate-groups) regenerate_proxy_groups ;;

        port|controller|change-port) change_controller_port "${2:-}" ;;
        http|http-port|change-http) change_http_port "${2:-}" ;;
        socks|socks-port|change-socks) change_socks_port "${2:-}" ;;

        socks-group|socks5-group|socket5-group)
            case "${2:-}" in
                on|enable|add|start)
                    enable_socks5_group "${3:-}"
                    ;;
                off|disable|remove|stop)
                    disable_socks5_group
                    ;;
                status|info)
                    show_socks5_group_status
                    ;;
                *)
                    echo "用法："
                    echo "  sudo bash mihomo.sh socks-group on 10"
                    echo "  sudo bash mihomo.sh socks-group off"
                    echo "  sudo bash mihomo.sh socks-group status"
                    exit 1
                    ;;
            esac
            ;;

        frontend|ui) install_frontend "${2:-}" ;;
        frontend-info|ui-info) show_frontend_info ;;
        menu) interactive_menu ;;
        help|-h|--help) show_help ;;
        *) log_error "未知命令：$cmd"; echo ""; show_help; exit 1 ;;
    esac
}

main "$@"