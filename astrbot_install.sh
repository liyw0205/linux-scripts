#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# 全局变量 (默认值，可通过命令行参数修改)
DEFAULT_PROJECT_NAME="AstrBot"
PROJECT_NAME="$DEFAULT_PROJECT_NAME"
DIR="" # 会在每次操作前根据 PROJECT_NAME 设置

# 带颜色的输出函数
ui_print() {
    local color=$1
    shift
    case $color in
        red) echo -e "${RED}$@${NC}" ;;
        green) echo -e "${GREEN}$@${NC}" ;;
        yellow) echo -e "${YELLOW}$@${NC}" ;;
        blue) echo -e "${BLUE}$@${NC}" ;;
        purple) echo -e "${PURPLE}$@${NC}" ;;
        cyan) echo -e "${CYAN}$@${NC}" ;;
        white) echo -e "${WHITE}$@${NC}" ;;
        *) echo -e " $@" ;;
    esac
}

# 显示操作状态的函数
show_status() {
    local operation=$1
    local status=$2
    if [ "$status" = "success" ]; then
        ui_print "green" "✓ $operation 成功"
    else
        ui_print "red" "✗ $operation 失败"
    fi
}

# 显示正在进行的操作
show_progress() {
    ui_print "blue" "正在 $1..."
}

# 读取用户输入的函数（带默认值）
read_or() {
    local var_name="$1"
    local prompt="$2"
    local default_value="$3"
    
    printf "$prompt (默认: $default_value): "
    read -r input
    if [[ -z "$input" ]]; then
        input="$default_value"
    fi
    eval "$var_name=\"$input\""
}

# 测试代理可用性和延迟的函数
test_proxy() {
    local proxy_url="$1"
    local target_host="github.com"
    
    # 从代理URL中提取主机名用于ping测试
    local proxy_host=$(echo "$proxy_url" | sed -E 's|^https?://([^/:]+).*|\1|')
    
    # 检查ping命令是否可用
    if ! command -v ping &> /dev/null; then
        ui_print "yellow" "警告: ping命令不可用，跳过网络连通性测试"
        return 0
    fi
    
    local ping_time
    
    # 如果不能直接ping通，尝试ping代理服务器本身
    if ping -c 1 -W 3 "$proxy_host" &> /dev/null; then
        # 计算ping延迟
        ping_time=$(ping -c 1 -W 3 "$proxy_host" | grep 'time=' | sed -E 's/.*time=([0-9.]+).*/\1/')
        
        # 如果没有获取到时间，给一个默认值
        if [[ -z "$ping_time" ]]; then
            ping_time="999"
        fi
        
        echo "$ping_time"
        return 0
    else
        echo "9999"
        return 1
    fi
}

