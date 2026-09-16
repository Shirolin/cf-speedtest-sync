#!/bin/sh
# Cloudflare SpeedTest Auto-Pilot (Main Wrapper)
# Author: Gemini CLI

# --- 初始化环境 ---
SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
LOCK_FILE="/tmp/cf-speedtest-sync.lock"

# --- 引入公共日志模块 (ROOT_DIR / CONFIG_FILE / LOG_FILE / log) ---
. "$SCRIPT_DIR/common.sh"

# --- 帮助与安装 ---
show_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --source, -s   Specify data source: local (default) or api"
    echo "  run (default)  Run speedtest and sync"
    echo "  test           Run speedtest and dry-run sync (no DNS changes)"
    echo "  speedtest      Only run speedtest"
    echo "  sync           Only run sync"
    echo "  install        Add this script to crontab (runs daily at 4 AM)"
    echo "  uninstall      Remove this script from crontab"
    echo "  help           Show this help"
}

manage_cron() {
    local action=$1
    local cron_job="0 4 * * * /bin/sh $SCRIPT_PATH > /dev/null 2>&1"
    
    case "$action" in
        install)
            (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$cron_job") | crontab -
            echo "[SUCCESS] Crontab updated. Script will run daily at 4 AM."
            ;;
        uninstall)
            crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
            echo "[SUCCESS] Script removed from crontab."
            ;;
    esac
}

# --- 参数解析 ---
SOURCE=""
TEMP_ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --source|-s)
            SOURCE="$2"
            shift 2
            ;;
        *)
            TEMP_ARGS="$TEMP_ARGS $1"
            shift
            ;;
    esac
done
eval set -- "$TEMP_ARGS"

# --- 执行入口 ---
case "$1" in
    install)   manage_cron "install"; exit 0 ;;
    uninstall) manage_cron "uninstall"; exit 0 ;;
    help|-h|--help) show_help; exit 0 ;;
esac

# 加锁防止重叠运行
if [ -f "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        log "[WARN] Another instance is running (PID: $PID). Exiting without touching DNS."
        exit 0
    fi
    log "[WARN] Removing stale lock file (PID: $PID is no longer running)."
fi
echo $$ > "$LOCK_FILE"
cleanup() { rm -f "$LOCK_FILE" /tmp/cfst_IPv4.csv /tmp/cfst_IPv6.csv; }
# EXIT 陷阱不得调用 exit，否则会用 rm 的退出码覆盖真实退出码
trap 'cleanup; exit 1' INT TERM
trap 'cleanup' EXIT

log ">>> Run started (mode=${1:-run}, source=${SOURCE:-config.json})"

STATUS=0
DEGRADED=0
case "$1" in
    speedtest)
        sh "$SCRIPT_DIR/speedtest.sh" ${SOURCE:+--source "$SOURCE"} || STATUS=$?
        ;;
    sync)
        sh "$SCRIPT_DIR/sync.sh" || STATUS=$?
        ;;
    test|--test|--dry-run)
        sh "$SCRIPT_DIR/speedtest.sh" -q ${SOURCE:+--source "$SOURCE"} || STATUS=$?
        if [ "$STATUS" -eq 0 ] || [ "$STATUS" -eq 2 ]; then
            [ "$STATUS" -eq 2 ] && DEGRADED=1
            sh "$SCRIPT_DIR/sync.sh" test || STATUS=$?
        else
            log "[ERROR] Speedtest step failed (exit $STATUS). Sync aborted to protect DNS."
        fi
        ;;
    *)
        # Default run
        sh "$SCRIPT_DIR/speedtest.sh" -q ${SOURCE:+--source "$SOURCE"} || STATUS=$?
        if [ "$STATUS" -eq 0 ] || [ "$STATUS" -eq 2 ]; then
            [ "$STATUS" -eq 2 ] && DEGRADED=1
            sh "$SCRIPT_DIR/sync.sh" || STATUS=$?
        else
            log "[ERROR] Speedtest step failed (exit $STATUS). Sync aborted to protect DNS."
        fi
        ;;
esac

rm -f "$LOCK_FILE"
if [ "$DEGRADED" -eq 1 ] && [ "$STATUS" -ne 1 ]; then
    log "[WARN] Run finished degraded (exit $STATUS): primary source unavailable, fallback data used."
fi
if [ "$STATUS" -ne 0 ] && [ "$STATUS" -ne 2 ]; then
    log "[ERROR] Run finished with errors (exit $STATUS)."
fi
exit $STATUS
