#!/usr/bin/env bash
# AstrBot 管理脚本（单文件备份版）
# 备份: 复制本文件即可
# 部署: bash /root/astr.sh deploy
# 或:   /root/astr.sh deploy

set -euo pipefail

APP_DIR="${ASTR_APP_DIR:-/root/AstrBot}"
VENV_DIR="${ASTR_VENV_DIR:-/root/myenv}"
APP_PID_FILE="${ASTR_APP_PID_FILE:-${APP_DIR}/astr.pid}"
SUPERVISOR_PID_FILE="${ASTR_SUPERVISOR_PID_FILE:-${APP_DIR}/astr-supervisor.pid}"
STOP_FILE="${ASTR_STOP_FILE:-${APP_DIR}/astr.stop}"
LOG_FILE="${ASTR_LOG_FILE:-${APP_DIR}/astr.log}"
LOG_MAX_SIZE_MB="${ASTR_LOG_MAX_SIZE_MB:-50}"
PYTHON="${ASTR_PYTHON:-${VENV_DIR}/bin/python}"
RESTART_DELAY="${ASTR_RESTART_DELAY:-3}"
SELF="${ASTR_SELF:-${BASH_SOURCE[0]}}"
SCREEN_SESSION="${ASTR_SCREEN_SESSION:-AstrBot}"

usage() {
    cat <<EOF
用法:
  astr start                  使用 screen 守护启动 AstrBot
  astr stop                   停止 AstrBot
  astr restart                重启 AstrBot
  astr status                 查看状态
  astr log                    查看并跟随日志
  astr install                安装依赖、克隆仓库并创建虚拟环境
  astr patch                  更新 AstrBot 代码并刷新 Python 依赖
  astr deploy                 将本脚本安装到系统命令 (默认 /usr/local/bin/astr)

screen 会话名: ${SCREEN_SESSION}
目录: ${APP_DIR}
虚拟环境: ${VENV_DIR}
EOF
}

read_pid_file() {
    local file="$1"
    local pid

    [[ -f "${file}" ]] || return 1
    IFS= read -r pid < "${file}" || true
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${pid}"
}

read_app_pid() {
    read_pid_file "${APP_PID_FILE}"
}

read_supervisor_pid() {
    read_pid_file "${SUPERVISOR_PID_FILE}"
}

is_running() {
    local pid="${1:-}"
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}


rotate_log_if_needed() {
    local log_file="${1:-${LOG_FILE}}"
    local max_mb="${2:-${LOG_MAX_SIZE_MB}}"
    local max_bytes size human_size

    [[ "${max_mb}" =~ ^[0-9]+$ ]] || max_mb=50
    max_bytes=$((max_mb * 1024 * 1024))

    [[ -f "${log_file}" ]] || return 0

    size="$(stat -c%s "${log_file}" 2>/dev/null || echo 0)"
    [[ "${size}" =~ ^[0-9]+$ ]] || size=0
    (( size < max_bytes )) && return 0

    if command -v numfmt >/dev/null 2>&1; then
        human_size="$(numfmt --to=iec-i --suffix=B "${size}" 2>/dev/null || echo "${size}B")"
    else
        human_size="${size} bytes"
    fi

    : > "${log_file}"
    printf '[%s] Log rotated: previous size %s exceeded %sMB limit; log truncated.\n'         "$(date '+%Y-%m-%d %H:%M:%S')" "${human_size}" "${max_mb}" >> "${log_file}"
}

log_event() {
    rotate_log_if_needed
    mkdir -p "$(dirname "${LOG_FILE}")"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}"
}


