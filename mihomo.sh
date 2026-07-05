#!/usr/bin/env bash

# Mihomo Linux 一体化管理脚本
# 功能：
# 安装、卸载、启动、停止、重启、状态、日志
# 前端切换、订阅导入/更新
# 修改 external-controller 管理端口
# 修改 HTTP 代理端口 port
# 修改 SOCKS5 代理端口 socks-port
# 设置 HTTP / SOCKS5 共用代理认证
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
SUB_URL_FILE="$MIHOMO_DIR/subscription.url"
COUNTRY_MMDB="$MIHOMO_DIR/Country.mmdb"
SOCKS5_GROUP_STATE="$MIHOMO_DIR/socks5_group.conf"

COUNTRY_MMDB_URL="${COUNTRY_MMDB_URL:-https://github.com/Dreamacro/maxmind-geoip/releases/latest/download/Country.mmdb}"

METACUBEXD_VERSION="${METACUBEXD_VERSION:-v1.189.0}"
METACUBEXD_DOWNLOAD_URL="${METACUBEXD_DOWNLOAD_URL:-https://github.com/MetaCubeX/metacubexd/releases/download/v1.189.0/compressed-dist.tgz}"

ZASHBOARD_VERSION="${ZASHBOARD_VERSION:-latest}"
ZASHBOARD_DOWNLOAD_URL="${ZASHBOARD_DOWNLOAD_URL:-https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip}"

DEFAULT_HTTP_PORT="7890"
DEFAULT_SOCKS_PORT="7891"
DEFAULT_CONTROLLER="127.0.0.1:9090"

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
    command -v "$1" >/dev/null 2>&1
}

has_mikefarah_yq() {
    command_exists yq || return 1
    yq --version 2>/dev/null | grep -qiE 'mikefarah|https://github.com/mikefarah/yq'
}

has_python_yaml() {
    command_exists python3 || return 1
    python3 -c 'import yaml' >/dev/null 2>&1
}

yaml_value_is_integer() {
    case "$1" in
        port|socks-port) return 0 ;;
        *) return 1 ;;
    esac
}

yaml_quote_string() {
    local value="${1:-}"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

yaml_unquote_string() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

    case "$value" in
        \'*\')
            value="${value#\'}"
            value="${value%\'}"
            value="${value//\'\'/\'}"
            ;;
        \"*\")
            value="${value#\"}"
            value="${value%\"}"
            ;;
    esac

    printf '%s\n' "$value"
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
    local output_dir output_base tmp_output

    local mirrors
    mapfile -t mirrors < <(get_github_mirrors)

    output_dir="$(dirname "$output")"
    output_base="$(basename "$output")"
    mkdir -p "$output_dir"
    tmp_output="$(mktemp "${output_dir}/.${output_base}.download.XXXXXX")" || return 1

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

            rm -f "$tmp_output"
            if curl -fL --connect-timeout 8 --max-time 180 -o "$tmp_output" "$url" 2>/dev/null; then
                if [ -f "$tmp_output" ]; then
                    local size
                    size="$(stat -c%s "$tmp_output" 2>/dev/null || echo 0)"
                    local type
                    type="$(file "$tmp_output" 2>/dev/null || echo unknown)"

                    if [ "$size" -lt 100 ]; then
                        log_warn "文件过小，可能下载失败：${size} bytes"
                        rm -f "$tmp_output"
                        continue
                    fi

                    if echo "$type" | grep -qiE "HTML|XML"; then
                        log_warn "下载到的是网页，不是目标文件：$type"
                        rm -f "$tmp_output"
                        continue
                    fi

                    if mv -f "$tmp_output" "$output"; then
                        log_success "下载成功：$output (${size} bytes)"
                        return 0
                    fi
                    rm -f "$tmp_output"
                    log_error "保存下载文件失败：$output"
                    return 1
                fi
            fi

            sleep 1
        done
    done

    log_error "下载失败：$description"
    log_error "原始地址：$original_url"
    rm -f "$tmp_output"
    return 1
}

