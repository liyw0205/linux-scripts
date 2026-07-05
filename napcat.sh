# NapCat 管理脚本（单文件备份版）
# 备份: 复制本文件即可
# 部署: bash /root/napcat.sh deploy
# 或:   /root/napcat.sh deploy

#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${NAPCAT_BASE_DIR:-/root}"
NAPCAT_DIR="${NAPCAT_DIR:-${BASE_DIR}/napcat}"
LAUNCHER_SO="${NAPCAT_LAUNCHER_SO:-${BASE_DIR}/libnapcat_launcher.so}"
DISPLAY_NUM="${NAPCAT_DISPLAY:-:1}"
CONFIG_DIR="${NAPCAT_CLI_CONFIG_DIR:-/root/.config/napcat-cli}"
STATE_DIR="${NAPCAT_CLI_STATE_DIR:-/root/.local/state/napcat-cli}"
QQ_FILE="${CONFIG_DIR}/qq"
PID_FILE="${STATE_DIR}/napcat.pid"
LOG_FILE="${STATE_DIR}/napcat.log"
LOG_MAX_SIZE_MB="${NAPCAT_LOG_MAX_SIZE_MB:-50}"
STOP_FILE="${STATE_DIR}/stopping"
SYSTEMD_UNIT="${NAPCAT_SYSTEMD_UNIT:-napcat.service}"
SELF="${BASH_SOURCE[0]}"
SCREEN_SESSION="${NAPCAT_SCREEN_SESSION:-napcat}"

QQ_BIN="${NAPCAT_QQ_BIN:-}"
if [[ -z "${QQ_BIN}" ]]; then
  QQ_BIN="$(command -v qq || true)"
  QQ_BIN="${QQ_BIN:-/usr/bin/qq}"
fi

usage() {
  cat <<EOF
用法:
  napcat start                使用 screen 守护启动 NapCat，异常停止会自动重启
  napcat stop                 手动停止 NapCat，停止后不会自动重启
  napcat restart              重启 NapCat
  napcat status               查看状态
  napcat log                  查看并跟随日志
  napcat install              下载并安装 NapCat
  napcat patch                下载并编译 NapCat Linux 启动器补丁
  napcat deploy               将本脚本安装到系统命令 (默认 /usr/local/bin/napcat)
  napcat -q 3834455831        设置 start 使用的 QQ 号
  napcat -q                   清空 start 使用的 QQ 号

也可以组合使用:
  napcat -q 3834455831 start
  napcat start -q 3834455831
  napcat -q start             清空 QQ 号后启动
EOF
}

ensure_dirs() {
  mkdir -p "${CONFIG_DIR}" "${STATE_DIR}"
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
  printf '[%s] Log rotated: previous size %s exceeded %sMB limit; log truncated.\n'     "$(date '+%Y-%m-%d %H:%M:%S')" "${human_size}" "${max_mb}" >> "${log_file}"
}

