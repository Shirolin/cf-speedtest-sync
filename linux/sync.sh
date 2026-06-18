#!/bin/sh
# Cloudflare SpeedTest Auto-Pilot (Sync Module)
# Author: Gemini CLI

# --- 初始化环境 ---
SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
ROOT_DIR=$(dirname "$SCRIPT_DIR")
CONFIG_FILE="$ROOT_DIR/config.json"
LOG_FILE="$ROOT_DIR/sync.log"

# --- 参数解析 ---
DRY_RUN="false"
if [ "$1" = "test" ] || [ "$1" = "--test" ] || [ "$1" = "--dry-run" ]; then
    DRY_RUN="true"
fi

# --- 依赖与配置检查 ---
if ! command -v jq >/dev/null 2>&1; then echo "[ERROR] jq not found."; exit 1; fi
if [ ! -f "$CONFIG_FILE" ]; then echo "[ERROR] config.json missing"; exit 1; fi

log() {
    [ "$DRY_RUN" = "true" ] && printf "[DRY-RUN] " >&2
    if [ -f "$LOG_FILE" ] && [ $(wc -c < "$LOG_FILE") -gt 1048576 ]; then
        local tmp_log=$(tail -n 1000 "$LOG_FILE")
        echo "$tmp_log" > "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated" >> "$LOG_FILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}

get_config() {
    local key=$1
    local env_val=""
    case "$key" in
        ".SecretId")  env_val="$CF_SECRET_ID" ;;
        ".SecretKey") env_val="$CF_SECRET_KEY" ;;
    esac
    if [ -n "$env_val" ]; then echo "$env_val"; else jq -r "$key" "$CONFIG_FILE" 2>/dev/null; fi
}

# --- DNS 引擎 (DNSPod) ---
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

dns_dispatch() {
    local provider=$(get_config ".DNSProvider")
    case "$provider" in
        dnspod) dnspod_api "$@" ;;
        *) log "[ERROR] Unsupported DNS: $provider"; return 1 ;;
    esac
}

# --- 同步逻辑 ---
run_sync() {
    local type=$1
    local record_type="A"
    [ "$type" = "IPv6" ] && record_type="AAAA"
    
    local csv="$ROOT_DIR/report_$type.csv"
    if [ ! -f "$csv" ]; then
        # 仅当启用了该类型，且文件不存在时报错
        [ "$(get_config ".$type.Enable")" = "true" ] && log "[WARN] $csv not found. Please run speedtest.sh first."
        return 0
    fi
    
    local best_ips=$(tail -n +2 "$csv" | awk -F, '{print $1}' | head -n $(get_config ".$type.DownloadCount"))
    
    # 清理非IP字符串并统计有效数量
    local valid_ips=""
    for ip in $best_ips; do
        if echo "$ip" | grep -Eq '^[0-9a-fA-F\.:]+$'; then
            valid_ips="$valid_ips $ip"
        fi
    done
    best_ips=$(echo "$valid_ips" | xargs)

    if [ -z "$best_ips" ]; then
        log "[ERROR] No valid $type IPs found in report. Aborting to protect DNS."
        return 1
    fi

    log ">>> Syncing $type (Best IPs: $(echo $best_ips | xargs))"
    local domain=$(get_config ".Domain")
    local lines=$(get_config ".Lines[]")
    local subdomains=$(get_config '.SubDomain | if type=="array" then .[] else . end')

    for sub in $subdomains; do
        log ">>> Processing: $sub ($record_type)"
        local resp=$(dns_dispatch "DescribeRecordList" "{\"Domain\":\"$domain\",\"Subdomain\":\"$sub\"}")
        [ -z "$resp" ] && continue
        
        # 严格校验 API 返回是否包含 Error
        if echo "$resp" | jq -e '.Response.Error' > /dev/null 2>&1; then
            log "[ERROR] API returned error for $sub. Skipping to prevent DNS corruption."
            continue
        fi

        # 严格校验 API 返回，防 Fail-Open
        local records=$(echo "$resp" | jq -e -c ".Response.RecordList // [] | map(select(.Type == \"$record_type\"))" 2>/dev/null)
        if [ $? -ne 0 ]; then
            log "[ERROR] Failed to parse RecordList for $sub. Skipping."
            continue
        fi

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
                sleep 1
            fi
        done

        for line in $lines; do
            for ip in $best_ips; do
                [ -z "$(echo "$matches" | grep "${line}_${ip}")" ] && \
                log "[+] ($sub) Adding ($line): $ip" && \
                { [ "$DRY_RUN" = "true" ] || dns_dispatch "CreateRecord" "{\"Domain\":\"$domain\",\"SubDomain\":\"$sub\",\"RecordType\":\"$record_type\",\"RecordLine\":\"$line\",\"Value\":\"$ip\"}" > /dev/null; } && \
                sleep 1
            done
        done
    done
}

run_sync "IPv4"
run_sync "IPv6"
log ">>> Sync completed."
exit 0