install_astr() {
    local repo_url="${ASTR_REPO_URL:-https://github.com/AstrBotDevs/AstrBot.git}"
    local base_dir
    base_dir="$(dirname "${APP_DIR}")"
    local venv_parent
    venv_parent="$(dirname "${VENV_DIR}")"
    local venv_name
    venv_name="$(basename "${VENV_DIR}")"

    echo "开始安装 AstrBot..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y git python3 python3-pip python3-venv screen
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y git python3 python3-pip screen
    else
        echo "请手动安装 git、python3、python3-venv、screen 后重试" >&2
        return 1
    fi

    if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
        echo "创建虚拟环境: ${VENV_DIR}"
        python3 -m venv "${VENV_DIR}"
    fi

    if [[ ! -d "${APP_DIR}/.git" ]]; then
        if [[ -d "${APP_DIR}" && -n "$(ls -A "${APP_DIR}" 2>/dev/null || true)" ]]; then
            echo "目录已存在且非空: ${APP_DIR}，跳过 git clone" >&2
        else
            mkdir -p "${base_dir}"
            git clone "${repo_url}" "${APP_DIR}"
        fi
    else
        echo "仓库已存在: ${APP_DIR}"
    fi

    if [[ ! -f "${APP_DIR}/requirements.txt" ]]; then
        echo "未找到 ${APP_DIR}/requirements.txt" >&2
        return 1
    fi

    # shellcheck disable=SC1091
    source "${VENV_DIR}/bin/activate"
    pip install -U pip
    pip install -r "${APP_DIR}/requirements.txt"
    echo "AstrBot 安装完成"
    echo "启动: astr start"
}

patch_astr() {
    if [[ ! -d "${APP_DIR}/.git" ]]; then
        echo "未找到 Git 仓库: ${APP_DIR}，请先执行 astr install" >&2
        return 1
    fi
    if [[ ! -x "${VENV_DIR}/bin/pip" ]]; then
        echo "未找到虚拟环境: ${VENV_DIR}，请先执行 astr install" >&2
        return 1
    fi

    echo "更新 AstrBot 代码与依赖..."
    git -C "${APP_DIR}" pull --ff-only || git -C "${APP_DIR}" pull
    # shellcheck disable=SC1091
    source "${VENV_DIR}/bin/activate"
    pip install -U pip
    pip install -r "${APP_DIR}/requirements.txt"
    echo "AstrBot patch 完成"
}

deploy_astr() {
    local install_path="${ASTR_INSTALL_PATH:-/usr/local/bin/astr}"
    local source_path="${SELF}"

    if [[ ! -f "${source_path}" ]]; then
        echo "无法定位脚本自身: ${source_path}" >&2
        return 1
    fi

    install -m 755 "${source_path}" "${install_path}"
    echo "已部署到: ${install_path}"
    echo "可直接使用: astr <command>"
}


check_paths() {
    if [[ ! -d "${APP_DIR}" ]]; then
        echo "AstrBot directory not found: ${APP_DIR}" >&2
        exit 1
    fi
    if [[ ! -x "${PYTHON}" ]]; then
        echo "Python not found in virtualenv: ${PYTHON}" >&2
        exit 1
    fi
}

