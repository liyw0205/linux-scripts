#!/usr/bin/env bash
set -euo pipefail

# ================== 全局配置 ==================
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"
CLOUDFLARED_HOME="${CLOUDFLARED_HOME:-$HOME/.cloudflared}"
SERVICE_PREFIX="cf-tunnel"
SERVICE_DIR="/etc/systemd/system"
PATCH_TARGET="/usr/local/bin/cf"
TMP_ROOT="${TMPDIR:-/tmp}"

# 代理列表
PROXY_LIST="
https://gh-proxy.net/
https://ghfile.geekertao.top/
https://git.yylx.win/
https://gh.llkk.cc/
https://ghproxy.net/
https://github.dpik.top/
https://hub.gitmirror.com/
https://gitproxy.click/
"

# ================== 工具 ==================
ui_print() {
    echo "====================================="
    echo "$1"
}

error() { echo "[ERROR] $*" >&2; }

abort() {
    error "$*"
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

run_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        need_cmd sudo || abort "未检测到 sudo，请安装 sudo 或使用 root 运行"
        sudo "$@"
    fi
}

require_systemd() {
    need_cmd systemctl || abort "检测到非 systemd 系统，无法使用服务管理命令"
}

ensure_home() {
    mkdir -p "$CLOUDFLARED_HOME"
}

check_login() {
    [[ -f "$CLOUDFLARED_HOME/cert.pem" ]] || abort "未登录，请先执行: cf login"
}

service_name() {
    local name="$1"
    echo "${SERVICE_PREFIX}-${name}.service"
}

service_file() {
    local name="$1"
    echo "${SERVICE_DIR}/$(service_name "$name")"
}

yaml_quote() {
    local value="$1"
    value="$(printf '%s' "$value" | sed "s/'/''/g")"
    printf "'%s'" "$value"
}

yaml_unquote() {
    local value="$1"
    if [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
        value="${value//"''"/"'"}"
    fi
    printf '%s\n' "$value"
}

read_yaml_value() {
    local cfg="$1"
    local key="$2"
    local value
    value="$(awk -v key="$key" '
        index($0, key ":") == 1 {
            value = substr($0, length(key) + 2)
            sub(/^[[:space:]]+/, "", value)
            print value
            exit
        }
    ' "$cfg")"
    yaml_unquote "$value"
}

detect_cloudflared_asset() {
    local arch
    if need_cmd dpkg; then
        arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    else
        arch="$(uname -m)"
    fi
    case "$arch" in
        x86_64|amd64)
            echo "cloudflared-linux-amd64"
            ;;
        aarch64|arm64)
            echo "cloudflared-linux-arm64"
            ;;
        armv7l|armv6l|armhf|armel)
            echo "cloudflared-linux-arm"
            ;;
        i386|i686|386)
            echo "cloudflared-linux-386"
            ;;
        *)
            abort "不支持的架构: $arch"
            ;;
    esac
}

