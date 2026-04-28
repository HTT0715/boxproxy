#!/system/bin/sh

# sing-box 守护脚本，适配 box_for_root / box 项目
# 放置位置建议：/data/adb/box/scripts/singbox-watchdog.sh

BOX_DIR="/data/adb/box"
SCRIPTS_DIR="${BOX_DIR}/scripts"
SETTINGS="${BOX_DIR}/settings.ini"
RUN_DIR="${BOX_DIR}/run"
PID_FILE="${RUN_DIR}/box.pid"
LOG_FILE="${RUN_DIR}/singbox-watchdog.log"
LOCK_DIR="${RUN_DIR}/locks/singbox-watchdog.lock"
SERVICE="${SCRIPTS_DIR}/box.service"
IPTABLES="${SCRIPTS_DIR}/box.iptables"

CHECK_INTERVAL=30
RESTART_COOLDOWN=60
MAX_RESTART_IN_WINDOW=5
WINDOW_SECONDS=600

export PATH="/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:/system/bin:/system/xbin:$PATH"

mkdir -p "${RUN_DIR}/locks" >/dev/null 2>&1 || true

log() {
  echo "[$(date '+%F %T')] $*" >> "${LOG_FILE}"
}

get_busybox() {
  if [ -x /data/adb/magisk/busybox ]; then
    echo /data/adb/magisk/busybox
  elif [ -x /data/adb/ksu/bin/busybox ]; then
    echo /data/adb/ksu/bin/busybox
  elif [ -x /data/adb/ap/bin/busybox ]; then
    echo /data/adb/ap/bin/busybox
  else
    echo busybox
  fi
}

BUSYBOX="$(get_busybox)"

is_manual_mode() {
  [ -f "${BOX_DIR}/manual" ]
}

is_module_disabled() {
  [ -f "/data/adb/modules/box_for_root/disable" ]
}

load_settings() {
  [ -r "${SETTINGS}" ] || return 1
  . "${SETTINGS}"
  return 0
}

is_singbox_selected() {
  load_settings || return 1
  [ "${bin_name}" = "sing-box" ]
}

pid_alive() {
  local pid
  pid="$(cat "${PID_FILE}" 2>/dev/null)"
  [ -n "${pid}" ] && kill -0 "${pid}" >/dev/null 2>&1
}

singbox_alive() {
  "${BUSYBOX}" pidof sing-box >/dev/null 2>&1 || pid_alive
}

start_singbox() {
  log "sing-box 未运行，尝试通过 box.service restart 重启"
  "${IPTABLES}" disable >/dev/null 2>&1 || true
  "${SERVICE}" restart >> "${LOG_FILE}" 2>&1
  sleep 5

  if singbox_alive; then
    "${IPTABLES}" enable >> "${LOG_FILE}" 2>&1 || true
    log "重启成功"
    return 0
  fi

  log "重启失败，请检查 ${RUN_DIR}/sing-box.log"
  return 1
}

with_lock_or_exit() {
  if ! mkdir "${LOCK_DIR}" >/dev/null 2>&1; then
    echo "watchdog 已在运行"
    exit 0
  fi
  trap 'rmdir "${LOCK_DIR}" >/dev/null 2>&1 || true; exit 0' INT TERM EXIT
}

main_loop() {
  with_lock_or_exit
  log "watchdog 启动"

  restart_count=0
  window_start="$(date +%s)"
  last_restart=0

  while true; do
    now="$(date +%s)"

    if [ $((now - window_start)) -gt "${WINDOW_SECONDS}" ]; then
      restart_count=0
      window_start="${now}"
    fi

    if is_module_disabled; then
      log "模块已禁用，跳过检测"
      sleep "${CHECK_INTERVAL}"
      continue
    fi

    if is_manual_mode; then
      log "检测到 manual 文件，跳过自动拉起"
      sleep "${CHECK_INTERVAL}"
      continue
    fi

    if ! is_singbox_selected; then
      log "当前 bin_name 不是 sing-box，跳过检测"
      sleep "${CHECK_INTERVAL}"
      continue
    fi

    if singbox_alive; then
      sleep "${CHECK_INTERVAL}"
      continue
    fi

    if [ $((now - last_restart)) -lt "${RESTART_COOLDOWN}" ]; then
      log "距离上次重启不足 ${RESTART_COOLDOWN}s，暂不重启"
      sleep "${CHECK_INTERVAL}"
      continue
    fi

    if [ "${restart_count}" -ge "${MAX_RESTART_IN_WINDOW}" ]; then
      log "${WINDOW_SECONDS}s 内已重启 ${restart_count} 次，暂停拉起，避免死循环"
      sleep "${CHECK_INTERVAL}"
      continue
    fi

    start_singbox
    restart_count=$((restart_count + 1))
    last_restart="$(date +%s)"
    sleep "${CHECK_INTERVAL}"
  done
}

case "$1" in
  start)
    main_loop &
    ;;
  stop)
    pids="$(${BUSYBOX} pgrep -f 'singbox-watchdog.sh' 2>/dev/null)"
    for p in ${pids}; do
      [ "${p}" != "$$" ] && kill -15 "${p}" >/dev/null 2>&1
    done
    rm -rf "${LOCK_DIR}"
    ;;
  restart)
    "$0" stop
    sleep 1
    "$0" start
    ;;
  status)
    if ${BUSYBOX} pgrep -f 'singbox-watchdog.sh' >/dev/null 2>&1; then
      echo "singbox-watchdog 正在运行"
    else
      echo "singbox-watchdog 未运行"
    fi
    ;;
  *)
    echo "用法: $0 {start|stop|restart|status}"
    ;;
esac