# 获取可用代理列表并按延迟排序
get_available_proxies() {
    local proxies=(
        "https://gh-proxy.net/"
        "https://ghfile.geekertao.top/"
        "https://git.yylx.win/"
        "https://gh.llkk.cc/"
        "https://ghproxy.net/"
        "https://github.dpik.top/"
        "https://hub.gitmirror.com/"
        "https://gitproxy.click/"
    )
    
    local proxy_latency=()
    local total=${#proxies[@]}
    local current=0
    
    ui_print "yellow" "正在测试代理服务器连通性和延迟..."
    
    for proxy in "${proxies[@]}"; do
        current=$((current + 1))
        printf "\r${BLUE}进度: %d/%d - 测试 %s${NC}" "$current" "$total" "$proxy"
        
        latency=$(test_proxy "$proxy")
        proxy_latency+=("$latency:$proxy")
        
        # 使用compare_numbers函数进行数值比较
        if (( $(compare_numbers "$latency" "<" "999") )); then
            ui_print "green" "\n✓ $proxy 可达 (延迟: ${latency}ms)"
        else
            ui_print "red" "\n✗ $proxy 不可达"
        fi
    done
    
    echo
    echo
    
    # 过滤出可用的代理并按延迟排序
    local available_proxies_temp=() # Avoid conflict with global AVAILABLE_PROXIES
    for item in "${proxy_latency[@]}"; do
        latency=$(echo "$item" | cut -d':' -f1)
        proxy=$(echo "$item" | cut -d':' -f2-)
        # 使用compare_numbers函数进行数值比较
        if (( $(compare_numbers "$latency" "<" "999") )); then
            available_proxies_temp+=("$latency:$proxy")
        fi
    done
    
    # 按延迟排序
    IFS=$'\n' sorted_proxies_temp=($(sort -t: -k1 -n <<< "${available_proxies_temp[*]}"))
    unset IFS
    
    if [ ${#sorted_proxies_temp[@]} -eq 0 ]; then
        ui_print "red" "没有找到可用的代理服务器！"
        ui_print "yellow" "建议选择'不使用代理'或'自定义代理'"
        return 1
    else
        ui_print "green" "找到 ${#sorted_proxies_temp[@]} 个可用代理服务器（按延迟排序）："
        # 全局变量 AVAILABLE_PROXIES 和 sorted_proxies 用于保存结果
        AVAILABLE_PROXIES=()
        sorted_proxies=()
        for i in "${!sorted_proxies_temp[@]}"; do
            latency=$(echo "${sorted_proxies_temp[$i]}" | cut -d':' -f1)
            proxy=$(echo "${sorted_proxies_temp[$i]}" | cut -d':' -f2-)
            ui_print "cyan" "  $((i+1)). $proxy (延迟: ${latency}ms)"
            
            # 存储到全局变量
            AVAILABLE_PROXIES+=("$proxy")
            sorted_proxies+=("$latency:$proxy")
        done
        echo
        return 0
    fi
}

check_bc_command() {
    if ! command -v bc &> /dev/null; then
        ui_print "yellow" "检测到bc命令不可用，正在尝试安装..."
        
        if command -v apt &> /dev/null; then
            apt update && apt install -y bc > /dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y bc > /dev/null 2>&1
        elif command -v dnf &> /dev/null; then
            dnf install -y bc > /dev/null 2>&1
        else
            ui_print "yellow" "无法自动安装bc，将使用awk进行数值比较"
            return 1
        fi
        
        if command -v bc &> /dev/null; then
            ui_print "green" "✓ bc安装成功"
            return 0
        else
            ui_print "yellow" "bc安装失败，将使用awk进行数值比较"
            return 1
        fi
    fi
    return 0
}

# 数值比较函数（兼容没有bc的情况）
compare_numbers() {
    local num1=$1
    local operator=$2
    local num2=$3
    
    if command -v bc &> /dev/null; then
        echo "$num1 $operator $num2" | bc -l
    else
        # 使用awk进行比较
        # awk return 0 for true, 1 for false; shell uses 0 for success, non-zero for failure
        awk "BEGIN {exit ! ($num1 $operator $num2)}"
    fi
}


# 询问用户是否使用代理
get_proxy_choice() {
    ui_print "yellow" "请选择是否使用 Git / 下载代理："
    ui_print "white" "1：自动选择延迟最低的可用代理（默认）"
    ui_print "white" "2：从可用代理中选择特定代理"
    ui_print "white" "3：不使用代理"
    ui_print "white" "4：自定义代理地址"
    echo

    read_or PROXY_CHOICE "请选择代理选项 (1-4)" "1"

    PROXY=""
    case "$PROXY_CHOICE" in
        1)
            check_bc_command
            if get_available_proxies; then
                # 选择延迟最低的代理
                PROXY="${AVAILABLE_PROXIES[0]}"
                latency=$(echo "${sorted_proxies[0]}" | cut -d':' -f1)
                ui_print "green" "✓ 自动选择最低延迟代理：$PROXY (延迟: ${latency}ms)"
            else
                ui_print "yellow" "未找到可用代理，将不使用代理"
            fi
            ;;
        2)
            check_bc_command
            if get_available_proxies; then
                echo
                read_or PROXY_INDEX "请选择代理编号 (1-${#AVAILABLE_PROXIES[@]})" "1"
                if [[ "$PROXY_INDEX" =~ ^[0-9]+$ ]] && [ "$PROXY_INDEX" -ge 1 ] && [ "$PROXY_INDEX" -le ${#AVAILABLE_PROXIES[@]} ]; then
                    PROXY="${AVAILABLE_PROXIES[$((PROXY_INDEX-1))]}"
                    # 显示选中代理的延迟
                    # sorted_proxies 是一个全局数组，存储了 "latency:proxy_url" 格式的字符串
                    # 通过索引找到对应项
                    local selected_item="${sorted_proxies[$((PROXY_INDEX-1))]}"
                    local latency_selected=$(echo "$selected_item" | cut -d':' -f1)
                    ui_print "green" "✓ 已选择代理：$PROXY (延迟: ${latency_selected}ms)"
                else
                    ui_print "red" "无效选择，将不使用代理"
                fi
            else
                ui_print "yellow" "未找到可用代理，将不使用代理"
                ui_print "cyan" "提示: 在Termux/proot环境中，GitHub可能可以直接访问"
            fi
            ;;
        3)
            ui_print "green" "✓ 不使用代理"
            ;;
        4)
            read_or CUSTOM_PROXY "请输入自定义代理地址" ""
            if [[ -n "$CUSTOM_PROXY" ]]; then
                # 测试自定义代理
                ui_print "blue" "正在测试自定义代理..."
                check_bc_command
                latency=$(test_proxy "$CUSTOM_PROXY")
                if (( $(compare_numbers "$latency" "<" "999") )); then
                    PROXY="$CUSTOM_PROXY"
                    ui_print "green" "✓ 自定义代理可用：$PROXY (延迟: ${latency}ms)"
                else
                    ui_print "red" "✗ 自定义代理不可用，将不使用代理"
                fi
            else
                ui_print "yellow" "未输入代理地址，将不使用代理"
            fi
            ;;
        *)
            ui_print "yellow" "无效选择，将不使用代理"
            ;;
    esac
}