backup_file() {
    local file="$1"

    if [ -f "$file" ]; then
        local backup
        backup="$(mktemp "${file}.bak.$(date +%Y%m%d_%H%M%S).XXXXXX")" || return 1
        cp -p "$file" "$backup"
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

    [ -f "$CONFIG_FILE" ] || return 0

    if has_mikefarah_yq; then
        YAML_KEY="$key" yq -r '.[strenv(YAML_KEY)] // ""' "$CONFIG_FILE" 2>/dev/null && return 0
    fi

    if has_python_yaml; then
        python3 - "$CONFIG_FILE" "$key" <<'PY' && return 0
import sys
import yaml

cfg, key = sys.argv[1], sys.argv[2]
with open(cfg, "r", encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}
if not isinstance(data, dict):
    sys.exit(1)
value = data.get(key, "")
if value is None:
    value = ""
print(value)
PY
    fi

    awk -v key="$key" '
        index($0, key ":") == 1 {
            value = substr($0, length(key) + 2)
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*#.*$/, "", value)
            sub(/[[:space:]]*$/, "", value)
            if ((value ~ /^".*"$/) || (value ~ /^'\''.*'\''$/)) {
                value = substr(value, 2, length(value) - 2)
            }
            print value
            exit
        }
    ' "$CONFIG_FILE"
}