# ================== 代理测速/下载 ==================
proxy_latency_ms() {
    local p="$1"
    local host
    host=$(echo "$p" | sed -E 's#^https?://([^/]+)/?.*#\1#')

    if ! command -v ping >/dev/null 2>&1; then
        echo 99999
        return
    fi

    local line
    line=$(ping -c 1 -W 2 "$host" 2>/dev/null | grep -o 'time=[0-9.]*' | head -n1)
    local ms=${line#time=}
    if [[ -z "$ms" ]]; then
        echo 99999
    else
        echo "${ms%.*}"
    fi
}

sorted_proxies() {
    local f
    f="$(mktemp "${TMP_ROOT%/}/cf_proxy_latency.XXXXXX")"
    : > "$f"
    for p in $PROXY_LIST; do
        local l
        l=$(proxy_latency_ms "$p")
        echo "$l $p" >> "$f"
    done
    sort -n "$f" | awk '{print $2}'
    rm -f "$f"
}

http_get() {
    local url="$1"
    local out="$2"

    if need_cmd curl; then
        curl -L --max-time 20 --connect-timeout 8 --retry 1 -o "$out" "$url" >/dev/null 2>&1
    elif need_cmd wget; then
        wget -q --no-check-certificate -t 1 -T 12 -O "$out" "$url"
    else
        error "未检测到 curl/wget"
        return 1
    fi
}

download_with_proxies() {
    local raw_url="$1"
    local out_file="$2"
    local ok=1

    for p in $(sorted_proxies); do
        [ -z "$p" ] && continue
        local l
        l=$(proxy_latency_ms "$p")
        [ "$l" -ge 3000 ] && continue

        local full_url="${p}${raw_url}"
        ui_print "> 尝试代理: $p (延迟: ${l}ms)"
        rm -f "$out_file"
        if http_get "$full_url" "$out_file" && [[ -s "$out_file" ]]; then
            ok=0
            ui_print "> 代理下载成功: $p"
            return 0
        fi
    done

    ui_print "> 代理不可用或超时，回退直连..."
    rm -f "$out_file"
    if http_get "$raw_url" "$out_file" && [[ -s "$out_file" ]]; then
        ok=0
    fi

    [[ $ok -eq 0 ]]
}

# ================== cloudflared 安装 ==================
ensure_cloudflared() {
    if [[ -x "$CLOUDFLARED_BIN" ]] && "$CLOUDFLARED_BIN" --version >/dev/null 2>&1; then
        return 0
    fi
    install_cloudflared
}

install_cloudflared() {
    ui_print "未检测到 cloudflared，开始安装..."
    local asset url tmp
    asset="$(detect_cloudflared_asset)"
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}"
    tmp="$(mktemp "${TMP_ROOT%/}/${asset}.XXXXXX")"

    if ! download_with_proxies "$url" "$tmp"; then
        rm -f "$tmp"
        abort "下载 cloudflared 失败，请检查网络"
    fi

    chmod +x "$tmp"
    if ! "$tmp" --version >/dev/null 2>&1; then
        rm -f "$tmp"
        abort "下载的 cloudflared 无法运行，请检查架构或文件完整性"
    fi

    run_root mkdir -p "$(dirname "$CLOUDFLARED_BIN")"
    run_root install -m 0755 "$tmp" "$CLOUDFLARED_BIN"
    rm -f "$tmp"

    "$CLOUDFLARED_BIN" --version >/dev/null || abort "安装验证失败"
    ui_print "cloudflared 安装完成: $($CLOUDFLARED_BIN --version | head -n 1)"
}

# ================== 隧道信息 ==================
get_tunnel_id_by_name() {
    local name="$1"
    "$CLOUDFLARED_BIN" tunnel list 2>/dev/null | awk -v n="$name" '$2==n {print $1; exit}'
}

tunnel_exists_remote_by_name() {
    local name="$1"
    [[ -n "$(get_tunnel_id_by_name "$name")" ]]
}

tunnel_exists_remote_by_id() {
    local id="$1"
    "$CLOUDFLARED_BIN" tunnel list 2>/dev/null | awk -v t="$id" '$1==t {f=1} END{exit !f}'
}

read_tunnel_id_from_yml() {
    local cfg="$1"
    read_yaml_value "$cfg" "tunnel"
}

read_credentials_from_yml() {
    local cfg="$1"
    read_yaml_value "$cfg" "credentials-file"
}

read_url_from_yml() {
    local cfg="$1"
    read_yaml_value "$cfg" "url"
}

backup_user_file() {
    local file="$1"
    local backup=""

    if [[ -f "$file" ]]; then
        backup="$(mktemp "${TMP_ROOT%/}/cf-user-backup.XXXXXX")" || return 1
        cp -p "$file" "$backup" || {
            rm -f "$backup"
            return 1
        }
    fi

    printf '%s\n' "$backup"
}

restore_user_file() {
    local file="$1"
    local backup="${2:-}"

    if [[ -n "$backup" ]]; then
        mkdir -p "$(dirname "$file")"
        mv "$backup" "$file"
    else
        rm -f "$file"
    fi
}

cleanup_user_backup() {
    local backup="${1:-}"
    [[ -n "$backup" ]] && rm -f "$backup"
}

backup_root_file() {
    local file="$1"
    local backup=""

    if run_root test -f "$file"; then
        backup="$(mktemp "${TMP_ROOT%/}/cf-root-backup.XXXXXX")" || return 1
        run_root cp -p "$file" "$backup" || {
            rm -f "$backup"
            return 1
        }
    fi

    printf '%s\n' "$backup"
}

restore_root_file() {
    local file="$1"
    local backup="${2:-}"

    if [[ -n "$backup" ]]; then
        run_root mkdir -p "$(dirname "$file")"
        run_root install -m 0644 "$backup" "$file"
    else
        run_root rm -f "$file"
    fi
}

