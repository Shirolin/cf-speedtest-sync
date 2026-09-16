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

# --- 兜底数据源 ---
# 与主接口同源（ymyuuu/IPDB 优选结果），但走 GitHub 独立基建：
# 主接口返回 400/宕机时该文件仍在每小时更新，可作为降级数据源。
# 可用 config.json 的 Api.IPv4Fallback 覆盖；显式设为 [] 表示关闭兜底。
DEFAULT_FALLBACK_URL="https://raw.githubusercontent.com/ymyuuu/IPDB/main/BestCF/bestcfv4.txt"
# 降级标记：主源全败但兜底成功时为 1，最终退出码 2（数据可用但已降级）
API_DEGRADED=0

# --- 引入公共日志模块 (ROOT_DIR / CONFIG_FILE / LOG_FILE / log) ---
. "$SCRIPT_DIR/common.sh"

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
if ! command -v jq >/dev/null 2>&1; then log "[ERROR] jq not found. Please install it (opkg install jq)."; exit 1; fi
if [ ! -f "$CONFIG_FILE" ]; then log "[ERROR] config.json missing at $CONFIG_FILE"; exit 1; fi

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
    local url="${mirror}https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/$PKG"
    log ">>> Downloading CloudflareST for $ARCH..."
    if ! curl -sL -o "/tmp/$PKG" "$url"; then
        log "[ERROR] Failed to download cfst: $url"
        exit 1
    fi
    mkdir -p "$CORE_DIR"
    if ! tar -zxf "/tmp/$PKG" -C "$CORE_DIR" cfst; then
        log "[ERROR] Failed to extract cfst from /tmp/$PKG"
        rm -f "/tmp/$PKG"
        exit 1
    fi
    chmod +x "$CFST_BIN"
    rm -f "/tmp/$PKG"
}

