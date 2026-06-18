#!/bin/sh
# Cloudflare SpeedTest Auto-Pilot (Main Wrapper)
# Author: Gemini CLI

# --- 初始化环境 ---
SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
LOCK_FILE="/tmp/cf-speedtest-sync.lock"

# --- 帮助与安装 ---
show_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
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
        echo "[WARN] Another instance is running (PID: $PID). Exiting."
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE" /tmp/cfst_IPv4.csv /tmp/cfst_IPv6.csv; exit' INT TERM EXIT

case "$1" in
    speedtest)
        sh "$SCRIPT_DIR/speedtest.sh"
        ;;
    sync)
        sh "$SCRIPT_DIR/sync.sh"
        ;;
    test|--test|--dry-run)
        sh "$SCRIPT_DIR/speedtest.sh" -q
        sh "$SCRIPT_DIR/sync.sh" test
        ;;
    *)
        # Default run
        sh "$SCRIPT_DIR/speedtest.sh" -q
        sh "$SCRIPT_DIR/sync.sh"
        ;;
esac

rm -f "$LOCK_FILE"
exit 0