cleanup_root_backup() {
    local backup="${1:-}"
    [[ -n "$backup" ]] && run_root rm -f "$backup"
}

# ================== 运行清理 ==================
collect_tunnel_pids() {
    local cfg="$1"
    ps -eo pid=,args= 2>/dev/null | awk -v cfg="$cfg" '
    {
        pid=$1
        $1=""
        line=$0
        if (line ~ /cloudflared/ && line ~ /--config[[:space:]]+/) {
            n = match(line, /--config[[:space:]]+/)
            if (n > 0) {
                rest = substr(line, n + RLENGTH)
                sub(/^[[:space:]]+/, "", rest)
                split(rest, a, /[[:space:]]+/)
                if (a[1] == cfg) print pid
            }
        }
    }'
}

wait_tunnel_exit() {
    local cfg="$1"
    local timeout="${2:-20}"
    local start
    start=$(date +%s)

    while :; do
        local pids
        pids="$(collect_tunnel_pids "$cfg")"
        [[ -z "$pids" ]] && return 0
        local now
        now=$(date +%s)
        (( now - start >= timeout )) && return 1
        sleep 2
    done
}

stop_local_tunnel_runtime() {
    local name="$1"
    local cfg="${CLOUDFLARED_HOME}/${name}.yml"
    local svc
    svc="$(service_name "$name")"

    ui_print "正在停止隧道运行: $name"

    if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
        run_root systemctl stop "$svc" 2>/dev/null || true
        run_root systemctl disable "$svc" 2>/dev/null || true
    fi

    local pids
    pids="$(collect_tunnel_pids "$cfg")"
    if [[ -n "$pids" ]]; then
        for pid in $pids; do run_root kill "$pid" 2>/dev/null || true; done
        if ! wait_tunnel_exit "$cfg" 12; then
            pids="$(collect_tunnel_pids "$cfg")"
            for pid in $pids; do run_root kill -9 "$pid" 2>/dev/null || true; done
            wait_tunnel_exit "$cfg" 5 || true
        fi
    fi
}

delete_tunnel_with_retry() {
    local target="$1"
    local tunnel_name="$2"
    local max_retry=6

    for ((i=1; i<=max_retry; i++)); do
        local out
        if out="$("$CLOUDFLARED_BIN" tunnel delete "$target" 2>&1)"; then
            echo "$out"
            return 0
        fi

        if echo "$out" | grep -Eq "code: 1022|active connections|Please stop all cloudflared replicas|has active connections"; then
            ui_print "检测到 active connections，停止本地运行后重试 (${i}/${max_retry})"
            stop_local_tunnel_runtime "$tunnel_name"
            sleep $((i * 3))
            continue
        fi

        echo "$out" >&2
        return 1
    done

    error "删除失败：多次重试后仍有活动连接"
    return 1
}

# ================== 配置/服务生成 ==================
write_tunnel_yml() {
    local name="$1"
    local tunnel_id="$2"
    local url="$3"
    local cred="${4:-${CLOUDFLARED_HOME}/${tunnel_id}.json}"
    local cfg="${CLOUDFLARED_HOME}/${name}.yml"
    local tmp
    mkdir -p "$CLOUDFLARED_HOME"
    tmp="$(mktemp "${CLOUDFLARED_HOME}/.${name}.yml.XXXXXX")" || return 1
    if ! cat > "$tmp" <<EOF
url: $(yaml_quote "$url")
tunnel: $(yaml_quote "$tunnel_id")
credentials-file: $(yaml_quote "$cred")
EOF
    then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$cfg"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$cfg" 2>/dev/null || true
}

write_service_file() {
    local name="$1"
    local svc_file tmp
    svc_file="$(service_file "$name")"
    run_root mkdir -p "$SERVICE_DIR"
    tmp="$(run_root mktemp "${SERVICE_DIR}/.${name}.service.XXXXXX")" || return 1
    if ! run_root tee "$tmp" >/dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel (${name})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --config ${CLOUDFLARED_HOME}/${name}.yml run
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    then
        run_root rm -f "$tmp"
        return 1
    fi
    if ! run_root chmod 0644 "$tmp" || ! run_root mv "$tmp" "$svc_file"; then
        run_root rm -f "$tmp"
        return 1
    fi
}

