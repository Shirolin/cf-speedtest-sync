#!/bin/sh
# Cloudflare SpeedTest Auto-Pilot (iStoreOS/R4S Phase 2)
# Author: Gemini CLI

# --- 依赖检查 ---
check_dependency() {
    for cmd in jq curl openssl; do
        if ! command -v $cmd >/dev/null 2>&1; then
            echo "[ERROR] $cmd is not installed."
            echo "Please run: opkg update && opkg install jq curl openssl-util"
            exit 1
        fi
    done
}

# --- 初始化环境 ---
SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
ROOT_DIR=$(dirname "$SCRIPT_DIR")
CONFIG_FILE="$ROOT_DIR/config.json"
CORE_DIR="$ROOT_DIR/core"
CFST_BIN="$CORE_DIR/cfst"
LOG_FILE="$ROOT_DIR/sync.log"
LOCK_FILE="/tmp/cf-speedtest-sync.lock"

# --- 工具函数 ---
log() {
    [ "$DRY_RUN" = "true" ] && printf "[DRY-RUN] "
    if [ -f "$LOG_FILE" ] && [ $(wc -c < "$LOG_FILE") -gt 1048576 ]; then
        local tmp_log=$(tail -n 1000 "$LOG_FILE")
        echo "$tmp_log" > "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated (exceeded 1MB)" >> "$LOG_FILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# --- 配置读取 (支持环境变量覆盖) ---
get_config() {
    local key=$1
    local env_val=""
    
    # 环境变量映射
    case "$key" in
        ".SecretId")  env_val="$CF_SECRET_ID" ;;
        ".SecretKey") env_val="$CF_SECRET_KEY" ;;
    esac

    if [ -n "$env_val" ]; then
        echo "$env_val"
    else
        jq -r "$key" "$CONFIG_FILE" 2>/dev/null
    fi
}

# --- 下载 CloudflareST ---
setup_cfst() {
    if [ -f "$CFST_BIN" ]; then return 0; fi
    
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64) PKG="CloudflareST_linux_arm64.tar.gz" ;;
        x86_64)  PKG="CloudflareST_linux_amd64.tar.gz" ;;
        *) log "[ERROR] Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    local mirror=$(get_config ".DownloadMirror")
    [ "$mirror" = "null" ] && mirror=""
    
    log ">>> Downloading CloudflareST for $ARCH..."
    local url="${mirror}https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/$PKG"
    if ! curl -sL -o "/tmp/$PKG" "$url"; then
        log "[ERROR] Download failed. URL: $url"
        exit 1
    fi
    mkdir -p "$CORE_DIR"
    tar -zxf "/tmp/$PKG" -C "$CORE_DIR" CloudflareST
    mv "$CORE_DIR/CloudflareST" "$CFST_BIN"
    chmod +x "$CFST_BIN"
    rm -f "/tmp/$PKG"
}

# --- DNS 供应商抽象层 ---

# 腾讯云 (DNSPod) 实现
dnspod_api() {
    local action=$1
    local payload=$2
    local secret_id=$(get_config ".SecretId")
    local secret_key=$(get_config ".SecretKey")
    local service="dnspod"
    local version="2021-03-23"
    local host="dnspod.tencentcloudapi.com"
    local timestamp=$(date +%s)
    local date=$(date -u -d "@$timestamp" +"%Y-%m-%d" 2>/dev/null || date -u +"%Y-%m-%d")
    
    local algorithm="TC3-HMAC-SHA256"
    local ct="application/json; charset=utf-8"
    local hashed_payload=$(printf "%s" "$payload" | openssl dgst -sha256 | sed 's/.* //')
    local canonical_request="POST\n/\n\ncontent-type:$ct\nhost:$host\n\ncontent-type;host\n$hashed_payload"
    local credential_scope="$date/$service/tc3_request"
    local hashed_canonical_request=$(printf "%b" "$canonical_request" | openssl dgst -sha256 | sed 's/.* //')
    local string_to_sign="$algorithm\n$timestamp\n$credential_scope\n$hashed_canonical_request"
    
    hmac_sha256() { printf "%s" "$2" | openssl dgst -sha256 -hmac "$1" -binary; }
    local k_date=$(hmac_sha256 "TC3$secret_key" "$date")
    local k_service=$(hmac_sha256 "$k_date" "$service")
    local k_signing=$(hmac_sha256 "$k_service" "tc3_request")
    local signature=$(printf "%s" "$string_to_sign" | openssl dgst -sha256 -hmac "$k_signing" | sed 's/.* //')
    
    local auth="$algorithm Credential=$secret_id/$credential_scope, SignedHeaders=content-type;host, Signature=$signature"
    local resp=$(curl -s -X POST "https://$host" -H "Authorization: $auth" -H "Content-Type: $ct" -H "X-TC-Action: $action" -H "X-TC-Version: $version" -H "X-TC-Timestamp: $timestamp" -d "$payload")
    
    if echo "$resp" | jq -e '.Response.Error' > /dev/null; then
        log "[ERROR] DNSPod $action failed: $(echo "$resp" | jq -r '.Response.Error.Message')"
    fi
    echo "$resp"
}