set_config_value() {
    local key="$1"
    local value="$2"
    local tmp_file

    mkdir -p "$(dirname "$CONFIG_FILE")"
    tmp_file="$(mktemp "$(dirname "$CONFIG_FILE")/.config.yaml.XXXXXX")"

    if has_mikefarah_yq; then
        if [ -f "$CONFIG_FILE" ]; then
            if ! cp "$CONFIG_FILE" "$tmp_file"; then
                rm -f "$tmp_file"
                tmp_file="$(mktemp "$(dirname "$CONFIG_FILE")/.config.yaml.XXXXXX")"
            fi
        else
            printf '{}\n' > "$tmp_file"
        fi
        if [ -s "$tmp_file" ]; then
            local yq_expr
            if yaml_value_is_integer "$key"; then
                yq_expr='.[strenv(YAML_KEY)] = (strenv(YAML_VALUE) | tonumber)'
            else
                yq_expr='.[strenv(YAML_KEY)] = strenv(YAML_VALUE)'
            fi
            if YAML_KEY="$key" YAML_VALUE="$value" yq -i "$yq_expr" "$tmp_file" 2>/dev/null; then
                mv "$tmp_file" "$CONFIG_FILE"
                chmod 600 "$CONFIG_FILE" 2>/dev/null || true
                return 0
            fi
        fi
        rm -f "$tmp_file"
        tmp_file="$(mktemp "$(dirname "$CONFIG_FILE")/.config.yaml.XXXXXX")"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        awk -v key="$key" -v value="$value" '
            BEGIN { written = 0 }
            index($0, key ":") == 1 {
                if (written == 0) {
                    print key ": " value
                    written = 1
                }
                next
            }
            { print }
            END {
                if (written == 0) {
                    print key ": " value
                }
            }
        ' "$CONFIG_FILE" > "$tmp_file"
    else
        printf '%s: %s\n' "$key" "$value" > "$tmp_file"
    fi

    mv "$tmp_file" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

get_top_level_yaml_block() {
    local key="$1"

    [ -f "$CONFIG_FILE" ] || return 0

    awk -v key="$key" '
        $0 ~ ("^" key ":[[:space:]]*") {
            in_block = 1
            print
            next
        }
        in_block {
            if ($0 ~ /^[^[:space:]#]/) exit
            print
        }
    ' "$CONFIG_FILE"
}

remove_top_level_yaml_block() {
    local key="$1"
    local tmp_file

    [ -f "$CONFIG_FILE" ] || return 0

    tmp_file="$(mktemp "$(dirname "$CONFIG_FILE")/.config.yaml.XXXXXX")"
    awk -v key="$key" '
        $0 ~ ("^" key ":[[:space:]]*") {
            in_block = 1
            next
        }
        in_block {
            if ($0 ~ /^[^[:space:]#]/) {
                in_block = 0
                print
            }
            next
        }
        { print }
    ' "$CONFIG_FILE" > "$tmp_file"

    mv "$tmp_file" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

get_proxy_auth_entry() {
    local value

    [ -f "$CONFIG_FILE" ] || return 0

    if has_mikefarah_yq; then
        value="$(yq -r '.authentication[0] // ""' "$CONFIG_FILE" 2>/dev/null || true)"
        if [ -n "${value:-}" ] && [ "$value" != "null" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    fi

    value="$(
        awk '
            /^authentication:[[:space:]]*/ {
                in_auth = 1
                value = $0
                sub(/^authentication:[[:space:]]*/, "", value)
                if (value !~ /^["\047]/) sub(/[[:space:]]+#.*$/, "", value)
                if (value != "" && value != "[]") {
                    print value
                    exit
                }
                next
            }
            in_auth {
                if ($0 ~ /^[^[:space:]#]/) exit
                if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
                    value = $0
                    sub(/^[[:space:]]*-[[:space:]]*/, "", value)
                    if (value !~ /^["\047]/) sub(/[[:space:]]+#.*$/, "", value)
                    print value
                    exit
                }
            }
        ' "$CONFIG_FILE"
    )"

    [ -n "${value:-}" ] || return 0
    yaml_unquote_string "$value"
}

get_proxy_auth_user() {
    local entry
    entry="$(get_proxy_auth_entry)"
    [ -n "${entry:-}" ] || return 0
    printf '%s\n' "${entry%%:*}"
}

proxy_auth_enabled() {
    [ -n "$(get_proxy_auth_entry)" ]
}

validate_proxy_auth_credentials() {
    local username="$1"
    local password="$2"

    if [ -z "$username" ]; then
        log_error "代理认证用户名不能为空"
        exit 1
    fi

    if [ -z "$password" ]; then
        log_error "代理认证密码不能为空"
        exit 1
    fi

    if [[ "$username" == *:* ]]; then
        log_error "代理认证用户名不能包含冒号"
        exit 1
    fi

    if [[ "$username$password" == *$'\n'* || "$username$password" == *$'\r'* ]]; then
        log_error "代理认证用户名和密码不能包含换行"
        exit 1
    fi
}

write_proxy_auth_credentials() {
    local username="$1"
    local password="$2"
    local quoted_auth
    local tmp_file

    validate_proxy_auth_credentials "$username" "$password"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    remove_top_level_yaml_block "authentication"

    quoted_auth="$(yaml_quote_string "${username}:${password}")"
    tmp_file="$(mktemp "$(dirname "$CONFIG_FILE")/.config.yaml.XXXXXX")"

    if [ -f "$CONFIG_FILE" ]; then
        awk -v quoted_auth="$quoted_auth" '
            BEGIN { inserted = 0 }
            {
                print
                if (inserted == 0 && $0 ~ /^socks-port:[[:space:]]*/) {
                    print "authentication:"
                    print "  - " quoted_auth
                    inserted = 1
                }
            }
            END {
                if (inserted == 0) {
                    print "authentication:"
                    print "  - " quoted_auth
                }
            }
        ' "$CONFIG_FILE" > "$tmp_file"
    else
        {
            echo "authentication:"
            echo "  - ${quoted_auth}"
        } > "$tmp_file"
    fi

    mv "$tmp_file" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

clear_proxy_auth_config() {
    remove_top_level_yaml_block "authentication"
}

generate_controller_secret() {
    if command_exists openssl; then
        openssl rand -hex 24
    else
        od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

is_safe_controller_secret() {
    local secret="$1"
    [[ "$secret" =~ ^[A-Za-z0-9._-]{8,128}$ ]]
}

get_secret_from_config() {
    get_config_value "secret"
}

ensure_controller_secret() {
    local secret

    ensure_config_exists
    secret="$(get_secret_from_config)"
    if [ -n "${secret:-}" ]; then
        if is_safe_controller_secret "$secret"; then
            echo "$secret"
            return 0
        fi
        log_warn "现有 secret 包含不安全字符，将重新生成"
    fi

    secret="$(generate_controller_secret)"
    is_safe_controller_secret "$secret" || {
        log_error "无法生成可用管理密钥"
        exit 1
    }

    set_config_value "secret" "$secret"
    echo "$secret"
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

get_controller_host() {
    local controller
    controller="$(get_controller_from_config)"
    echo "${controller%:*}"
}

get_controller_display_host() {
    local host
    host="$(get_controller_host)"
    case "$host" in
        0.0.0.0|"")
            get_server_ip
            ;;
        *)
            echo "$host"
            ;;
    esac
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
        echo "127.0.0.1:${input}"
        return 0
    fi

    if echo "$input" | grep -qE '^:[0-9]+$'; then
        echo "127.0.0.1${input}"
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
    local mmdb="${1:-$COUNTRY_MMDB}"
    if [ ! -f "$mmdb" ]; then return 1; fi
    local size
    size="$(stat -c%s "$mmdb" 2>/dev/null || echo 0)"
    [ "$size" -ge 100000 ] || return 1
    local type
    type="$(file "$mmdb" 2>/dev/null || echo unknown)"
    echo "$type" | grep -qiE "HTML|XML|text|empty" && return 1
    return 0
}

download_country_mmdb() {
    check_root
    mkdir -p "$MIHOMO_DIR"
    local force=0 candidate

    if [ "${1:-}" = "--force" ]; then
        force=1
    fi

    if [ "$force" -eq 0 ] && check_country_mmdb; then
        local size
        size="$(stat -c%s "$COUNTRY_MMDB" 2>/dev/null || echo 0)"
        log_success "Country.mmdb 正常：$COUNTRY_MMDB (${size} bytes)"
        return 0
    fi

    log_warn "Country.mmdb 不存在或无效，开始下载..."

    candidate="$(mktemp "$MIHOMO_DIR/.Country.mmdb.XXXXXX")" || return 1

    if download_file "$COUNTRY_MMDB_URL" "$candidate" "Country.mmdb"; then
        if check_country_mmdb "$candidate"; then
            chmod 644 "$candidate"
            mv -f "$candidate" "$COUNTRY_MMDB" || {
                rm -f "$candidate"
                return 1
            }
            rm -f "$MIHOMO_DIR/country.mmdb" "$MIHOMO_DIR/geoip.metadb"
            local size
            size="$(stat -c%s "$COUNTRY_MMDB" 2>/dev/null || echo 0)"
            log_success "Country.mmdb 下载完成：$COUNTRY_MMDB (${size} bytes)"
            return 0
        fi
    fi

    rm -f "$candidate"
    log_error "Country.mmdb 下载失败或文件无效"
    return 1
}

repair_mmdb() {
    check_root
    log_info "开始修复 Country.mmdb..."
    download_country_mmdb --force || return 1
    test_and_restart
    log_success "Country.mmdb 修复完成"
}

# =========================
# SOCKS5 多端口组
# =========================

remove_socks5_group_blocks() {
    if [ -f "$CONFIG_FILE" ]; then
        local tmp_file
        tmp_file="$(mktemp "$(dirname "$CONFIG_FILE")/.config.yaml.XXXXXX")"
        awk '
            function flush_buffer() {
                for (i = 1; i <= buffered; i++) print buffer[i]
                buffered = 0
            }
            /# MIHOMO SOCKS5 (GROUPS|LISTENERS) BEGIN/ {
                in_block = 1
                buffered = 1
                buffer[buffered] = $0
                next
            }
            in_block {
                buffered++
                buffer[buffered] = $0
                if ($0 ~ /# MIHOMO SOCKS5 (GROUPS|LISTENERS) END/) {
                    in_block = 0
                    buffered = 0
                }
                next
            }
            { print }
            END {
                if (in_block) flush_buffer()
            }
        ' "$CONFIG_FILE" > "$tmp_file"
        mv "$tmp_file" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
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
    tmp_file="$(mktemp "$(dirname "$CONFIG_FILE")/.config.yaml.XXXXXX")"

    awk -v block="$(cat "$block_file")" '
        BEGIN { inserted = 0 }
        /^rules:/ {
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
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
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

    if grep -qE '^listeners:' "$CONFIG_FILE"; then
        log_error "检测到 config.yaml 中已存在 listeners 配置"
        log_info "为了避免破坏你已有的配置，脚本暂停自动写入。"
        log_info "请先手动处理 listeners 后再启用 SOCKS5 多端口组。"
        exit 1
    fi

    local block_file
    block_file="$(mktemp "$(dirname "$CONFIG_FILE")/.socks5-block.XXXXXX")"
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

    local secret
    secret="$(generate_controller_secret)"
    is_safe_controller_secret "$secret" || {
        log_error "无法生成可用管理密钥"
        exit 1
    }

    cat > "$CONFIG_FILE" <<EOF
port: ${DEFAULT_HTTP_PORT}
socks-port: ${DEFAULT_SOCKS_PORT}
allow-lan: true
mode: rule
log-level: info
external-controller: ${DEFAULT_CONTROLLER}
secret: ${secret}
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
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true

    log_success "已生成默认配置：$CONFIG_FILE"
}

create_subscription_config() {
    local controller
    local http_port
    local socks_port
    local secret
    local proxy_auth_block
    local skip_auth_prefixes_block

    controller="$(get_controller_from_config)"
    controller="${controller:-$DEFAULT_CONTROLLER}"

    secret="$(get_secret_from_config)"
    if [ -z "${secret:-}" ] || ! is_safe_controller_secret "$secret"; then
        secret="$(generate_controller_secret)"
    fi

    http_port="$(get_http_port)"
    http_port="${http_port:-$DEFAULT_HTTP_PORT}"

    socks_port="$(get_socks_port)"
    socks_port="${socks_port:-$DEFAULT_SOCKS_PORT}"

    proxy_auth_block="$(get_top_level_yaml_block "authentication")"
    skip_auth_prefixes_block="$(get_top_level_yaml_block "skip-auth-prefixes")"

    backup_file "$CONFIG_FILE"

    {
        cat <<EOF
port: ${http_port}
socks-port: ${socks_port}
EOF
        if [ -n "${proxy_auth_block:-}" ]; then
            printf '%s\n' "$proxy_auth_block"
        fi
        if [ -n "${skip_auth_prefixes_block:-}" ]; then
            printf '%s\n' "$skip_auth_prefixes_block"
        fi
        cat <<EOF
allow-lan: true
mode: rule
log-level: info
external-controller: ${controller}
secret: ${secret}
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
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true

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
    local tmp_dir tmp_file bin_dir tmp_bin

    log_info "Mihomo 版本：$MIHOMO_VERSION"
    log_info "核心文件：$arch_file"

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mihomo.XXXXXX")"
    tmp_file="${tmp_dir}/mihomo.gz"
    if ! download_file "$url" "$tmp_file" "Mihomo 核心"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    bin_dir="$(dirname "$MIHOMO_BIN")"
    mkdir -p "$bin_dir"
    tmp_bin="$(mktemp "${bin_dir}/.mihomo.XXXXXX")" || {
        rm -rf "$tmp_dir"
        return 1
    }

    if ! gunzip -c "$tmp_file" > "$tmp_bin"; then
        rm -f "$tmp_bin"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! chmod +x "$tmp_bin"; then
        rm -f "$tmp_bin"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! mv -f "$tmp_bin" "$MIHOMO_BIN"; then
        rm -f "$tmp_bin"
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"

    log_success "Mihomo 核心已安装：$MIHOMO_BIN"
}

replace_dir_with_backup() {
    local src_dir="$1"
    local dst_dir="$2"
    local parent backup_dir=""

    parent="$(dirname "$dst_dir")"
    mkdir -p "$parent"

    if [ -e "$dst_dir" ]; then
        backup_dir="$(mktemp -d "${parent}/.$(basename "$dst_dir").bak.XXXXXX")" || return 1
        rmdir "$backup_dir"
        if ! mv "$dst_dir" "$backup_dir"; then
            rm -rf "$backup_dir"
            return 1
        fi
    fi

    if mv "$src_dir" "$dst_dir"; then
        [ -n "$backup_dir" ] && rm -rf "$backup_dir"
        return 0
    fi

    rm -rf "$dst_dir"
    if [ -n "$backup_dir" ] && [ -e "$backup_dir" ]; then
        mv "$backup_dir" "$dst_dir" || true
    fi
    return 1
}

prepare_frontend_stage() {
    local stage_dir="$1"
    local nested_index nested_dir item

    if [ -f "$stage_dir/index.html" ]; then
        return 0
    fi

    nested_index="$(find "$stage_dir" -mindepth 2 -maxdepth 2 -type f -name 'index.html' | head -n 1)"
    [ -n "$nested_index" ] || return 1
    nested_dir="$(dirname "$nested_index")"

    while IFS= read -r item; do
        mv "$item" "$stage_dir/"
    done < <(find "$nested_dir" -mindepth 1 -maxdepth 1)
    rmdir "$nested_dir" 2>/dev/null || true

    [ -f "$stage_dir/index.html" ]
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
    local tmp_dir tmp_file stage_dir
    mkdir -p "$MIHOMO_DIR"
    tmp_dir="$(mktemp -d "${MIHOMO_DIR}/.ui-download.XXXXXX")"
    tmp_file="${tmp_dir}/metacubexd.tgz"
    stage_dir="${tmp_dir}/ui"
    mkdir -p "$stage_dir"
    if ! download_file "$METACUBEXD_DOWNLOAD_URL" "$tmp_file" "MetaCubeXD"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    tar -tzf "$tmp_file" >/dev/null || {
        rm -rf "$tmp_dir"
        return 1
    }
    tar -xzf "$tmp_file" -C "$stage_dir" || {
        rm -rf "$tmp_dir"
        return 1
    }
    if ! prepare_frontend_stage "$stage_dir"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    echo "metacubexd" > "$stage_dir/.frontend_info"
    echo "MetaCubeXD ${METACUBEXD_VERSION}" > "$stage_dir/.frontend_version"
    replace_dir_with_backup "$stage_dir" "$UI_DIR" || {
        rm -rf "$tmp_dir"
        return 1
    }
    rm -rf "$tmp_dir"
    log_success "MetaCubeXD 安装完成"
}

install_zashboard() {
    log_info "安装 Zashboard 前端..."
    local tmp_dir tmp_file stage_dir
    mkdir -p "$MIHOMO_DIR"
    tmp_dir="$(mktemp -d "${MIHOMO_DIR}/.ui-download.XXXXXX")"
    tmp_file="${tmp_dir}/zashboard.zip"
    stage_dir="${tmp_dir}/ui"
    mkdir -p "$stage_dir"
    if ! download_file "$ZASHBOARD_DOWNLOAD_URL" "$tmp_file" "Zashboard"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    unzip -tq "$tmp_file" >/dev/null || {
        rm -rf "$tmp_dir"
        return 1
    }
    unzip -q "$tmp_file" -d "$stage_dir" || {
        rm -rf "$tmp_dir"
        return 1
    }
    if ! prepare_frontend_stage "$stage_dir"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    echo "zashboard" > "$stage_dir/.frontend_info"
    echo "Zashboard ${ZASHBOARD_VERSION}" > "$stage_dir/.frontend_version"
    replace_dir_with_backup "$stage_dir" "$UI_DIR" || {
        rm -rf "$tmp_dir"
        return 1
    }
    rm -rf "$tmp_dir"
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

validate_subscription_file() {
    local file="$1"
    local size

    size="$(stat -c%s "$file" 2>/dev/null || echo 0)"
    if [ "$size" -lt 20 ]; then
        log_error "订阅文件过小，可能无效"
        return 1
    fi

    if grep -qiE "<html|<!doctype html" "$file"; then
        log_error "下载到的是网页，不是订阅 YAML"
        return 1
    fi
}

validate_subscription_url() {
    local url="$1"

    if [ -z "$url" ]; then
        log_error "订阅链接不能为空"
        return 1
    fi

    if [[ "$url" == *$'\n'* || "$url" == *$'\r'* ]]; then
        log_error "订阅链接不能包含换行"
        return 1
    fi
}

curl_config_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

download_subscription_file() {
    local url="$1"
    local output="$2"
    local quoted_url

    validate_subscription_url "$url" || return 1
    quoted_url="$(curl_config_quote "$url")"

    if ! printf 'url = %s\n' "$quoted_url" | curl -fL --connect-timeout 10 --max-time 120 -A "Clash Verge" -H "User-Agent: Clash Verge" -o "$output" --config -; then
        log_error "订阅下载失败"
        return 1
    fi

    validate_subscription_file "$output"
}

save_subscription_url() {
    local url="$1"
    local tmp_file

    validate_subscription_url "$url" || return 1
    mkdir -p "$MIHOMO_DIR"
    tmp_file="$(mktemp "$MIHOMO_DIR/.subscription.url.XXXXXX")" || return 1
    printf '%s\n' "$url" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$SUB_URL_FILE" || {
        rm -f "$tmp_file"
        return 1
    }
    chmod 600 "$SUB_URL_FILE" 2>/dev/null || true
}

get_subscription_url() {
    [ -f "$SUB_URL_FILE" ] || return 0
    sed -n '1{s/\r$//;p;q;}' "$SUB_URL_FILE"
}

download_and_publish_subscription() {
    local url="$1"
    local action="${2:-更新}"
    local tmp_sub

    mkdir -p "$MIHOMO_DIR"
    log_info "开始${action}订阅..."

    tmp_sub="$(mktemp "$MIHOMO_DIR/subscription.XXXXXX")" || return 1
    if ! download_subscription_file "$url" "$tmp_sub"; then
        rm -f "$tmp_sub"
        return 1
    fi

    backup_file "$SUB_FILE"
    if ! mv "$tmp_sub" "$SUB_FILE"; then
        log_error "订阅保存失败：$SUB_FILE"
        rm -f "$tmp_sub"
        return 1
    fi
    chmod 600 "$SUB_FILE" 2>/dev/null || true
    log_success "订阅已保存：$SUB_FILE"
}

show_subscription_status() {
    echo ""
    echo -e "${CYAN}订阅状态：${NC}"
    if [ -f "$SUB_FILE" ]; then
        echo "  订阅文件：$SUB_FILE"
    else
        echo "  订阅文件：未导入"
    fi

    if [ -s "$SUB_URL_FILE" ]; then
        echo "  订阅链接：已保存（出于安全考虑不显示明文）"
        echo "  更新命令：sudo bash mihomo.sh sub update"
    else
        echo "  订阅链接：未保存"
        echo "  导入命令：sudo bash mihomo.sh sub <订阅链接>"
    fi
    echo ""
}

import_subscription() {
    check_root

    local url="${1:-}"
    if [ -z "$url" ]; then
        read -r -s -p "请输入订阅链接（输入不会显示）：" url
        echo ""
    fi

    if [ -z "$url" ]; then
        log_error "订阅链接不能为空"
        return 1
    fi

    download_and_publish_subscription "$url" "导入" || return 1
    save_subscription_url "$url" || {
        log_error "订阅链接保存失败：$SUB_URL_FILE"
        return 1
    }
    log_success "订阅链接已保存，后续可执行：sudo bash mihomo.sh sub update"

    create_subscription_config
    test_and_restart
    log_success "订阅导入完成，Mihomo 已重启"
    show_access_info
}

update_subscription() {
    check_root
    local url

    url="$(get_subscription_url)"
    if [ -z "${url:-}" ]; then
        log_error "未找到已保存的订阅链接"
        log_info "请先导入订阅：sudo bash mihomo.sh sub <订阅链接>"
        return 1
    fi

    download_and_publish_subscription "$url" "更新" || return 1

    create_subscription_config
    test_and_restart
    log_success "订阅更新完成，Mihomo 已重启"
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

    set_config_value "external-controller" "$controller"
    ensure_controller_secret >/dev/null

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

    set_config_value "port" "$port"

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

    set_config_value "socks-port" "$port"

    log_success "SOCKS5 代理端口 socks-port 已修改为：$port"
    test_and_restart
    log_info "SOCKS5 代理地址：$(get_server_ip):${port}"
}

# =========================
# 代理认证
# =========================

show_proxy_auth_status() {
    local entry
    local username

    entry="$(get_proxy_auth_entry)"

    echo ""
    echo -e "${CYAN}HTTP / SOCKS5 代理认证：${NC}"
    if [ -n "${entry:-}" ]; then
        username="${entry%%:*}"
        echo "  状态：已启用"
        echo "  用户名：${username}"
        echo "  密码：已隐藏"
    else
        echo "  状态：未启用"
    fi
    echo ""
}

set_proxy_auth() {
    check_root
    local username="${1:-}"
    local password=""

    if [ -z "$username" ]; then
        echo ""
        read -r -p "请输入 HTTP / SOCKS5 共用认证用户名：" username
    fi

    if [ "$#" -ge 2 ]; then
        password="$2"
    else
        read -r -s -p "请输入 HTTP / SOCKS5 共用认证密码：" password
        echo ""
    fi

    ensure_config_exists
    backup_file "$CONFIG_FILE"
    write_proxy_auth_credentials "$username" "$password"

    log_success "HTTP / SOCKS5 代理认证已启用，用户名：$username，密码已隐藏"
    test_and_restart
    show_proxy_auth_status
}

clear_proxy_auth() {
    check_root
    ensure_config_exists

    if ! proxy_auth_enabled; then
        log_info "HTTP / SOCKS5 代理认证未启用"
        return 0
    fi

    backup_file "$CONFIG_FILE"
    clear_proxy_auth_config

    log_success "HTTP / SOCKS5 代理认证已清除"
    test_and_restart
}

manage_proxy_auth() {
    local action="${1:-status}"

    case "$action" in
        ""|status|info)
            show_proxy_auth_status
            ;;
        set|on|enable)
            shift || true
            set_proxy_auth "$@"
            ;;
        off|clear|disable|remove)
            clear_proxy_auth
            ;;
        *)
            if [ "$#" -ge 2 ]; then
                set_proxy_auth "$1" "$2"
            else
                set_proxy_auth "$1"
            fi
            ;;
    esac
}

configure_proxy_auth_menu() {
    check_root
    local choice

    show_proxy_auth_status
    echo "  1) 设置或更新认证"
    echo "  2) 清除认证"
    echo "  0) 返回"
    echo ""
    read -r -p "请选择操作：" choice

    case "$choice" in
        1) set_proxy_auth ;;
        2) clear_proxy_auth ;;
        0|"") return 0 ;;
        *) log_error "无效选项" ;;
    esac
}

# =========================
# 服务管理
# =========================

test_and_restart() {
    local tmp_log
    ensure_controller_secret >/dev/null
    download_country_mmdb
    if [ -x "$MIHOMO_BIN" ]; then
        log_info "测试 Mihomo 配置..."
        tmp_log="$(mktemp "${TMPDIR:-/tmp}/mihomo-test.XXXXXX")"
        if "$MIHOMO_BIN" -t -d "$MIHOMO_DIR" >"$tmp_log" 2>&1; then
            rm -f "$tmp_log"
            log_success "配置测试通过"
        else
            log_error "配置测试失败："
            cat "$tmp_log"
            rm -f "$tmp_log"
            exit 1
        fi
    else
        log_warn "Mihomo 核心不存在，跳过配置测试：$MIHOMO_BIN"
    fi
    systemctl restart mihomo 2>/dev/null || true
}

show_access_info() {
    local ip http_port socks_port controller_port controller_host secret proxy_auth_user
    ip="$(get_server_ip)"
    http_port="$(get_http_port)"
    socks_port="$(get_socks_port)"
    controller_port="$(get_controller_port)"
    controller_host="$(get_controller_display_host)"
    secret="$(get_secret_from_config)"

    echo ""
    echo -e "${CYAN}访问与代理信息：${NC}"
    echo "  Web 管理界面: http://${controller_host}:${controller_port}"
    if [ -n "${secret:-}" ]; then
        echo "  Web 管理密钥: 已设置（见 ${CONFIG_FILE} 的 secret 字段）"
    else
        echo "  Web 管理密钥: 未设置"
    fi
    echo "  HTTP 代理    : http://${ip}:${http_port}"
    echo "  SOCKS5 代理  : ${ip}:${socks_port}"
    proxy_auth_user="$(get_proxy_auth_user)"
    if [ -n "${proxy_auth_user:-}" ]; then
        echo "  代理认证    : 已启用（用户名：${proxy_auth_user}，密码已隐藏）"
    else
        echo "  代理认证    : 未启用"
    fi
    echo ""
}

start_mihomo() {
    check_root
    ensure_controller_secret >/dev/null
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
    ensure_controller_secret >/dev/null
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
    ensure_controller_secret >/dev/null
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
    echo "  8) 更新订阅"
    echo "  9) 修改 Web 管理端口 external-controller"
    echo " 10) 修改 HTTP 代理端口 port"
    echo " 11) 修改 SOCKS5 代理端口 socks-port"
    echo " 12) 设置 HTTP / SOCKS5 代理认证"
    echo " 13) 切换前端"
    echo " 14) 查看前端信息"
    echo " 15) 测试配置"
    echo " 16) 重新生成自动/均衡代理组"
    echo " 17) 修复/下载 Country.mmdb"
    echo " 18) 启用 SOCKS5 多端口组"
    echo " 19) 移除 SOCKS5 多端口组"
    echo " 20) 查看 SOCKS5 多端口组状态"
    echo " 21) 卸载 Mihomo"
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
            8) update_subscription ;;
            9) change_controller_port ;;
            10) change_http_port ;;
            11) change_socks_port ;;
            12) configure_proxy_auth_menu ;;
            13) install_frontend ;;
            14) show_frontend_info ;;
            15) test_config ;;
            16) regenerate_proxy_groups ;;
            17) repair_mmdb ;;
            18) enable_socks5_group ;;
            19) disable_socks5_group ;;
            20) show_socks5_group_status ;;
            21) uninstall_mihomo ;;
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
  sub [订阅链接]              导入订阅、保存链接并生成自动代理组
  sub update                  使用已保存链接更新订阅
  sub status                  查看订阅状态
  update-sub                  同 sub update
  subscription [订阅链接]     同 sub
  groups                      重新生成自动选择、故障转移、负载均衡代理组