write_local_tunnel_files() {
    local name="$1"
    local tunnel_id="$2"
    local url="$3"
    local cred="${4:-${CLOUDFLARED_HOME}/${tunnel_id}.json}"
    local cfg svc_file cfg_backup svc_backup

    cfg="${CLOUDFLARED_HOME}/${name}.yml"
    svc_file="$(service_file "$name")"
    if ! cfg_backup="$(backup_user_file "$cfg")"; then
        return 1
    fi
    if ! svc_backup="$(backup_root_file "$svc_file")"; then
        cleanup_user_backup "$cfg_backup"
        return 1
    fi

    if write_tunnel_yml "$name" "$tunnel_id" "$url" "$cred" && write_service_file "$name"; then
        cleanup_user_backup "$cfg_backup"
        cleanup_root_backup "$svc_backup"
        return 0
    fi

    error "本地配置/服务写入失败，开始回滚: $name"
    restore_user_file "$cfg" "$cfg_backup" || true
    restore_root_file "$svc_file" "$svc_backup" || true
    cleanup_user_backup "$cfg_backup"
    cleanup_root_backup "$svc_backup"
    return 1
}

# ================== 命令 ==================
login_cmd() {
    ensure_cloudflared
    ui_print "请复制浏览器链接完成登录"
    rm -f "$CLOUDFLARED_HOME/cert.pem"
    "$CLOUDFLARED_BIN" tunnel login
}

