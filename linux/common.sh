#!/bin/sh
# Cloudflare SpeedTest Auto-Pilot (Shared Logging Module)
# 由 optimize.sh / speedtest.sh / sync.sh 引用（source），统一日志落点与轮转策略。
# 用法：
#   SCRIPT_PATH=$(readlink -f "$0")
#   SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
#   . "$SCRIPT_DIR/common.sh"
# 提供：ROOT_DIR / CONFIG_FILE / LOG_FILE / log()

if [ -z "$SCRIPT_DIR" ]; then
    echo "[ERROR] common.sh: caller must set SCRIPT_DIR before sourcing." >&2
    exit 1
fi

# --- 可选密钥文件 ---
# 用于把 CF_SECRET_ID / CF_SECRET_KEY 放在项目目录之外（建议 chmod 600），
# 使 config.json 可安全备份/分发。文件不存在时静默跳过，行为与从前一致。
# 可用 CFSYNC_ENV_FILE 覆盖路径。
CFSYNC_ENV_FILE="${CFSYNC_ENV_FILE:-/etc/cf-speedtest.env}"
if [ -f "$CFSYNC_ENV_FILE" ]; then
    . "$CFSYNC_ENV_FILE"
fi

if [ -z "$ROOT_DIR" ]; then
    ROOT_DIR=$(dirname "$SCRIPT_DIR")
fi
CONFIG_FILE="$ROOT_DIR/config.json"

# 日志与产物统一归档到 output/<Domain>/；config.json 缺失或 jq 不可用时退回 output/
LOG_DOMAIN=""
if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
    LOG_DOMAIN=$(jq -r '.Domain // empty' "$CONFIG_FILE" 2>/dev/null)
    [ "$LOG_DOMAIN" = "null" ] && LOG_DOMAIN=""
fi
if [ -n "$LOG_DOMAIN" ]; then
    LOG_DIR="$ROOT_DIR/output/$LOG_DOMAIN"
else
    LOG_DIR="$ROOT_DIR/output"
fi
LOG_FILE="$LOG_DIR/sync.log"
mkdir -p "$LOG_DIR" 2>/dev/null

# 统一日志函数：文件落盘 + stderr 回显（DRY_RUN=true 时额外标注）
log() {
    [ "$DRY_RUN" = "true" ] && printf "[DRY-RUN] " >&2
    if [ -f "$LOG_FILE" ] && [ $(wc -c < "$LOG_FILE") -gt 1048576 ]; then
        local tmp_log=$(tail -n 1000 "$LOG_FILE")
        echo "$tmp_log" > "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated" >> "$LOG_FILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}
