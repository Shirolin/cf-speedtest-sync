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
SOURCE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet)
            QUIET="true"
            shift
            ;;
        --source)
            SOURCE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# --- 依赖与配置检查 ---
if ! command -v jq >/dev/null 2>&1; then echo "[ERROR] jq not found."; exit 1; fi
if [ ! -f "$CONFIG_FILE" ]; then echo "[ERROR] config.json missing"; exit 1; fi

get_config() { jq -r "$1" "$CONFIG_FILE" 2>/dev/null; }

# --- 确定数据源 ---
FINAL_SOURCE=$(get_config ".IPSource")
if [ -n "$SOURCE" ]; then
    FINAL_SOURCE="$SOURCE"
fi

# --- 输出目录管控 ---
DOMAIN=$(get_config ".Domain")
OUTPUT_DIR="$ROOT_DIR/output/$DOMAIN"
mkdir -p "$OUTPUT_DIR"

# --- 下载 CloudflareST ---
setup_cfst() {
    if [ "$FINAL_SOURCE" = "api" ]; then return 0; fi # API 模式不需要 cfst
    if [ -f "$CFST_BIN" ]; then return 0; fi
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64) PKG="cfst_linux_arm64.tar.gz" ;;
        x86_64)  PKG="cfst_linux_amd64.tar.gz" ;;
        *) echo "[ERROR] Unsupported arch: $ARCH"; exit 1 ;;
    esac
    local mirror=$(get_config ".DownloadMirror")
    [ "$mirror" = "null" ] && mirror=""
    [ "$QUIET" = "false" ] && echo ">>> Downloading CloudflareST..."
    local url="${mirror}https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/$PKG"
    curl -sL -o "/tmp/$PKG" "$url" || exit 1
    mkdir -p "$CORE_DIR"
    tar -zxf "/tmp/$PKG" -C "$CORE_DIR" cfst
    chmod +x "$CFST_BIN"
    rm -f "/tmp/$PKG"
}

# --- 执行测速 / API 获取 ---
run_type_speedtest() {
    local type=$1
    local config_key=".$type"
    [ "$(get_config "$config_key.Enable")" != "true" ] && return 1

    local output_csv="$OUTPUT_DIR/report_$type.csv"
    rm -f "$output_csv"

    if [ "$FINAL_SOURCE" = "api" ]; then
        if [ "$type" = "IPv6" ]; then
            [ "$QUIET" = "false" ] && echo ">>> API source selected. Skipping IPv6."
            return 0
        fi

        local api_url=$(get_config ".Api.IPv4")
        [ "$QUIET" = "false" ] && echo ">>> Fetching IPs from API ($api_url)..."
        
        local resp=$(curl -s --max-time 10 "$api_url")
        if [ -z "$resp" ]; then
            echo "[ERROR] API returned empty response or timed out."
            exit 1
        fi
        
        echo "IP,Address,PingTime,LossRate,Latency,Speed,Colo" > "$output_csv"
        for ip in $resp; do
            if echo "$ip" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
                echo "$ip,$ip,0,0,0,100,API" >> "$output_csv"
            fi
        done
        
        local count=$(wc -l < "$output_csv")
        count=$((count - 1))
        if [ "$count" -le 0 ]; then
            echo "[ERROR] No valid IPv4 addresses found in API response."
            exit 1
        fi
        [ "$QUIET" = "false" ] && echo ">>> API fetch completed. Saved $count IPs to $output_csv"
        return 0
    fi

    # 本地测速模式
    [ "$QUIET" = "false" ] && echo ">>> Running Speedtest for $type..."
    local ip_file="$CORE_DIR/$(get_config "$config_key.File")"
    [ ! -f "$ip_file" ] && ip_file="$ROOT_DIR/core/$(get_config "$config_key.File")"
    [ ! -f "$ip_file" ] && echo "[WARN] $ip_file missing, skip $type" && return 1

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
[ "$QUIET" = "false" ] && echo ">>> Speedtest finished. Reports saved to output directory."
exit 0