list_cmd() {
    ensure_cloudflared
    require_systemd
    ui_print "远程隧道列表"
    "$CLOUDFLARED_BIN" tunnel list || true
    echo
    ui_print "本地配置与服务状态"
    local count=0
    shopt -s nullglob
    for cfg in "${CLOUDFLARED_HOME}"/*.yml; do
        [[ -f "$cfg" ]] || continue
        count=$((count + 1))
        local name service enabled status
        name="$(basename "$cfg" .yml)"
        service="$(service_name "$name")"
        enabled="未启用"
        status="未运行"
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            enabled="已启用"
            if systemctl is-active "$service" >/dev/null 2>&1; then status="运行中"; else status="已停"; fi
        fi
        printf "  %-25s  service=%s\n  status: %s / %s\n" "$name" "$service" "$enabled" "$status"
        echo
    done
    shopt -u nullglob
    [[ $count -eq 0 ]] && echo "  无本地配置"
}

create_cmd() {
    local name="${1:-}"
    local url="${2:-http://localhost:80}"
    [[ -n "$name" ]] || abort "用法: cf create <隧道名> [穿透地址]"

    ensure_cloudflared
    check_login

    if tunnel_exists_remote_by_name "$name"; then
        abort "远程已存在同名隧道: $name，请先 delete 或使用 rename"
    fi

    ui_print "正在创建隧道: $name"
    "$CLOUDFLARED_BIN" tunnel create "$name" >/dev/null

    local tunnel_id=""
    for _ in {1..8}; do
        tunnel_id="$(get_tunnel_id_by_name "$name")"
        [[ -n "$tunnel_id" ]] && break
        sleep 1
    done
    [[ -n "$tunnel_id" ]] || abort "创建成功但未拿到 tunnel id"

    write_local_tunnel_files "$name" "$tunnel_id" "$url" || abort "本地配置/服务写入失败: $name"

    ui_print "已创建隧道: $name"
    echo "ID: $tunnel_id"
    echo "配置: ${CLOUDFLARED_HOME}/${name}.yml"
    echo "服务: $(service_file "$name")"
}

delete_cmd() {
    [[ $# -ge 1 ]] || abort "用法: cf delete <隧道名1> [隧道名2 ...]"
    require_systemd
    check_login

    for name in "$@"; do
        ui_print "正在删除隧道: $name"
        local cfg="${CLOUDFLARED_HOME}/${name}.yml"
        local svc_file tunnel_id cred
        svc_file="$(service_file "$name")"
        tunnel_id=""
        cred=""

        if [[ -f "$cfg" ]]; then
            tunnel_id="$(read_tunnel_id_from_yml "$cfg")"
            cred="$(read_credentials_from_yml "$cfg")"
        fi

        if [[ -n "$tunnel_id" ]]; then
            tunnel_exists_remote_by_id "$tunnel_id" || abort "远程不存在此隧道(ID): $tunnel_id（name=$name）"
        else
            tunnel_id="$(get_tunnel_id_by_name "$name")"
            [[ -n "$tunnel_id" ]] || abort "远程不存在此隧道: $name"
        fi

        stop_local_tunnel_runtime "$name"

        if delete_tunnel_with_retry "$tunnel_id" "$name"; then
            if [[ -f "$svc_file" ]]; then
                run_root rm -f "$svc_file"
                run_root systemctl daemon-reload
            fi

            [[ -f "$cfg" ]] && rm -f "$cfg"
            [[ -n "$cred" && -f "$cred" ]] && rm -f "$cred"
            ui_print "已删除隧道: $name"
        else
            abort "删除失败，已保留本地配置以便重试: $name"
        fi
    done
}

rename_cmd() {
    local old_name="${1:-}"
    local new_name="${2:-}"
    [[ -n "$old_name" && -n "$new_name" ]] || abort "用法: cf rename <旧隧道名> <新隧道名>"
    require_systemd
    ensure_cloudflared
    check_login

    [[ "$old_name" != "$new_name" ]] || abort "新旧名称不能相同"
    tunnel_exists_remote_by_name "$old_name" || abort "远程不存在旧隧道: $old_name"
    ! tunnel_exists_remote_by_name "$new_name" || abort "远程已存在新名称: $new_name"

    local id old_cfg new_cfg old_svc new_svc url cred was_enabled
    id="$(get_tunnel_id_by_name "$old_name")"
    [[ -n "$id" ]] || abort "无法获取隧道 ID: $old_name"

    old_cfg="${CLOUDFLARED_HOME}/${old_name}.yml"
    new_cfg="${CLOUDFLARED_HOME}/${new_name}.yml"
    old_svc="$(service_name "$old_name")"
    new_svc="$(service_name "$new_name")"
    was_enabled=0
    if systemctl is-enabled "$old_svc" >/dev/null 2>&1; then
        was_enabled=1
    fi

    stop_local_tunnel_runtime "$old_name"

    ui_print "远程重命名: $old_name -> $new_name"
    "$CLOUDFLARED_BIN" tunnel rename "$id" "$new_name" >/dev/null

    url="http://localhost:80"
    cred="${CLOUDFLARED_HOME}/${id}.json"
    if [[ -f "$old_cfg" ]]; then
        local u c
        u="$(read_url_from_yml "$old_cfg" || true)"
        c="$(read_credentials_from_yml "$old_cfg" || true)"
        [[ -n "${u:-}" ]] && url="$u"
        [[ -n "${c:-}" ]] && cred="$c"
    fi

    write_local_tunnel_files "$new_name" "$id" "$url" "$cred" || abort "本地配置/服务写入失败，已保留旧本地文件: $old_name"

    local old_svc_file new_svc_file
    old_svc_file="$(service_file "$old_name")"
    new_svc_file="$(service_file "$new_name")"
    [[ -f "$old_cfg" ]] && rm -f "$old_cfg"
    [[ -f "$old_svc_file" ]] && run_root rm -f "$old_svc_file"
    run_root systemctl daemon-reload

    if [[ "$was_enabled" -eq 1 ]]; then
        run_root systemctl enable "$new_svc" >/dev/null 2>&1 || true
        run_root systemctl start "$new_svc" >/dev/null 2>&1 || true
    fi

    ui_print "重命名完成: $old_name -> $new_name"
    echo "ID: $id"
    echo "配置: $new_cfg"
    echo "服务: $new_svc_file"
}

sync_cmd() {
    ensure_cloudflared
    check_login
    require_systemd

    ui_print "按远端列表同步本地配置和服务文件"
    local tmp
    tmp="$(mktemp "${TMP_ROOT%/}/cf_sync_list.XXXXXX")"
    "$CLOUDFLARED_BIN" tunnel list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9a-f-]{36}$/ {print $1, $2}' > "$tmp" || true

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        abort "未获取到远端隧道列表"
    fi

    while read -r id name; do
        [[ -z "${id:-}" || -z "${name:-}" ]] && continue
        local cfg="${CLOUDFLARED_HOME}/${name}.yml"
        local url="http://localhost:80"

        if [[ -f "$cfg" ]]; then
            local u
            u="$(read_url_from_yml "$cfg" || true)"
            [[ -n "${u:-}" ]] && url="$u"
        fi

        write_local_tunnel_files "$name" "$id" "$url" || abort "本地配置/服务写入失败: $name"
    done < "$tmp"

    rm -f "$tmp"
    run_root systemctl daemon-reload
    ui_print "同步完成（仅生成/更新本地配置和服务，不自动启停）"
}

dns_cmd() {
    local name="${1:-}"
    local domain="${2:-}"
    [[ -n "$name" && -n "$domain" ]] || abort "用法: cf dns <隧道名> <域名>"
    ensure_cloudflared
    check_login
    tunnel_exists_remote_by_name "$name" || abort "远程不存在隧道: $name"

    ui_print "正在设置 DNS 记录: $domain"
    if "$CLOUDFLARED_BIN" tunnel route dns -f "$name" "$domain" >/dev/null 2>&1; then
        ui_print "DNS 设置成功: $domain"
    else
        abort "DNS 设置失败，可能域名已存在或参数错误"
    fi
}

set_url_cmd() {
    local name="${1:-}"
    local url="${2:-}"
    [[ -n "$name" && -n "$url" ]] || abort "用法: cf set-url <隧道名> <穿透地址>"
    ensure_cloudflared

    local cfg="${CLOUDFLARED_HOME}/${name}.yml"
    [[ -f "$cfg" ]] || abort "配置文件不存在: $cfg"

    local id cred
    id="$(read_tunnel_id_from_yml "$cfg")"
    cred="$(read_credentials_from_yml "$cfg")"
    [[ -n "${id:-}" ]] || abort "无法识别 tunnel 字段: $cfg"
    [[ -n "${cred:-}" ]] || cred="${CLOUDFLARED_HOME}/${id}.json"
    write_tunnel_yml "$name" "$id" "$url" "$cred" || abort "写入配置失败: $cfg"

    ui_print "已修改穿透地址: $name -> $url"
    echo "提示：如需立即生效，请执行 cf restart $name"
}

repair_cmd() {
    local name="${1:-}"
    [[ -n "$name" ]] || abort "用法: cf repair <隧道名>"
    ensure_cloudflared

    local cfg="${CLOUDFLARED_HOME}/${name}.yml"
    [[ -f "$cfg" ]] || abort "配置文件不存在: $cfg"

    if grep -qE '^url:' "$cfg"; then
        ui_print "无需修复，$name 已为标准格式"
        return 0
    fi

    local id cred url
    id="$(read_tunnel_id_from_yml "$cfg")"
    cred="$(read_credentials_from_yml "$cfg")"
    url="$(awk '/service:/{print $2; exit}' "$cfg")"
    [[ -z "$id" ]] && abort "无法识别 tunnel 字段，无法修复: $cfg"
    [[ -z "$cred" ]] && cred="${CLOUDFLARED_HOME}/${id}.json"
    [[ -z "$url" ]] && url="http://127.0.0.1:80"

    write_tunnel_yml "$name" "$id" "$url" "$cred" || abort "写入配置失败: $cfg"

    ui_print "已修复: $cfg"
}

enable_cmd() {
    local name="${1:-}"
    [[ -n "$name" ]] || abort "用法: cf enable <隧道名>"
    ensure_cloudflared
    check_login
    require_systemd

    local cfg="${CLOUDFLARED_HOME}/${name}.yml"
    [[ -f "$cfg" ]] || abort "配置文件不存在: $cfg"

    local svc
    svc="$(service_name "$name")"
    run_root systemctl daemon-reload
    run_root systemctl enable "$svc" || abort "启用服务失败: $svc"
    run_root systemctl start "$svc" || abort "启动服务失败: $svc"

    ui_print "已启用并启动: $name"
    run_root systemctl status "$svc" --no-pager -l
}

disable_cmd() {
    local name="${1:-}"
    [[ -n "$name" ]] || abort "用法: cf disable <隧道名>"
    require_systemd

    local svc
    svc="$(service_name "$name")"
    run_root systemctl stop "$svc" 2>/dev/null || true
    run_root systemctl disable "$svc" 2>/dev/null || true
    ui_print "已停用: $name"
}

restart_cmd() {
    local name="${1:-}"
    [[ -n "$name" ]] || abort "用法: cf restart <隧道名>"
    require_systemd

    local svc
    svc="$(service_name "$name")"
    run_root systemctl daemon-reload
    run_root systemctl restart "$svc" || abort "重启失败: $name"
    ui_print "已重启: $name"
    run_root systemctl status "$svc" --no-pager -l
}

stop_cmd() {
    local name="${1:-}"
    [[ -n "$name" ]] || abort "用法: cf stop <隧道名>"
    stop_local_tunnel_runtime "$name"
    ui_print "已停止: $name"
}

status_cmd() {
    local name="${1:-}"
    [[ -n "$name" ]] || abort "用法: cf status <隧道名>"
    require_systemd
    run_root systemctl status "$(service_name "$name")" --no-pager -l
}

logs_cmd() {
    local name="${1:-}"
    local lines="${2:-200}"
    [[ -n "$name" ]] || abort "用法: cf logs <隧道名> [行数]"
    require_systemd
    run_root journalctl -u "$(service_name "$name")" -n "$lines" -f --no-pager
}

info_cmd() {
    local name="${1:-}"
    [[ -n "$name" ]] || abort "用法: cf info <隧道名>"
    ensure_cloudflared

    local cfg="${CLOUDFLARED_HOME}/${name}.yml"
    [[ -f "$cfg" ]] || abort "配置文件不存在: $cfg"

    echo "本地配置: $cfg"
    echo "-----------------------------------"
    cat "$cfg"
    echo "-----------------------------------"

    local id
    id="$(read_tunnel_id_from_yml "$cfg")"
    if [[ -n "$id" ]]; then
        echo "远程信息:"
        "$CLOUDFLARED_BIN" tunnel info "$id" 2>/dev/null || true
    fi
}

patch_cmd() {
    local src
    src="$(readlink -f "$0")"
    run_root cp "$src" "$PATCH_TARGET" || abort "复制到 ${PATCH_TARGET} 失败"
    run_root chmod +x "$PATCH_TARGET"
    ui_print "安装成功，可直接使用:"
    echo "  cf --help"
}

usage() {
    cat <<'EOF'
cloudflared Tunnel 管理脚本（Debian）

用法:
  cf <命令> [参数]

基础:
  install
      安装 cloudflared（二进制+代理加速）
  patch
      安装本脚本为 /usr/local/bin/cf
  login
      登录 Cloudflare（生成 cert.pem）
  list
      查看远程隧道 + 本地配置/服务状态
  info <隧道名>
      查看配置与远程详情
  sync
      按远程隧道列表重新生成本地 yml 与 service 文件

隧道:
  create <隧道名> [穿透地址]
      创建隧道（创建前检查远端是否已存在同名）
  delete <隧道名1> [隧道名2 ...]
      删除隧道（删除前检查远端是否存在）
  rename <旧隧道名> <新隧道名>
      重命名隧道（远端+本地配置/服务同步改名）
  dns <隧道名> <域名>
      设置 DNS 记录
  set-url <隧道名> <穿透地址>
      修改 yml 的 url 字段
  repair <隧道名>
      将旧配置修复为标准格式（url/tunnel/credentials-file）

服务:
  enable <隧道名>
      启用并启动服务（开机自启）
  disable <隧道名>
      停止并禁用服务
  restart <隧道名>
      重启服务
  stop <隧道名>
      仅停止服务和本地进程
  status <隧道名>
      查看服务状态
  logs <隧道名> [行数]
      查看日志

其他:
  -h, --help
      查看此帮助
EOF
}

main() {
    ensure_home
    local cmd="${1:-}"
    [[ -z "$cmd" ]] && { usage; return 0; }
    shift || true

    case "$cmd" in
        install) ensure_cloudflared ;;
        patch) patch_cmd ;;
        login) ensure_cloudflared; login_cmd ;;
        list) ensure_cloudflared; list_cmd ;;
        info) ensure_cloudflared; info_cmd "$@" ;;
        create) ensure_cloudflared; create_cmd "$@" ;;
        delete) ensure_cloudflared; delete_cmd "$@" ;;
        rename) ensure_cloudflared; rename_cmd "$@" ;;
        sync) ensure_cloudflared; sync_cmd "$@" ;;
        dns) ensure_cloudflared; dns_cmd "$@" ;;
        set-url) ensure_cloudflared; set_url_cmd "$@" ;;
        repair) ensure_cloudflared; repair_cmd "$@" ;;
        enable) ensure_cloudflared; enable_cmd "$@" ;;
        disable) ensure_cloudflared; disable_cmd "$@" ;;
        restart) ensure_cloudflared; restart_cmd "$@" ;;
        stop) ensure_cloudflared; stop_cmd "$@" ;;
        status) ensure_cloudflared; status_cmd "$@" ;;
        logs) ensure_cloudflared; logs_cmd "$@" ;;
        -h|--help|"") usage ;;
        *)
            error "未知命令: $cmd"
            echo
            usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