read_qq() {
  [[ -s "${QQ_FILE}" ]] || return 1

  local qq
  qq="$(tr -d '[:space:]' < "${QQ_FILE}")"
  [[ "${qq}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${qq}"
}

set_qq() {
  local qq="$1"
  ensure_dirs
  printf '%s\n' "${qq}" > "${QQ_FILE}"
  echo "已设置启动 QQ: ${qq}"
}

clear_qq() {
  ensure_dirs
  rm -f "${QQ_FILE}"
  echo "已清空启动 QQ"
}

pid_from_file() {
  [[ -f "${PID_FILE}" ]] || return 1

  local pid
  IFS= read -r pid < "${PID_FILE}" || true
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${pid}"
}

is_pid_ours() {
  local pid="$1"
  [[ -r "/proc/${pid}/cmdline" ]] || return 1

  local argv arg previous=""
  argv="$({ tr '\0' '\n' < "/proc/${pid}/cmdline"; } 2>/dev/null || true)"

  while IFS= read -r arg; do
    if [[ "${arg}" == "${SELF}" || "${arg}" == */napcat || "${arg}" == */napcat.sh || "${arg}" == "napcat" || "${arg}" == "napcat.sh" ]]; then
      previous="napcat"
      continue
    fi

    if [[ "${previous}" == "napcat" && "${arg}" == "_run" ]]; then
      return 0
    fi

    previous=""
  done <<< "${argv}"

  return 1
}

managed_run_pids() {
  local proc pid

  for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    if [[ "${pid}" != "$$" ]] && is_pid_ours "${pid}"; then
      printf '%s\n' "${pid}"
    fi
  done | sort -n
}

managed_process_pids() {
  local proc pid env ppid

  for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    [[ "${pid}" != "$$" && -r "${proc}/cmdline" ]] || continue

    if is_pid_ours "${pid}"; then
      printf '%s\n' "${pid}"
      continue
    fi

    if [[ -r "${proc}/environ" ]]; then
      env="$({ tr '\0' '\n' < "${proc}/environ"; } 2>/dev/null || true)"
      if [[ "${env}" == *"NAPCAT_BOOTMAIN=${BASE_DIR}"* ]]; then
        printf '%s\n' "${pid}"
        continue
      fi
    fi

    if is_xvfb_child_of_supervisor "${pid}"; then
      printf '%s\n' "${pid}"
      continue
    fi
  done | sort -n | uniq
}

is_xvfb_child_of_supervisor() {
  local pid="$1"
  [[ -r "/proc/${pid}/cmdline" && -r "/proc/${pid}/stat" ]] || return 1

  local argv arg index=0 is_xvfb=0 has_display=0 ppid
  argv="$({ tr '\0' '\n' < "/proc/${pid}/cmdline"; } 2>/dev/null || true)"

  while IFS= read -r arg; do
    if [[ "${index}" -eq 0 && "${arg}" == */Xvfb || "${index}" -eq 0 && "${arg}" == "Xvfb" ]]; then
      is_xvfb=1
    elif [[ "${index}" -eq 1 && "${arg}" == "${DISPLAY_NUM}" ]]; then
      has_display=1
    fi
    index=$((index + 1))
  done <<< "${argv}"

  [[ "${is_xvfb}" -eq 1 && "${has_display}" -eq 1 ]] || return 1

  ppid="$(awk '{print $4}' "/proc/${pid}/stat" 2>/dev/null || true)"
  [[ -n "${ppid}" ]] || return 1
  is_pid_ours "${ppid}"
}

is_running() {
  local pid
  pid="$(pid_from_file)" || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  is_pid_ours "${pid}"
}

cleanup_stale_pid() {
  if is_running; then
    return 0
  fi

  local pid
  pid="$(managed_run_pids | head -n 1 || true)"
  if [[ -n "${pid}" ]]; then
    printf '%s\n' "${pid}" > "${PID_FILE}"
    return 0
  fi

  rm -f "${PID_FILE}"
}

current_pgid() {
  local pid="$1"
  ps -o pgid= -p "${pid}" 2>/dev/null | tr -d '[:space:]' || true
}

terminate_managed_processes() {
  local signal="$1"
  local self_pgid pid pgid killed_pgids=" "

  self_pgid="$(current_pgid "$$" || true)"

  while IFS= read -r pid; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    pgid="$(current_pgid "${pid}" || true)"

    if [[ -n "${pgid}" && "${pgid}" != "${self_pgid}" && "${killed_pgids}" != *" ${pgid} "* ]]; then
      kill "-${signal}" "-${pgid}" 2>/dev/null || true
      killed_pgids+="${pgid} "
    else
      kill "-${signal}" "${pid}" 2>/dev/null || true
    fi
  done < <(managed_process_pids)
}

has_managed_processes() {
  local pid
  pid="$(managed_process_pids | head -n 1 || true)"
  [[ -n "${pid}" ]]
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

systemd_unit_installed() {
  [[ -f "/etc/systemd/system/${SYSTEMD_UNIT}" ]]
}

use_systemd() {
  systemd_available && systemd_unit_installed
}

require_screen() {
  if ! command -v screen >/dev/null 2>&1; then
    echo "缺少 screen，请先安装 screen" >&2
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
  "$0" _rotate_log
  "$0" _run 2>&1 | tee -a "$1"
  code=${PIPESTATUS[0]}
  if [[ -f "$2" ]]; then
    exit 0
  fi
  printf "[%s] napcat _run exited with code %s, restarting in 3s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$code" | tee -a "$1"
  sleep 3
done
' "${SELF}" "${LOG_FILE}" "${STOP_FILE}"
}



patch_napcat() {
  local cpp_file="${BASE_DIR}/launcher.cpp"
  local cpp_url="https://raw.githubusercontent.com/NapNeko/napcat-linux-launcher/refs/heads/main/launcher.cpp"
  local download_url="${cpp_url}"
  local proxy status timeout=10
  local proxy_arr=(
    "https://ghfast.top"
    "https://gh.wuliya.xin"
    "https://gh-proxy.com"
    "https://github.moeyy.xyz"
  )
  local check_url="https://raw.githubusercontent.com/NapNeko/NapCatQQ/main/package.json"
  local target_proxy=""

  cd "${BASE_DIR}"
  echo "开始编译 NapCat Linux 启动器补丁..."

  local system_arch
  system_arch="$(arch | sed 's/aarch64/arm64/; s/x86_64/amd64/')"
  if [[ "${system_arch}" != "amd64" && "${system_arch}" != "arm64" ]]; then
    echo "不支持的架构: ${system_arch}" >&2
    return 1
  fi

  if ! command -v g++ >/dev/null 2>&1; then
    echo "未找到 g++，尝试安装..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y -qq g++
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y gcc-c++
    else
      echo "请手动安装 g++ 后重试" >&2
      return 1
    fi
  fi

  for proxy in "${proxy_arr[@]}"; do
    status="$(curl -k -L --connect-timeout "${timeout}" --max-time $((timeout * 2)) -o /dev/null -s -w '%{http_code}' "${proxy}/${check_url}" || true)"
    if [[ "${status}" == "200" ]]; then
      target_proxy="${proxy}"
      break
    fi
  done

  if [[ -n "${target_proxy}" ]]; then
    download_url="${target_proxy}/${cpp_url#https://}"
  fi

  curl -k -L -# "${download_url}" -o "${cpp_file}"
  g++ -shared -fPIC "${cpp_file}" -o "${LAUNCHER_SO}" -ldl
  chmod 755 "${LAUNCHER_SO}"
  echo "补丁完成: ${LAUNCHER_SO}"
}

deploy_napcat() {
  local install_path="${NAPCAT_INSTALL_PATH:-/usr/local/bin/napcat}"
  local source_path="${SELF}"

  if [[ ! -f "${source_path}" ]]; then
    echo "无法定位脚本自身: ${source_path}" >&2
    return 1
  fi

  install -m 755 "${source_path}" "${install_path}"
  echo "已部署到: ${install_path}"
  echo "可直接使用: napcat <command>"
}

install_napcat() {
  local install_script="${BASE_DIR}/napcat-install.sh"

  cd "${BASE_DIR}"
  echo "开始安装 NapCat..."
  curl -o "${install_script}" https://raw.githubusercontent.com/NapNeko/napcat-linux-installer/refs/heads/main/install.sh
  bash "${install_script}"
}

require_install() {
  local missing=0

  if [[ ! -d "${NAPCAT_DIR}" ]]; then
    echo "缺少 NapCat 目录: ${NAPCAT_DIR}" >&2
    missing=1
  fi

  if [[ ! -f "${LAUNCHER_SO}" ]]; then
    echo "缺少 Linux 启动器: ${LAUNCHER_SO}" >&2
    missing=1
  fi

  if [[ ! -x "${QQ_BIN}" ]]; then
    echo "缺少 QQ 可执行文件: ${QQ_BIN}" >&2
    missing=1
  fi

  if ! command -v Xvfb >/dev/null 2>&1; then
    echo "缺少 Xvfb，请先安装 xvfb" >&2
    missing=1
  fi

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

start_napcat() {
  ensure_dirs
  rotate_log_if_needed
  rm -f "${STOP_FILE}"
  cleanup_stale_pid

  if is_running; then
    local pid qq
    pid="$(pid_from_file)"
    qq="$(read_qq 2>/dev/null || true)"
    echo "NapCat 已在运行 (PID: ${pid})"
    if screen_session_exists; then
      echo "screen 会话: ${SCREEN_SESSION}"
    else
      echo "screen 会话: 未使用（重启后将改用 screen）"
    fi
    if [[ -n "${qq}" ]]; then
      echo "启动 QQ: ${qq}（下次 start 生效）"
    fi
    return 0
  fi

  if screen_session_exists; then
    echo "发现残留 screen 会话: ${SCREEN_SESSION}，正在清理后重启"
    stop_screen_session
    sleep 0.5
  fi

  require_install
  require_screen

  local qq
  qq="$(read_qq 2>/dev/null || true)"

  {
    echo
    echo "==== $(date '+%Y-%m-%d %H:%M:%S') start ===="
    echo "BASE_DIR=${BASE_DIR}"
    echo "NAPCAT_DIR=${NAPCAT_DIR}"
    echo "QQ_BIN=${QQ_BIN}"
    echo "DISPLAY=${DISPLAY_NUM}"
    if [[ -n "${qq}" ]]; then
      echo "QUICK_LOGIN_QQ=${qq}"
    else
      echo "QUICK_LOGIN_QQ=<empty>"
    fi
  } >> "${LOG_FILE}"

  local pid=""
  if use_systemd; then
    systemctl stop "${SYSTEMD_UNIT}" >/dev/null 2>&1 || true
    rm -f "${STOP_FILE}"
  fi
  start_screen_supervisor

  for _ in $(seq 1 20); do
    cleanup_stale_pid
    if is_running; then
      break
    fi
    sleep 0.5
  done

  if is_running; then
    pid="$(pid_from_file)"
    echo "NapCat 已通过 screen 守护启动 (PID: ${pid})"
    echo "screen 会话: ${SCREEN_SESSION}"
    if [[ -n "${qq}" ]]; then
      echo "启动 QQ: ${qq}"
    else
      echo "启动 QQ: 未设置，将使用二维码/默认登录流程"
    fi
    echo "日志: ${LOG_FILE}"
    return 0
  fi

  rm -f "${PID_FILE}"
  echo "NapCat 启动失败，最近日志如下:" >&2
  tail -n 40 "${LOG_FILE}" >&2 || true
  return 1
}

stop_napcat() {
  ensure_dirs
  cleanup_stale_pid

  local had_processes=0
  if is_running || has_managed_processes || screen_session_exists; then
    had_processes=1
  fi

  touch "${STOP_FILE}"

  if use_systemd; then
    systemctl stop "${SYSTEMD_UNIT}" >/dev/null 2>&1 || true
  fi

  cleanup_stale_pid

  if ! is_running && ! has_managed_processes; then
    stop_screen_session
    rm -f "${PID_FILE}"
    rm -f "${STOP_FILE}"
    if [[ "${had_processes}" -eq 1 ]]; then
      echo "NapCat 已手动停止"
    else
      echo "NapCat 未运行"
    fi
    return 0
  fi

  terminate_managed_processes TERM

  for _ in $(seq 1 30); do
    if ! has_managed_processes; then
      stop_screen_session
      rm -f "${PID_FILE}"
      rm -f "${STOP_FILE}"
      echo "NapCat 已手动停止"
      return 0
    fi
    sleep 0.5
  done

  terminate_managed_processes KILL

  for _ in $(seq 1 10); do
    if ! has_managed_processes; then
      stop_screen_session
      rm -f "${PID_FILE}"
      rm -f "${STOP_FILE}"
      echo "NapCat 已手动强制停止"
      return 0
    fi
    sleep 0.5
  done

  rm -f "${PID_FILE}"
  rm -f "${STOP_FILE}"
  stop_screen_session
  echo "NapCat 停止失败，仍有残留进程:" >&2
  managed_process_pids | xargs -r ps -o pid,ppid,pgid,stat,cmd -p >&2
  return 1
}

status_napcat() {
  ensure_dirs
  cleanup_stale_pid

  local qq
  qq="$(read_qq 2>/dev/null || true)"

  if is_running; then
    local pid
    pid="$(pid_from_file)"
    echo "状态: 运行中"
    echo "PID: ${pid}"
    if screen_session_exists; then
      echo "守护: screen (${SCREEN_SESSION})"
    elif use_systemd && systemctl is-active --quiet "${SYSTEMD_UNIT}"; then
      echo "守护: systemd"
    else
      echo "守护: 内置守护"
    fi
  else
    local stray_pid
    stray_pid="$(managed_process_pids | head -n 1 || true)"
    if [[ -n "${stray_pid}" ]]; then
      echo "状态: 运行中"
      echo "PID: ${stray_pid}"
    elif screen_session_exists; then
      echo "状态: screen 会话存在，但托管进程未运行"
      echo "screen 会话: ${SCREEN_SESSION}"
    else
      echo "状态: 未运行"
    fi
  fi

  if [[ -n "${qq}" ]]; then
    echo "启动 QQ: ${qq}"
  else
    echo "启动 QQ: 未设置"
  fi

  echo "配置: ${QQ_FILE}"
  echo "日志: ${LOG_FILE}"
}

log_napcat() {
  ensure_dirs
  rotate_log_if_needed
  touch "${LOG_FILE}"

  local lines=120
  local follow=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--lines)
        [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || {
          echo "log 的 -n/--lines 需要数字" >&2
          exit 2
        }
        lines="$2"
        shift 2
        ;;
      --no-follow)
        follow=0
        shift
        ;;
      -f|--follow)
        follow=1
        shift
        ;;
      *)
        echo "未知 log 参数: $1" >&2
        exit 2
        ;;
    esac
  done

  if [[ "${follow}" -eq 1 ]]; then
    exec tail -n "${lines}" -f "${LOG_FILE}"
  fi

  exec tail -n "${lines}" "${LOG_FILE}"
}

run_napcat() {
  require_install
  ensure_dirs
  if [[ -f "${STOP_FILE}" ]]; then
    echo "[napcat] 检测到停止标记，退出"
    exit 0
  fi

  printf '%s\n' "$$" > "${PID_FILE}"
  cd "${BASE_DIR}"

  local shutdown=0
  local xvfb_pid=""
  local child_pid=""
  local supervisor_pid="${BASHPID}"
  local xvfb_runner=()

  if command -v xvfb-run >/dev/null 2>&1; then
    xvfb_runner=(xvfb-run -a -s "-screen 0 1280x1024x24 +extension GLX +render")
  fi

  start_xvfb() {
    if [[ -n "${xvfb_pid}" ]] && kill -0 "${xvfb_pid}" 2>/dev/null; then
      return 0
    fi

    Xvfb "${DISPLAY_NUM}" -screen 0 1x1x8 +extension GLX +render >/dev/null 2>&1 &
    xvfb_pid="$!"
    sleep 0.2

    if ! kill -0 "${xvfb_pid}" 2>/dev/null; then
      echo "[napcat] Xvfb ${DISPLAY_NUM} 未保持运行，可能该 DISPLAY 已存在；继续启动 QQ"
      xvfb_pid=""
    fi
  }

  stop_child() {
    if [[ -n "${child_pid:-}" ]]; then
      kill -TERM "-${child_pid}" 2>/dev/null || kill -TERM "${child_pid}" 2>/dev/null || true
      wait "${child_pid}" 2>/dev/null || true
      kill -KILL "-${child_pid}" 2>/dev/null || true
      child_pid=""
    fi
    cleanup_child_leftovers
  }

  cleanup_child_leftovers() {
    local signal proc pid

    for signal in TERM KILL; do
      for proc in /proc/[0-9]*; do
        pid="${proc##*/}"
        [[ "${pid}" =~ ^[0-9]+$ ]] || continue
        [[ "${pid}" != "$$" && "${pid}" != "${xvfb_pid:-}" ]] || continue
        is_pid_ours "${pid}" && continue

        if [[ -r "${proc}/environ" ]] && grep -z -F -q "NAPCAT_BOOTMAIN=${BASE_DIR}" "${proc}/environ" 2>/dev/null; then
          kill "-${signal}" "${pid}" 2>/dev/null || true
        fi
      done

      if [[ "${signal}" == "TERM" ]]; then
        sleep 1
      fi
    done
  }

  cleanup() {
    [[ "${BASHPID}" == "${supervisor_pid:-}" ]] || return 0

    stop_child
    if [[ -n "${xvfb_pid:-}" ]]; then
      kill "${xvfb_pid}" 2>/dev/null || true
      wait "${xvfb_pid}" 2>/dev/null || true
    fi
    if [[ "$(pid_from_file 2>/dev/null || true)" == "$$" ]]; then
      rm -f "${PID_FILE}"
    fi
  }

  handle_shutdown() {
    [[ "${BASHPID}" == "${supervisor_pid:-}" ]] || return 0

    shutdown=1
    stop_child
  }

  trap cleanup EXIT
  trap handle_shutdown INT TERM
  trap '' SIGPIPE

  if [[ "${#xvfb_runner[@]}" -eq 0 ]]; then
    export DISPLAY="${DISPLAY_NUM}"
  fi

  while [[ "${shutdown}" -eq 0 ]]; do
    if [[ -f "${STOP_FILE}" ]]; then
      echo "[napcat] 检测到停止标记，停止守护"
      break
    fi

    rotate_log_if_needed

    if [[ "${#xvfb_runner[@]}" -eq 0 ]]; then
      start_xvfb
    fi

    local qq
    qq="$(read_qq 2>/dev/null || true)"

    local qq_args=(--no-sandbox)
    if [[ -n "${qq}" ]]; then
      qq_args+=(-q "${qq}")
    fi

    if [[ "${#xvfb_runner[@]}" -gt 0 ]]; then
      echo "[napcat] 启动命令: LD_PRELOAD=${LAUNCHER_SO} xvfb-run -a ${QQ_BIN} ${qq_args[*]:-}"
      "${xvfb_runner[@]}" env         LD_PRELOAD="${LAUNCHER_SO}"         NAPCAT_BOOTMAIN="${BASE_DIR}"         "${QQ_BIN}" "${qq_args[@]}" &
    else
      echo "[napcat] 启动命令: LD_PRELOAD=${LAUNCHER_SO} ${QQ_BIN} ${qq_args[*]:-}"
      env LD_PRELOAD="${LAUNCHER_SO}" NAPCAT_BOOTMAIN="${BASE_DIR}" DISPLAY="${DISPLAY_NUM}"         "${QQ_BIN}" "${qq_args[@]}" &
    fi
    child_pid="$!"

    local exit_code=0
    if wait "${child_pid}"; then
      exit_code=0
    else
      exit_code="$?"
    fi
    child_pid=""
    cleanup_child_leftovers

    if [[ "${shutdown}" -ne 0 || -f "${STOP_FILE}" ]]; then
      echo "[napcat] 已停止"
      break
    fi

    echo "[napcat] 进程退出，退出码 ${exit_code}，5 秒后自动重启"
    for _ in $(seq 1 5); do
      [[ "${shutdown}" -eq 0 && ! -f "${STOP_FILE}" ]] || break
      sleep 1
    done
  done

  trap - EXIT
  cleanup
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  local qq_touched=0
  local qq_value=""
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q|--qq)
        qq_touched=1
        if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
          qq_value="$2"
          shift 2
        else
          qq_value=""
          shift
        fi
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [[ "${qq_touched}" -eq 1 ]]; then
    if [[ -n "${qq_value}" ]]; then
      set_qq "${qq_value}"
    else
      clear_qq
    fi
  fi

  if [[ "${#positional[@]}" -eq 0 ]]; then
    exit 0
  fi

  local cmd="${positional[0]}"
  local rest=("${positional[@]:1}")

  case "${cmd}" in
    start)
      start_napcat
      ;;
    stop)
      stop_napcat
      ;;
    status)
      status_napcat
      ;;
    log|logs)
      log_napcat "${rest[@]}"
      ;;
    restart)
      stop_napcat
      start_napcat
      ;;
    install)
      install_napcat
      ;;
    patch)
      patch_napcat
      ;;
    deploy|self-install)
      deploy_napcat
      ;;
    _run)
      run_napcat
      ;;
    _rotate_log)
      rotate_log_if_needed
      ;;
    *)
      echo "未知命令: ${cmd}" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
