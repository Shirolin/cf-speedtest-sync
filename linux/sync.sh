#!/bin/sh
# Cloudflare SpeedTest Auto-Pilot (Sync Module)
# Author: Gemini CLI

# --- 初始化环境 ---
SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
ROOT_DIR=$(dirname "$SCRIPT_DIR")

# --- 参数解析（须在引入 common.sh 之前：log 依赖 DRY_RUN 决定是否加 [DRY-RUN] 前缀）---
DRY_RUN="false"
if [ "$1" = "test" ] || [ "$1" = "--test" ] || [ "$1" = "--dry-run" ]; then
    DRY_RUN="true"
fi

# --- 引入公共日志模块 (ROOT_DIR / CONFIG_FILE / LOG_FILE / log) ---
. "$SCRIPT_DIR/common.sh"

# --- 依赖与配置检查 ---
if ! command -v jq >/dev/null 2>&1; then log "[ERROR] jq not found. Please install it (opkg install jq)."; exit 1; fi
if [ ! -f "$CONFIG_FILE" ]; then log "[ERROR] config.json missing at $CONFIG_FILE"; exit 1; fi

get_config() {
    local key=$1
    local env_val=""
    case "$key" in
        ".SecretId")  env_val="$CF_SECRET_ID" ;;
        ".SecretKey") env_val="$CF_SECRET_KEY" ;;
    esac
    if [ -n "$env_val" ]; then echo "$env_val"; else jq -r "$key" "$CONFIG_FILE" 2>/dev/null; fi
}

DOMAIN=$(get_config ".Domain")

# --- DNS 引擎 (DNSPod) ---
dnspod_api() {
    local action=$1
    local payload=$2
    
    if ! command -v python3 >/dev/null 2>&1; then
        log "[ERROR] python3 is required for API requests but not found. Please install python3."
        echo '{"Response":{"Error":{"Code":"MissingDependency", "Message":"python3 not found"}}}'
        return 1
    fi
    
    local resp=$(python3 "$SCRIPT_DIR/dnspod.py" "$action" "$payload")
    
    if echo "$resp" | jq -e '.Response.Error' > /dev/null 2>&1; then
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
    
    local csv="$ROOT_DIR/output/$DOMAIN/report_$type.csv"
    if [ ! -f "$csv" ]; then
        # 未启用的类型无需同步；启用了却拿不到结果文件 = 测速环节失败
        if [ "$(get_config ".$type.Enable")" = "true" ]; then
            log "[ERROR] $csv not found. Speedtest step produced no result for $type."
            return 1
        fi
        return 0
    fi

    local failed=0
    
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
        if [ -z "$resp" ]; then
            log "[ERROR] Empty response from DNS API while listing $sub."
            failed=1
            continue
        fi

        # 严格校验 API 返回是否包含 Error
        if echo "$resp" | jq -e '.Response.Error' > /dev/null 2>&1; then
            log "[ERROR] API returned error for $sub. Skipping to prevent DNS corruption."
            failed=1
            continue
        fi

        # 严格校验 API 返回，防 Fail-Open
        local records=$(echo "$resp" | jq -e -c ".Response.RecordList // [] | map(select(.Type == \"$record_type\"))" 2>/dev/null)
        if [ $? -ne 0 ]; then
            log "[ERROR] Failed to parse RecordList for $sub. Skipping."
            failed=1
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

            if [ "$is_cfg_line" = "true" ]; then
                if [ "$is_best" = "true" ]; then
                    matches="$matches ${r_line}_${r_value}"
                else
                    log "[-] ($sub) Deleting ($r_line): $r_value"
                    if [ "$DRY_RUN" != "true" ]; then
                        local del_resp=$(dns_dispatch "DeleteRecord" "{\"Domain\":\"$domain\",\"RecordId\":$r_id}")
                        echo "$del_resp" | jq -e '.Response.Error' > /dev/null 2>&1 && failed=1
                    fi
                    sleep 1
                fi
            fi
        done

        for line in $lines; do
            for ip in $best_ips; do
                if [ -z "$(echo "$matches" | grep "${line}_${ip}")" ]; then
                    log "[+] ($sub) Adding ($line): $ip"
                    if [ "$DRY_RUN" != "true" ]; then
                        local add_resp=$(dns_dispatch "CreateRecord" "{\"Domain\":\"$domain\",\"SubDomain\":\"$sub\",\"RecordType\":\"$record_type\",\"RecordLine\":\"$line\",\"Value\":\"$ip\"}")
                        echo "$add_resp" | jq -e '.Response.Error' > /dev/null 2>&1 && failed=1
                    fi
                    sleep 1
                fi
            done
        done
    done

    if [ "$failed" -ne 0 ]; then
        log "[ERROR] $type sync finished with API errors."
        return 1
    fi
    return 0
}

SYNC_FAILED=0
run_sync "IPv4" || SYNC_FAILED=1
run_sync "IPv6" || SYNC_FAILED=1

if [ "$SYNC_FAILED" -ne 0 ]; then
    log "[ERROR] Sync finished with errors. DNS records may be missing or stale."
    exit 1
fi
log ">>> Sync completed."
exit 0