# --- 获取大厂 SaaS 优质 IP 网段 ---
get_saas_ips() {
    local domains="cname.pages.dev anycast.cloudflare.com discord.com zoom.us cloudflare.com"
    local temp_file="$OUTPUT_DIR/saas_ips.txt"
    rm -f "$temp_file"
    
    for d in $domains; do
        local ips=""
        if command -v dig >/dev/null 2>&1; then
            ips=$(dig +short A "$d" | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
        elif command -v nslookup >/dev/null 2>&1; then
            ips=$(nslookup -query=A "$d" 2>/dev/null | awk '/^Address: / { print $2 }' | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
        elif command -v getent >/dev/null 2>&1; then
            ips=$(getent ahosts "$d" | awk '{print $1}' | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
        fi
        
        for ip in $ips; do
            local prefix=$(echo "$ip" | cut -d. -f1-3)
            for i in $(seq 1 254); do
                echo "$prefix.$i" >> "$temp_file"
            done
        done
    done
    
    if [ -f "$temp_file" ]; then
        sort -u "$temp_file" -o "$temp_file"
    fi
}

# --- 从单一数据源抓取 IPv4 列表 ---
# 成功：把合法 IPv4 逐行写到 stdout 并返回 0；失败：写日志并返回 1。
# 失败时记录 HTTP 状态码与响应开头，避免"接口返回 400 + HTML 帮助页"被误判成网络问题。
fetch_ipv4_from() {
    local url="$1"
    local body="/tmp/cfsync_fetch.$$"
    local code head_txt

    code=$(curl -s -m 10 -o "$body" -w '%{http_code}' "$url" 2>/dev/null)
    [ -z "$code" ] && code="000"   # curl 自身失败（DNS/连接/超时）拿不到状态码

    if grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' "$body" 2>/dev/null; then
        grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' "$body"
        rm -f "$body"
        return 0
    fi

    head_txt=$(head -c 120 "$body" 2>/dev/null | tr '\n\r\t' '   ')
    rm -f "$body"
    log "[WARN] Source unusable (HTTP $code, no valid IPv4): $url"
    [ -n "$head_txt" ] && log "[WARN] Response head: $head_txt"
    return 1
}

# --- 执行测速 / API 获取 ---
run_type_speedtest() {
    local type=$1
    local config_key=".$type"

    # 未启用的协议不算失败，直接跳过
    if [ "$(get_config "$config_key.Enable")" != "true" ]; then
        log ">>> $type disabled in config.json. Skipping."
        return 0
    fi

    local output_csv="$OUTPUT_DIR/report_$type.csv"
    rm -f "$output_csv"

    if [ "$FINAL_SOURCE" = "api" ]; then
        if [ "$type" = "IPv6" ]; then
            log ">>> API source does not support $type. Skipping."
            return 0
        fi

        local api_url=$(get_config ".Api.IPv4")
        if [ -z "$api_url" ] || [ "$api_url" = "null" ]; then
            log "[ERROR] Api.IPv4 is empty in config.json."
            return 1
        fi

        local retries=$(get_config ".Api.Retries")
        case "$retries" in ''|*[!0-9]*) retries=3 ;; esac
        [ "$retries" -lt 1 ] && retries=1

        # 主源：重试若干次，覆盖单次抖动（持续多天的接口故障由兜底源处理）
        local ips="" attempt=1 delay=5
        while [ "$attempt" -le "$retries" ]; do
            log ">>> Fetching IPs from API ($api_url) [attempt $attempt/$retries]..."
            ips=$(fetch_ipv4_from "$api_url")
            [ -n "$ips" ] && break
            if [ "$attempt" -lt "$retries" ]; then
                log "[WARN] API attempt $attempt/$retries failed; retrying in ${delay}s..."
                sleep "$delay"
                delay=$((delay * 2))
            fi
            attempt=$((attempt + 1))
        done

        # 兜底源：主源全败时按顺序尝试（默认内置 GitHub 镜像，可用 [] 关闭）
        if [ -z "$ips" ]; then
            local fallbacks=$(get_config '.Api.IPv4Fallback[]?')
            if [ "$(get_config '.Api.IPv4Fallback | type')" != "array" ]; then
                fallbacks="$DEFAULT_FALLBACK_URL"
            fi
            for url in $fallbacks; do
                log "[WARN] Primary API failed after $retries attempt(s). Trying fallback source: $url"
                ips=$(fetch_ipv4_from "$url")
                if [ -n "$ips" ]; then
                    API_DEGRADED=1
                    break
                fi
            done
        fi

        if [ -z "$ips" ]; then
            log "[ERROR] All sources failed; no valid IPv4 obtained. DNS left untouched."
            rm -f "$output_csv"
            return 1
        fi

        echo "IP,Address,PingTime,LossRate,Latency,Speed,Colo" > "$output_csv"
        local count=0
        for ip in $ips; do
            echo "$ip,$ip,0,0,0,100,API" >> "$output_csv"
            count=$((count + 1))
        done
        log ">>> API fetch completed. Saved $count IPs to $output_csv"
        return 0
    fi

    # 本地测速模式
    local ip_file="$CORE_DIR/$(get_config "$config_key.File")"
    [ ! -f "$ip_file" ] && ip_file="$ROOT_DIR/core/$(get_config "$config_key.File")"

    if [ "$FINAL_SOURCE" = "saas" ]; then
        if [ "$type" = "IPv6" ]; then
            log ">>> SaaS source does not support $type. Skipping."
            return 0
        fi
        log ">>> [1/3] Gathering SaaS domains IP ranges..."
        get_saas_ips
        local temp_file="$OUTPUT_DIR/saas_ips.txt"
        if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
            ip_file="$temp_file"
            local count=$(wc -l < "$temp_file")
            log ">>> Gathered $count IPs from SaaS domains. Running speedtest..."
        else
            log "[WARN] Failed to resolve SaaS domains. Falling back to default IP list."
        fi
    else
        log ">>> Running Speedtest for $type..."
    fi

    if [ ! -f "$ip_file" ]; then
        log "[ERROR] IP list $ip_file missing. Cannot run speedtest for $type."
        return 1
    fi

    local flags="-f $ip_file -url $(get_config "$config_key.SpeedTestURL") -httping -n $(get_config "$config_key.Threads") -dn $(get_config "$config_key.DownloadCount") -tl $(get_config "$config_key.LatencyLimit") -o $output_csv -p 0"
    [ "$type" = "IPv6" ] && flags="$flags -ipv6"

    if [ "$QUIET" = "true" ]; then
        "$CFST_BIN" $flags > /dev/null 2>&1
    else
        "$CFST_BIN" $flags
    fi
    CFST_STATUS=$?

    if [ "$FINAL_SOURCE" = "saas" ] && [ -f "$OUTPUT_DIR/saas_ips.txt" ]; then
        rm -f "$OUTPUT_DIR/saas_ips.txt"
    fi

    if [ "$CFST_STATUS" -ne 0 ]; then
        log "[ERROR] cfst exited with code $CFST_STATUS for $type."
        return 1
    fi
    if [ ! -s "$output_csv" ]; then
        log "[ERROR] cfst produced no result file for $type: $output_csv"
        return 1
    fi
    return 0
}

setup_cfst

STATUS=0
run_type_speedtest "IPv4" || STATUS=1
run_type_speedtest "IPv6" || STATUS=1

if [ "$STATUS" -ne 0 ]; then
    log "[ERROR] Speedtest finished with errors. Reports may be incomplete."
    exit 1
fi
if [ "$API_DEGRADED" -ne 0 ]; then
    log "[WARN] Degraded run: primary API failed, data came from the fallback source."
    exit 2
fi
log ">>> Speedtest finished. Reports saved to output directory."
exit 0