# 统一 DNS 接口
dns_dispatch() {
    local provider=$(get_config ".DNSProvider")
    case "$provider" in
        dnspod) dnspod_api "$@" ;;
        *) log "[ERROR] Unsupported DNS provider: $provider"; return 1 ;;
    esac
}

# --- 核心逻辑 ---
run_speedtest() {
    local type=$1
    local config_key=".$type"
    [ "$(get_config "$config_key.Enable")" != "true" ] && return 1

    log ">>> [1/2] Running Speedtest for $type..."
    local ip_file="$CORE_DIR/$(get_config "$config_key.File")"
    [ ! -f "$ip_file" ] && ip_file="$ROOT_DIR/core/$(get_config "$config_key.File")"
    [ ! -f "$ip_file" ] && log "[WARN] $ip_file missing, skip $type" && return 1

    local output_csv="/tmp/cfst_$type.csv"
    local flags="-f $ip_file -url $(get_config "$config_key.SpeedTestURL") -httping -n $(get_config "$config_key.Threads") -dn $(get_config "$config_key.DownloadCount") -tl $(get_config "$config_key.LatencyLimit") -o $output_csv -p 0"
    [ "$type" = "IPv6" ] && flags="$flags -ipv6"

    "$CFST_BIN" $flags
}

run_sync() {
    local type=$1
    local record_type="A"
    [ "$type" = "IPv6" ] && record_type="AAAA"
    
    local csv="/tmp/cfst_$type.csv"
    [ ! -f "$csv" ] && return 0
    
    local best_ips=$(tail -n +2 "$csv" | awk -F, '{print $1}' | head -n $(get_config ".$type.DownloadCount"))
    [ -z "$best_ips" ] && log "[ERROR] No valid $type IPs found." && return 1

    log ">>> [2/2] Syncing $type (Best IPs: $(echo $best_ips | xargs))"
    local domain=$(get_config ".Domain")
    local lines=$(get_config ".Lines[]")
    local subdomains=$(get_config ".SubDomain | if type=="array" then .[] else . end")

    for sub in $subdomains; do
        log ">>> Processing: $sub ($record_type)"
        local resp=$(dns_dispatch "DescribeRecordList" "{\"Domain\":\"$domain\",\"Subdomain\":\"$sub\"}")
        [ -z "$resp" ] && continue
        
        local records=$(echo "$resp" | jq -c ".Response.RecordList // [] | map(select(.Type == \"$record_type\"))")
        local matches=""
        
        for row in $(echo "$records" | jq -r '.[] | @base64'); do
            _jq() { printf "%s" ${row} | base64 -d | jq -r ${1}; }
            local r_id=$(_jq '.RecordId')
            local r_line=$(_jq '.Line')
            local r_value=$(_jq '.Value')

            local is_best=false
            for ip in $best_ips; do [ "$ip" = "$r_value" ] && is_best=true && break; done
            local is_cfg_line=false
            for l in $lines; do [ "$l" = "$r_line" ] && is_cfg_line=true && break; done

            if [ "$is_best" = "true" ] && [ "$is_cfg_line" = "true" ]; then
                matches="$matches ${r_line}_${r_value}"
            else
                log "[-] ($sub) Deleting ($r_line): $r_value"
                [ "$DRY_RUN" != "true" ] && dns_dispatch "DeleteRecord" "{\"Domain\":\"$domain\",\"RecordId\":$r_id}" > /dev/null
                sleep 0.3
            fi
        done

        for line in $lines; do
            for ip in $best_ips; do
                [ -z "$(echo "$matches" | grep "${line}_${ip}")" ] && \
                log "[+] ($sub) Adding ($line): $ip" && \
                { [ "$DRY_RUN" = "true" ] || dns_dispatch "CreateRecord" "{\"Domain\":\"$domain\",\"SubDomain\":\"$sub\",\"RecordType\":\"$record_type\",\"RecordLine\":\"$line\",\"Value\":\"$ip\"}" > /dev/null; } && \
                sleep 0.3
            done
        done
    done
}

# --- 执行入口 ---
case "$1" in
    install)   (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "0 4 * * * /bin/sh $SCRIPT_PATH > /dev/null 2>&1") | crontab -; echo "[SUCCESS] Installed."; exit 0 ;;
    uninstall) crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -; echo "[SUCCESS] Uninstalled."; exit 0 ;;
    test|--test|--dry-run) export DRY_RUN="true" ;;
    help|-h)   echo "Usage: $0 [install|uninstall|run|test]"; exit 0 ;;
esac

[ ! -f "$CONFIG_FILE" ] && echo "[ERROR] config.json missing" && exit 1
if [ -f "$LOCK_FILE" ] && kill -0 $(cat "$LOCK_FILE") 2>/dev/null; then log "[WARN] Running. Exit."; exit 0; fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE" /tmp/cfst_IPv4.csv /tmp/cfst_IPv6.csv; exit' INT TERM EXIT

check_dependency
setup_cfst
run_speedtest "IPv4" && run_sync "IPv4"
run_speedtest "IPv6" && run_sync "IPv6"
log ">>> Done!"
