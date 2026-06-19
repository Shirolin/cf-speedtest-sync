#!/bin/sh
# Shell script to view Cloudflare DNS sync logs from the past 7 days.
# Support environments with busybox (sh/ash) and bash.

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ROOT_DIR=$(dirname "$SCRIPT_DIR")
CONFIG_FILE="$ROOT_DIR/config.json"

# Check if config.json exists to extract domain
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] config.json missing. Cannot determine domain name."
    exit 1
fi

DOMAIN=$(jq -r ".Domain" "$CONFIG_FILE" 2>/dev/null)
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "null" ]; then
    echo "[ERROR] Failed to parse domain from config.json"
    exit 1
fi

LOG_FILE="$ROOT_DIR/output/$DOMAIN/sync.log"

if [ ! -f "$LOG_FILE" ]; then
    echo "[ERROR] Log file not found at: $LOG_FILE"
    exit 1
fi

# Calculate the timestamp threshold for 7 days ago
# Compatible with busybox date, GNU date, and macOS date
if date -d "7 days ago" +%Y-%m-%d >/dev/null 2>&1; then
    # GNU date / Linux
    THRESHOLD_DATE=$(date -d "7 days ago" +%Y-%m-%d)
elif date -v-7d +%Y-%m-%d >/dev/null 2>&1; then
    # macOS/BSD date
    THRESHOLD_DATE=$(date -v-7d +%Y-%m-%d)
else
    # Fallback to simple calculation (seconds since epoch)
    NOW=$(date +%s)
    SEVEN_DAYS_AGO=$((NOW - 7 * 86400))
    THRESHOLD_DATE=$(date -d "@$SEVEN_DAYS_AGO" +%Y-%m-%d 2>/dev/null)
    if [ -z "$THRESHOLD_DATE" ]; then
        # Last resort fallback: if date calculation is completely unsupported on target shell, output the entire log file
        echo "[WARN] Date calculation unsupported. Printing full log instead."
        cat "$LOG_FILE"
        exit 0
    fi
fi

echo ">>> Filter logs since: $THRESHOLD_DATE (Past 7 days) <<<"
echo "--------------------------------------------------------"

# Stream line by line to support any POSIX sh
while IFS= read -r line; do
    # Extract date from [YYYY-MM-DD HH:MM:SS]
    case "$line" in
        \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
            log_date=$(echo "$line" | cut -d' ' -f1 | tr -d '[]')
            if [ "$log_date" ] && [ "$log_date" \>= "$THRESHOLD_DATE" ]; then
                echo "$line"
            fi
            ;;
        *)
            # Non-timestamp lines (e.g. error/detailed info) are preserved
            echo "$line"
            ;;
    esac
done < "$LOG_FILE"