端口：
  port [端口或地址]           修改 Web 管理端口 external-controller
  http [端口]                 修改 HTTP 代理端口 port
  socks [端口]                修改 SOCKS5 代理端口 socks-port

代理认证：
  auth [用户名] [密码]        设置 HTTP / SOCKS5 共用认证
  auth set <用户名> [密码]    设置 HTTP / SOCKS5 共用认证
  auth off                    清除 HTTP / SOCKS5 代理认证
  auth status                 查看代理认证状态

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
  mihomoctl sub update
  mihomoctl sub status
  mihomoctl port 8899
  mihomoctl http 7890
  mihomoctl socks 7891
  mihomoctl auth status
  mihomoctl auth set user
  mihomoctl auth off
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

        sub|subscription|import-sub)
            case "${2:-}" in
                update|refresh)
                    update_subscription
                    ;;
                status|info)
                    show_subscription_status
                    ;;
                *)
                    import_subscription "${2:-}"
                    ;;
            esac
            ;;
        update-sub|sub-update|update-subscription|subscription-update|refresh-sub) update_subscription ;;
        groups|proxy-groups|regenerate-groups) regenerate_proxy_groups ;;

        port|controller|change-port) change_controller_port "${2:-}" ;;
        http|http-port|change-http) change_http_port "${2:-}" ;;
        socks|socks-port|change-socks) change_socks_port "${2:-}" ;;
        auth|proxy-auth|authentication)
            shift
            manage_proxy_auth "$@"
            ;;

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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