# 下载release资源文件（支持代理重试）
download_release_resource() {
    local release_url="$1"
    local download_path="$2"
    local proxy_urls_str="$3" # 传入的是字符串，需要解析为数组
    
    show_progress "下载release资源文件"
    
    local proxy_array=()
    # 如果 proxy_urls_str 包含多个以空格分隔的代理 URL
    if [[ -n "$proxy_urls_str" ]]; then
        # 使用 IFS 将字符串拆分为数组
        IFS=' ' read -r -a proxy_array <<< "$proxy_urls_str"
    fi

    local success=false
    
    # 尝试所有可用的代理（包括空代理，即直接下载）
    # 如果 proxy_array 为空，则只尝试直接下载
    if [ ${#proxy_array[@]} -eq 0 ]; then
        proxy_array=("") # 强制进行一次直接下载尝试
    fi

    for proxy_url in "${proxy_array[@]}"; do
        local current_download_url
        if [[ -n "$proxy_url" ]]; then
            current_download_url="${proxy_url}${release_url}"
            ui_print "cyan" "尝试代理下载 ($proxy_url): $current_download_url"
        else
            current_download_url="$release_url"
            ui_print "cyan" "尝试直接下载: $current_download_url"
        fi
        
        # 使用wget或curl下载文件
        if command -v wget &> /dev/null; then
            if wget -O "$download_path" "$current_download_url"; then
                show_status "下载release资源文件" "success"
                success=true
                break
            else
                ui_print "yellow" "下载失败，尝试下一个方式..."
                # 删除可能的部分下载文件
                rm -f "$download_path" 2>/dev/null
            fi
        elif command -v curl &> /dev/null; then
            if curl -L -o "$download_path" "$current_download_url"; then
                show_status "下载release资源文件" "success"
                success=true
                break
            else
                ui_print "yellow" "下载失败，尝试下一个方式..."
                # 删除可能的部分下载文件
                rm -f "$download_path" 2>/dev/null
            fi
        else
            ui_print "red" "错误: 未找到wget或curl命令"
            return 1
        fi
    done
    
    if $success; then
        return 0
    fi
    
    show_status "下载release资源文件" "failure"
    return 1
}

# 停止并删除 screen 会话
stop_screen_session() {
    local screen_name="$1"
    if screen -list | grep -q "$screen_name"; then
        ui_print "yellow" "正在停止 screen 会话 '$screen_name'..."
        screen -X -S "$screen_name" quit > /dev/null 2>&1
        sleep 2 # 给一点时间让会话结束
        if screen -list | grep -q "$screen_name"; then
            ui_print "red" "警告: 无法停止 screen 会话 '$screen_name'，尝试强制杀死。"
            kill $(screen -list | grep "$screen_name" | awk '{print $1}' | cut -d'.' -f1) > /dev/null 2>&1
            sleep 2
        fi
        if ! screen -list | grep -q "$screen_name"; then
            show_status "停止 screen 会话 '$screen_name'" "success"
        else
            show_status "停止 screen 会话 '$screen_name'" "failure"
        fi
    else
        ui_print "green" "screen 会话 '$screen_name' 未运行或不存在。"
    fi
}

# ==============================================================================
# 安装函数
# ==============================================================================
install_project() {
    ui_print "yellow" "正在执行项目安装..."

    # 检查并创建安装目录
    if [[ -d "$DIR" ]]; then
        ui_print "red" "安装目录已存在：$DIR"
        ui_print "yellow" "请先运行 './install.sh uninstall $PROJECT_NAME' 或手动删除后重试。"
        return 127
    else
        show_progress "克隆 Git 仓库"
        cd /root || { show_status "进入 /root 目录" "failure"; return 127; }

        local git_clone_url="https://github.com/AstrBotDevs/AstrBot.git"
        if [[ -n "$PROXY" ]]; then
            ui_print "cyan" "正在使用代理克隆 Git 仓库: $git_clone_url (代理: $PROXY)"
            # Git 代理设置 (临时)
            # 注意: 这里只支持 HTTP/HTTPS 代理，对于 SSH URL 不起作用
            # 如果是 HTTPS URL，可以使用 all.http.proxy
            git config --global http.proxy "$PROXY"
            git config --global https.proxy "$PROXY"
        fi

        if git clone "$git_clone_url" "$PROJECT_NAME"; then
            show_status "克隆 Git 仓库" "success"
        else
            show_status "克隆 Git 仓库" "failure"
            if [[ -n "$PROXY" ]]; then
                 ui_print "red" "Git 克隆失败，请检查代理设置或尝试不使用代理。"
            else
                 ui_print "red" "Git 克隆失败，请检查网络连接或尝试使用代理。"
            fi
            # 尝试回滚代理设置
            git config --global --unset-all http.proxy >/dev/null 2>&1
            git config --global --unset-all https.proxy >/dev/null 2>&1
            return 127
        fi

        # 恢复 Git 代理设置
        if [[ -n "$PROXY" ]]; then
            git config --global --unset-all http.proxy >/dev/null 2>&1
            git config --global --unset-all https.proxy >/dev/null 2>&1
        fi

        cd "$DIR" || { show_status "进入安装目录 $DIR" "failure"; return 127; }
    fi

    # 系统依赖安装
    show_progress "更新系统及安装依赖"
    if command -v apt &> /dev/null; then
        # Debian/Ubuntu
        apt update && apt upgrade -y && apt install -y screen curl wget git python3 python3-pip python3-venv bc tar unzip
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL
        yum update -y && yum install -y screen curl wget git python3 python3-pip python3-virtualenv bc tar unzip
    elif command -v dnf &> /dev/null; then
        # Fedora
        dnf update -y && dnf install -y screen curl wget git python3 python3-pip python3-virtualenv bc tar unzip
    else
        ui_print "red" "不支持的包管理器，请手动安装必要的依赖。"
        return 127
    fi
    if [ $? -eq 0 ]; then
        show_status "系统更新及依赖安装" "success"
    else
        show_status "系统更新及依赖安装" "failure"
        return 127
    fi

    # 设置时区
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    show_status "设置时区为 Asia/Shanghai (上海)" "success"

    # 询问代理选择
    get_proxy_choice

    mkdir -p "$DIR/data"

    # Release资源下载配置
    REPO_OWNER="AstrBotDevs"
    REPO_NAME="AstrBot"

    # 获取最新的Release版本
    show_progress "获取最新Release版本信息"
    API_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    
    local api_curl_cmd="curl -s"
    if [[ -n "$PROXY" ]]; then
        # 对于 API 请求，如果设置了全局代理，curl 会自动使用
        # 如果 curl 需要指定代理，可以加上 -x 或 --proxy
        # 例如：api_curl_cmd="curl -s -x $PROXY"
        ui_print "cyan" "正在尝试使用代理访问 GitHub API..."
    fi

    LATEST_TAG=$($api_curl_cmd "$API_URL" | grep -oP '"tag_name": "\K[^"]+')

    if [[ -n "$LATEST_TAG" ]]; then
        RELEASE_TAG="$LATEST_TAG"
        ui_print "green" "✓ 获取到最新Release版本: $RELEASE_TAG"
    else
        ui_print "red" "✗ 无法获取最新Release版本，将使用默认值 v4.19.4"
        RELEASE_TAG="v4.19.4" # 回退到已知的稳定版本
    fi

    RELEASE_ASSET="AstrBot-$RELEASE_TAG-dashboard.zip" # release资源文件名，根据最新标签构建

    # 构建release下载URL
    RELEASE_URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$RELEASE_TAG/$RELEASE_ASSET"

    TEMP_DOWNLOAD_PATH="$DIR/data/${RELEASE_ASSET}"

    # 根据代理选择决定使用单个代理还是所有可用代理
    if [[ "$PROXY_CHOICE" == "1" && -n "${AVAILABLE_PROXIES[*]}" ]]; then 
        # 自动选择模式：使用所有可用代理进行重试
        PROXY_FOR_DOWNLOAD="${AVAILABLE_PROXIES[*]}" # 转换为字符串，download_release_resource 会解析
        ui_print "green" "✓ 将按顺序尝试所有可用代理（${#AVAILABLE_PROXIES[@]}个）"
    elif [[ -n "$PROXY" ]]; then
        # 单个代理模式 (或自定义代理)
        PROXY_FOR_DOWNLOAD="$PROXY"
    else
        # 无代理模式
        PROXY_FOR_DOWNLOAD=""
    fi

    # 下载release资源文件（支持代理重试）
    if ! download_release_resource "$RELEASE_URL" "$TEMP_DOWNLOAD_PATH" "$PROXY_FOR_DOWNLOAD"; then
        ui_print "red" "所有下载方式均失败，请检查网络连接"
        return 127
    fi

    # 解压release资源文件
    unzip -o "$TEMP_DOWNLOAD_PATH" -d "$DIR/data" # -o 选项表示覆盖现有文件
    if [ $? -eq 0 ]; then
        show_status "解压release资源文件" "success"
    else
        show_status "解压release资源文件" "failure"
        return 127
    fi

    # 清理临时文件
    rm -f "$TEMP_DOWNLOAD_PATH" > /dev/null 2>&1 # 删除下载的zip文件
    show_status "清理临时文件" "success"

    # 创建 Python 虚拟环境并安装依赖
    show_progress "创建 Python 虚拟环境 myenv"
    python3 -m venv "$DIR"/myenv > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        show_status "创建 Python 虚拟环境 myenv" "success"
    else
        show_status "创建 Python 虚拟环境 myenv" "failure"
        return 127
    fi

    # 创建启动脚本
    cat <<EOF> "/bin/${PROJECT_NAME}_start"
export TZ=Asia/Shanghai
source "$DIR"/myenv/bin/activate
cd "$DIR"
export ASTRBOT_RELOAD=1
python main.py
EOF

    source "$DIR"/myenv/bin/activate > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        show_status "激活 Python 虚拟环境" "failure"
        return 127
    fi
    show_status "激活 Python 虚拟环境" "success"

    pip config set global.index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        show_status "设置 pip 镜像源为清华源" "success"
    else
        ui_print "yellow" "设置 pip 镜像源为清华源"
        show_status "设置 pip 镜像源为清华源" "failure"
    fi

    cd "$DIR" || {
        show_status "进入安装目录 $DIR" "failure"
        return 127
    }
    show_status "进入安装目录 $DIR" "success"

    # 尝试安装 uv，如果失败则回退到 pip
    # 确保 uv 本身是安装在系统环境或者在虚拟环境激活前就安装好了
    show_progress "安装 Python 依赖项"
    if command -v uv &> /dev/null && uv sync > /dev/null 2>&1; then
        show_status "使用 uv 安装依赖项" "success"
    else
        ui_print "yellow" "uv sync 失败或 uv 未安装，尝试使用 pip 安装依赖..."
        if pip install -r requirements.txt > /dev/null 2>&1; then
            show_status "使用 pip 安装依赖项（来自 requirements.txt）" "success"
        else
            show_status "安装依赖项（来自 requirements.txt）" "failure"
            return 127
        fi
    fi

    chmod +x "/bin/${PROJECT_NAME}_start"

    show_status "创建启动脚本 /bin/${PROJECT_NAME}_start" "success"

    # 获取公网IPv4地址
    IPV4=$(curl -s ifconfig.me 2> /dev/null)

    # 安装完成提示
    ui_print "green" "========================================"
    ui_print "green" "✓ 项目安装完成！"
    ui_print "green" "项目名称: $PROJECT_NAME"
    ui_print "green" "安装目录: $DIR"
    ui_print "green" "WebUI地址"
    ui_print "white" "    http://${IPV4}:6185"

    ui_print "yellow" "你可以通过以下命令启动项目："
    ui_print "white" "    screen -dmS ${PROJECT_NAME} /bin/${PROJECT_NAME}_start"
    ui_print "yellow" "进入会话管理：screen -r ${PROJECT_NAME}"
    ui_print "yellow" "退出会话但不关闭程序：Ctrl+A D"
    ui_print "yellow" "要停止服务，请进入screen会话，然后按 Ctrl+C 停止。"
    ui_print "yellow" "首次启动后，请根据AstrBot的提示进行初始化配置。"
    ui_print "green" "========================================"
    return 0
}

# ==============================================================================
# 卸载函数
# ==============================================================================
uninstall_project() {
    ui_print "red" "警告: 您正在卸载项目 '$PROJECT_NAME'！这将删除所有相关文件。"
    read -p "确定要继续吗？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        ui_print "yellow" "操作已取消。"
        return 1
    fi

    if [[ ! -d "$DIR" ]]; then
        ui_print "yellow" "项目目录 '$DIR' 不存在，无需卸载。"
        return 0
    fi

    stop_screen_session "$PROJECT_NAME"

    show_progress "删除启动脚本 /bin/${PROJECT_NAME}_start"
    if rm -f "/bin/${PROJECT_NAME}_start"; then
        show_status "删除启动脚本" "success"
    else
        show_status "删除启动脚本" "failure"
    fi

    show_progress "删除项目目录 $DIR"
    if rm -rf "$DIR"; then
        show_status "删除项目目录" "success"
    else
        show_status "删除项目目录" "failure"
        ui_print "red" "可能需要手动删除目录 '$DIR'。"
        return 1
    fi

    ui_print "green" "项目 '$PROJECT_NAME' 已成功卸载。"
    return 0
}

# ==============================================================================
# 更新函数
# ==============================================================================
# 使用代理列表轮询 git pull，全部失败后直连
git_pull_with_fallback() {
    local repo_dir="$1"
    local proxy_urls_str="$2"   # 空格分隔代理列表
    local success=false

    cd "$repo_dir" || return 1

    local proxy_array=()
    if [[ -n "$proxy_urls_str" ]]; then
        IFS=' ' read -r -a proxy_array <<< "$proxy_urls_str"
    fi

    # 逐个代理尝试 pull
    for proxy_url in "${proxy_array[@]}"; do
        [[ -z "$proxy_url" ]] && continue

        ui_print "cyan" "尝试代理 pull: $proxy_url"
        git config --local http.proxy "$proxy_url"
        git config --local https.proxy "$proxy_url"

        if git pull; then
            ui_print "green" "✓ 代理 pull 成功: $proxy_url"
            success=true
            break
        else
            ui_print "yellow" "✗ 代理 pull 失败: $proxy_url，切换下一个..."
            git config --local --unset-all http.proxy >/dev/null 2>&1
            git config --local --unset-all https.proxy >/dev/null 2>&1
        fi
    done

    # 清理代理配置
    git config --local --unset-all http.proxy >/dev/null 2>&1
    git config --local --unset-all https.proxy >/dev/null 2>&1

    # 全部代理失败后直连
    if ! $success; then
        ui_print "yellow" "所有代理 pull 均失败，尝试直连 pull..."
        if git pull; then
            ui_print "green" "✓ 直连 pull 成功"
            success=true
        else
            ui_print "red" "✗ 直连 pull 也失败"
        fi
    fi

    $success
}

# ==============================================================================
# 更新函数（完整替换）
# ==============================================================================
update_project() {
    ui_print "yellow" "正在更新项目 '$PROJECT_NAME'..."

    if [[ ! -d "$DIR" ]]; then
        ui_print "red" "项目目录 '$DIR' 不存在，无法更新。请先安装项目。"
        return 1
    fi

    # 先选择代理（让 pull / API / release 下载共用）
    get_proxy_choice

    # 自动模式下，提前探测可用代理（供 pull 与下载轮询）
    if [[ "$PROXY_CHOICE" == "1" ]]; then
        check_bc_command
        get_available_proxies || true
    fi

    stop_screen_session "$PROJECT_NAME"

    cd "$DIR" || { show_status "进入项目目录 $DIR" "failure"; return 1; }

    show_progress "拉取 Git 仓库最新代码"
    local git_pull_succeeded=false

    # 为 pull 构建代理列表：自动模式=全部可用代理；手选/自定义=单个代理；不使用=空
    local PROXY_FOR_PULL=""
    if [[ "$PROXY_CHOICE" == "1" && ${#AVAILABLE_PROXIES[@]} -gt 0 ]]; then
        PROXY_FOR_PULL="${AVAILABLE_PROXIES[*]}"
    elif [[ "$PROXY_CHOICE" == "2" || "$PROXY_CHOICE" == "4" ]]; then
        [[ -n "$PROXY" ]] && PROXY_FOR_PULL="$PROXY"
    fi

    if git_pull_with_fallback "$DIR" "$PROXY_FOR_PULL"; then
        show_status "拉取 Git 仓库最新代码" "success"
        git_pull_succeeded=true
    else
        show_status "拉取 Git 仓库最新代码" "failure"
        ui_print "red" "Git pull 最终失败。请检查网络或仓库状态。"
        # 继续后续流程（尽量更新 dashboard 和依赖）
    fi

    # 获取最新的Release版本
    REPO_OWNER="AstrBotDevs"
    REPO_NAME="AstrBot"
    show_progress "获取最新Release版本信息用于更新 Dashboard"
    API_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    
    local api_curl_cmd="curl -s"
    if [[ -n "$PROXY" ]]; then
        ui_print "cyan" "正在尝试使用代理访问 GitHub API..."
    fi

    LATEST_TAG=$($api_curl_cmd "$API_URL" | grep -oP '"tag_name": "\K[^"]+')

    if [[ -n "$LATEST_TAG" ]]; then
        RELEASE_TAG="$LATEST_TAG"
        ui_print "green" "✓ 获取到最新Release版本: $RELEASE_TAG"
    else
        ui_print "red" "✗ 无法获取最新Release版本，将使用当前版本进行更新，Dashboard可能不会更新"
        if [[ -f "$DIR/data/version.txt" ]]; then
            RELEASE_TAG=$(cat "$DIR/data/version.txt" | head -n 1)
            ui_print "yellow" "使用本地检测到的版本 $RELEASE_TAG"
        else
            ui_print "red" "无法获取当前版本，Dashboard更新将被跳过。"
            RELEASE_TAG=""
        fi
    fi
    
    if [[ -n "$RELEASE_TAG" ]]; then
        RELEASE_ASSET="AstrBot-$RELEASE_TAG-dashboard.zip"
        RELEASE_URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$RELEASE_TAG/$RELEASE_ASSET"
        TEMP_DOWNLOAD_PATH="$DIR/data/${RELEASE_ASSET}"

        # 下载代理策略：自动模式用全部可用代理轮询；否则用单个代理；都没有则直连
        local PROXY_FOR_DOWNLOAD=""
        if [[ "$PROXY_CHOICE" == "1" && ${#AVAILABLE_PROXIES[@]} -gt 0 ]]; then 
            PROXY_FOR_DOWNLOAD="${AVAILABLE_PROXIES[*]}"
        elif [[ -n "$PROXY" ]]; then
            PROXY_FOR_DOWNLOAD="$PROXY"
        fi

        if download_release_resource "$RELEASE_URL" "$TEMP_DOWNLOAD_PATH" "$PROXY_FOR_DOWNLOAD"; then
            unzip -o "$TEMP_DOWNLOAD_PATH" -d "$DIR/data"
            if [ $? -eq 0 ]; then
                show_status "更新并解压 Dashboard 资源" "success"
                rm -f "$TEMP_DOWNLOAD_PATH" > /dev/null 2>&1
            else
                show_status "更新并解压 Dashboard 资源" "failure"
            fi
        else
            ui_print "red" "Dashboard 资源下载失败，Dashboard 未更新。"
        fi
    else
        ui_print "yellow" "未找到 Dashboard 最新版本或无法下载，Dashboard 更新已跳过。"
    fi

    # 更新 Python 虚拟环境及依赖
    show_progress "更新 Python 虚拟环境及依赖"
    source "$DIR"/myenv/bin/activate > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        show_status "激活 Python 虚拟环境" "failure"
        ui_print "red" "无法激活虚拟环境，依赖更新失败。"
        return 1
    fi
    show_status "激活 Python 虚拟环境" "success"

    pip config set global.index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        show_status "设置 pip 镜像源为清华源" "success"
    else
        show_status "设置 pip 镜像源为清华源" "failure"
    fi

    if command -v uv &> /dev/null && uv sync > /dev/null 2>&1; then
        show_status "使用 uv 更新依赖项" "success"
    else
        ui_print "yellow" "uv sync 失败或 uv 未安装，尝试使用 pip 更新依赖..."
        if pip install -r requirements.txt > /dev/null 2>&1; then
            show_status "使用 pip 更新依赖项（来自 requirements.txt）" "success"
        else
            show_status "更新依赖项（来自 requirements.txt）" "failure"
            ui_print "red" "依赖项更新失败。项目可能无法正常启动。"
            return 1
        fi
    fi

    ui_print "green" "项目 '$PROJECT_NAME' 更新完成！"
    ui_print "yellow" "您可以通过以下命令重新启动项目："
    ui_print "white" "    screen -dmS ${PROJECT_NAME} /bin/${PROJECT_NAME}_start"
    ui_print "yellow" "或进入会话手动启动：screen -r ${PROJECT_NAME}"
    return 0
}

# ==============================================================================
# 使用说明
# ==============================================================================
usage() {
    ui_print "white" "用法: $0 <命令> [项目名称]"
    ui_print "white" "命令:"
    ui_print "cyan" "  install [项目名称]  - 安装 Astrobot 项目。可选参数 [项目名称] 来指定安装目录和 screen 会话名称。"
    ui_print "cyan" "                    (默认项目名称: ${DEFAULT_PROJECT_NAME})"
    ui_print "cyan" "  uninstall [项目名称] - 卸载 Astrobot 项目。可选参数 [项目名称] 来指定要卸载的项目。"
    ui_print "cyan" "  update [项目名称]   - 更新 Astrobot 项目 (Git pull 和重新安装依赖)。可选参数 [项目名称] 来指定要更新的项目。"
    ui_print "white" ""
    ui_print "white" "示例:"
    ui_print "green" "  $0 install           # 安装默认项目名称 (AstrBot)"
    ui_print "green" "  $0 install MyBot     # 安装名为 MyBot 的项目"
    ui_print "green" "  $0 update            # 更新默认项目名称 (AstrBot)"
    ui_print "green" "  $0 uninstall MyBot   # 卸载名为 MyBot 的项目"
    exit 1
}

# ==============================================================================
# 主逻辑
# ==============================================================================

# 解析命令行参数
COMMAND="$1"
if [ -n "$2" ]; then
    PROJECT_NAME="$2"
fi
DIR="/root/$PROJECT_NAME"

# 在执行命令前，检查是否需要 bc
check_bc_command


case "$COMMAND" in
    install)
        if [ -n "$2" ]; then
            ui_print "green" "使用自定义项目名称: $PROJECT_NAME"
        else
            ui_print "yellow" "使用默认项目名称: $PROJECT_NAME"
        fi
        install_project
        ;;
    uninstall)
        if [ -n "$2" ]; then
            ui_print "green" "正在准备卸载项目: $PROJECT_NAME"
        else
            ui_print "yellow" "使用默认项目名称: $PROJECT_NAME"
        fi
        uninstall_project
        ;;
    update)
        if [ -n "$2" ]; then
            ui_print "green" "正在准备更新项目: $PROJECT_NAME"
        else
            ui_print "yellow" "使用默认项目名称: $PROJECT_NAME"
        fi
        update_project
        ;;
    *)
        usage
        ;;
esac