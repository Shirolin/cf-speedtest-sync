#!/bin/sh
# Cloudflare SpeedTest Auto-Pilot (Speedtest Module)
# Author: Gemini CLI

# --- 初始化环境 ---
SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
ROOT_DIR=$(dirname "$SCRIPT_DIR")
CONFIG_FILE="$ROOT_DIR/config.json"
CORE_DIR="$ROOT_DIR/core"
CFST_BIN="$CORE_DIR/cfst"

# --- 参数解析 ---
QUIET="false"
if [ "$1" = "-q" ] || [ "$1" = "--quiet" ]; then
    QUIET="true"
fi

# --- 依赖与配置检查 ---
if ! command -v jq >/dev/null 2>&1; then echo "[ERROR] jq not found."; exit 1; fi
if [ ! -f "$CONFIG_FILE" ]; then echo "[ERROR] config.json missing"; exit 1; fi

get_config() { jq -r "$1" "$CONFIG_FILE" 2>/dev/null; }

# --- 下载 CloudflareST ---
setup_cfst() {
    if [ -f "$CFST_BIN" ]; then return 0; fi
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64) PKG="CloudflareST_linux_arm64.tar.gz" ;;
        x86_64)  PKG="CloudflareST_linux_amd64.tar.gz" ;;
        *) echo "[ERROR] Unsupported arch: $ARCH"; exit 1 ;;
    esac
    local mirror=$(get_config ".DownloadMirror")
    [ "$mirror" = "null" ] && mirror=""
    [ "$QUIET" = "false" ] && echo ">>> Downloading CloudflareST..."
    local url="${mirror}https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/$PKG"
    curl -sL -o "/tmp/$PKG" "$url" || exit 1
    mkdir -p "$CORE_DIR"
    tar -zxf "/tmp/$PKG" -C "$CORE_DIR" CloudflareST
    mv "$CORE_DIR/CloudflareST" "$CFST_BIN"
    chmod +x "$CFST_BIN"
    rm -f "/tmp/$PKG"
}

# --- 执行测速 ---
run_type_speedtest() {
    local type=$1
    local config_key=".$type"
    [ "$(get_config "$config_key.Enable")" != "true" ] && return 1

    [ "$QUIET" = "false" ] && echo ">>> Running Speedtest for $type..."
    local ip_file="$CORE_DIR/$(get_config "$config_key.File")"
    [ ! -f "$ip_file" ] && ip_file="$ROOT_DIR/core/$(get_config "$config_key.File")"
    [ ! -f "$ip_file" ] && echo "[WARN] $ip_file missing, skip $type" && return 1

    local output_csv="$ROOT_DIR/report_$type.csv"
    rm -f "$output_csv"

    local flags="-f $ip_file -url $(get_config "$config_key.SpeedTestURL") -httping -n $(get_config "$config_key.Threads") -dn $(get_config "$config_key.DownloadCount") -tl $(get_config "$config_key.LatencyLimit") -o $output_csv -p 0"
    [ "$type" = "IPv6" ] && flags="$flags -ipv6"

    if [ "$QUIET" = "true" ]; then
        "$CFST_BIN" $flags > /dev/null 2>&1
    else
        "$CFST_BIN" $flags
    fi
}

setup_cfst
run_type_speedtest "IPv4"
run_type_speedtest "IPv6"
[ "$QUIET" = "false" ] && echo ">>> Speedtest finished. Reports saved to root directory."
exit 0