wait_for_exit() {
    local pid="${1:-}"
    local i
    for i in {1..20}; do
        if ! is_running "${pid}"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

current_pgid() {
    local pid="${1:-}"
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    ps -o pgid= -p "${pid}" 2>/dev/null | tr -d '[:space:]' || true
}

require_screen() {
    if ! command -v screen >/dev/null 2>&1; then
        echo "screen not found, please install screen first" >&2
        exit 1
    fi
}

screen_session_exists() {
    local session="${1:-${SCREEN_SESSION}}"
    local listing

    command -v screen >/dev/null 2>&1 || return 1
    listing="$(screen -ls 2>/dev/null || true)"

    printf '%s\n' "${listing}" | awk -v name="${session}" '
        {
            session_name = $1
            sub(/^[0-9]+\./, "", session_name)
            if (session_name == name) found = 1
        }
        END { exit found ? 0 : 1 }
    '
}

stop_screen_session() {
    local session="${1:-${SCREEN_SESSION}}"

    screen_session_exists "${session}" || return 0
    screen -S "${session}" -X quit >/dev/null 2>&1 || true
}

start_screen_supervisor() {
    require_screen

    screen -dmS "${SCREEN_SESSION}" bash -c '
while true; do
    "$0" rotate-log
    "$0" supervise >> "$2" 2>&1
    code=$?
    if [[ -f "$1" ]]; then
        exit 0
    fi
    printf "[%s] AstrBot supervise exited with code %s, restarting in 3s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$code" >> "$2"
    sleep 3
done
' "${SELF}" "${STOP_FILE}" "${LOG_FILE}"
}

terminate_process() {
    local pid="${1:-}"
    local pgid
    if ! is_running "${pid}"; then
        return 0
    fi

    pgid="$(current_pgid "${pid}" || true)"
    if [[ -n "${pgid}" && "${pgid}" == "${pid}" ]]; then
        kill -- "-${pgid}" 2>/dev/null || kill "${pid}" 2>/dev/null || true
    else
        kill "${pid}" 2>/dev/null || true
    fi
    if wait_for_exit "${pid}"; then
        return 0
    fi

    if [[ -n "${pgid}" && "${pgid}" == "${pid}" ]]; then
        kill -9 -- "-${pgid}" 2>/dev/null || kill -9 "${pid}" 2>/dev/null || true
    else
        kill -9 "${pid}" 2>/dev/null || true
    fi
    wait_for_exit "${pid}" || true
}

stop_app() {
    local pid
    pid="$(read_app_pid || true)"
    if is_running "${pid}"; then
        terminate_process "${pid}"
    fi
    rm -f "${APP_PID_FILE}"
}

supervise() {
    check_paths
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "$$" > "${SUPERVISOR_PID_FILE}"

    shutdown_supervisor() {
        touch "${STOP_FILE}"
        stop_app || true
        rm -f "${SUPERVISOR_PID_FILE}"
        log_event "AstrBot supervisor stopped"
        exit 0
    }
    trap shutdown_supervisor TERM INT

    log_event "AstrBot supervisor started, pid=$$"
    while true; do
        if [[ -f "${STOP_FILE}" ]]; then
            shutdown_supervisor
        fi

        rotate_log_if_needed

        local existing_pid
        existing_pid="$(read_app_pid || true)"
        if is_running "${existing_pid}"; then
            log_event "Supervising existing AstrBot process, pid=${existing_pid}"
            while is_running "${existing_pid}"; do
                if [[ -f "${STOP_FILE}" ]]; then
                    shutdown_supervisor
                fi
                sleep 2
            done
            rm -f "${APP_PID_FILE}"
            log_event "AstrBot process exited unexpectedly, restarting in ${RESTART_DELAY}s"
            sleep "${RESTART_DELAY}"
            continue
        fi

        log_event "Starting AstrBot process"
        rotate_log_if_needed
        local exit_code
        if (
            cd "${APP_DIR}"
            source "${VENV_DIR}/bin/activate"
            setsid "${PYTHON}" -u main.py </dev/null >> "${LOG_FILE}" 2>&1 &
            echo "$!" > "${APP_PID_FILE}"
            wait "$!"
        ); then
            exit_code=0
        else
            exit_code=$?
        fi

        rm -f "${APP_PID_FILE}"
        if [[ -f "${STOP_FILE}" ]]; then
            shutdown_supervisor
        fi
        log_event "AstrBot process exited with code ${exit_code}, restarting in ${RESTART_DELAY}s"
        sleep "${RESTART_DELAY}"
    done
}

start() {
    check_paths

    local supervisor_pid
    supervisor_pid="$(read_supervisor_pid || true)"
    if is_running "${supervisor_pid}"; then
        local app_pid
        app_pid="$(read_app_pid || true)"
        if is_running "${app_pid}"; then
            echo "AstrBot daemon is already running, supervisor_pid=${supervisor_pid}, app_pid=${app_pid}"
        else
            echo "AstrBot daemon is already running, supervisor_pid=${supervisor_pid}"
        fi
        if screen_session_exists; then
            echo "screen session: ${SCREEN_SESSION}"
        else
            echo "screen session: not used yet; restart will move it into screen"
        fi
        exit 0
    fi

    if screen_session_exists; then
        echo "Found stale screen session: ${SCREEN_SESSION}, recreating it"
        stop_screen_session
        sleep 0.5
    fi

    rm -f "${SUPERVISOR_PID_FILE}" "${STOP_FILE}"
    mkdir -p "$(dirname "${LOG_FILE}")"
    rotate_log_if_needed
    start_screen_supervisor

    sleep 1
    supervisor_pid="$(read_supervisor_pid || true)"
    if is_running "${supervisor_pid}"; then
        local app_pid
        app_pid="$(read_app_pid || true)"
        if is_running "${app_pid}"; then
            echo "AstrBot daemon started in screen, supervisor_pid=${supervisor_pid}, app_pid=${app_pid}"
        else
            echo "AstrBot daemon started in screen, supervisor_pid=${supervisor_pid}"
        fi
        echo "screen session: ${SCREEN_SESSION}"
        echo "Log: ${LOG_FILE}"
    else
        echo "AstrBot daemon failed to start. Last log lines:" >&2
        tail -n 40 "${LOG_FILE}" >&2 || true
        exit 1
    fi
}

stop() {
    touch "${STOP_FILE}"

    local supervisor_pid
    supervisor_pid="$(read_supervisor_pid || true)"
    if is_running "${supervisor_pid}"; then
        kill "${supervisor_pid}" 2>/dev/null || true
        if ! wait_for_exit "${supervisor_pid}"; then
            kill -9 "${supervisor_pid}" 2>/dev/null || true
            wait_for_exit "${supervisor_pid}" || true
        fi
    fi

    local app_pid
    app_pid="$(read_app_pid || true)"
    if is_running "${app_pid}"; then
        stop_app
    fi

    rm -f "${SUPERVISOR_PID_FILE}" "${APP_PID_FILE}"
    stop_screen_session
    echo "AstrBot stopped"
}

restart() {
    echo "Restarting AstrBot..."
    stop
    rm -f "${STOP_FILE}"
    start
}

status() {
    local supervisor_pid app_pid
    supervisor_pid="$(read_supervisor_pid || true)"
    app_pid="$(read_app_pid || true)"

    if is_running "${supervisor_pid}" && is_running "${app_pid}"; then
        echo "AstrBot daemon is running, supervisor_pid=${supervisor_pid}, app_pid=${app_pid}"
    elif is_running "${supervisor_pid}"; then
        echo "AstrBot daemon is running, supervisor_pid=${supervisor_pid}"
        echo "AstrBot process is not running right now; supervisor may be restarting it"
    elif is_running "${app_pid}"; then
        echo "AstrBot is running without daemon, app_pid=${app_pid}"
    else
        echo "AstrBot is not running"
        [[ -f "${STOP_FILE}" ]] && echo "Manual stop flag: ${STOP_FILE}"
        [[ -f "${SUPERVISOR_PID_FILE}" ]] && echo "Stale supervisor pid file: ${SUPERVISOR_PID_FILE}"
        [[ -f "${APP_PID_FILE}" ]] && echo "Stale app pid file: ${APP_PID_FILE}"
    fi
    if screen_session_exists; then
        echo "screen session: ${SCREEN_SESSION}"
    fi
    exit 0
}

show_log() {
    rotate_log_if_needed
    touch "${LOG_FILE}"
    tail -n 200 -f "${LOG_FILE}"
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    case "${1:-}" in
        supervise)
            supervise
            ;;
        start)
            start
            ;;
        stop)
            stop
            ;;
        restart)
            restart
            ;;
        status)
            status
            ;;
        log)
            show_log
            ;;
        rotate-log)
            rotate_log_if_needed
            ;;
        install)
            install_astr
            ;;
        patch)
            patch_astr
            ;;
        deploy|self-install)
            deploy_astr
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
