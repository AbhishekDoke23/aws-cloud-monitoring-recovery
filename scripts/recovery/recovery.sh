#!/usr/bin/env bash
# =============================================================================
# recovery.sh — Auto-Recovery Agent
#
# Purpose:
#   Monitors a configurable list of systemd services on an EC2 instance.
#   When a service is found to be inactive or failed, the agent attempts to
#   restart it (up to MAX_RETRIES times). Recovery and failure events are
#   logged locally and uploaded to an S3 bucket. If all restart attempts
#   fail, an SNS alert is published to notify the operations team.
#
# Usage:
#   Run directly:   sudo bash recovery.sh
#   As a service:   managed by systemd (see systemd/recovery-agent.service)
#
# Dependencies:
#   - AWS CLI v2 (configured with an IAM instance profile)
#   - systemctl
#   - jq (optional, used for JSON log formatting)
#
# Configuration:
#   Edit recovery-config.conf to add/remove services to monitor.
#   Edit the variables in the CONFIG section below to tune behaviour.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG — adjust these values to match your environment
# ---------------------------------------------------------------------------

# Path to the file listing services to monitor (one per line)
CONFIG_FILE="$(dirname "$0")/recovery-config.conf"

# How often (in seconds) to run a full health-check cycle
CHECK_INTERVAL=60

# Maximum number of restart attempts before declaring a service failed
MAX_RETRIES=3

# Seconds to wait between restart attempts
RETRY_DELAY=10

# Local directory where log files are written before S3 upload
LOCAL_LOG_DIR="/var/log/recovery-agent"

# S3 bucket name — set via environment variable or replace the default below
S3_BUCKET="${S3_BUCKET:-your-monitoring-log-bucket}"

# SNS topic ARN — set via environment variable or replace the default below
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:us-east-1:123456789012:MonitoringAlerts}"

# AWS region
AWS_REGION="${AWS_REGION:-us-east-1}"

# ---------------------------------------------------------------------------
# SETUP — create log directory if it does not exist
# ---------------------------------------------------------------------------

mkdir -p "$LOCAL_LOG_DIR"

# Build a datestamped log file path for today's entries
LOG_FILE="$LOCAL_LOG_DIR/recovery-$(date +%Y-%m-%d).log"

# ---------------------------------------------------------------------------
# HELPER FUNCTIONS
# ---------------------------------------------------------------------------

# log_event <level> <service> <message>
#   Writes a structured log line to the daily log file and to stdout.
log_event() {
    local level="$1"
    local service="$2"
    local message="$3"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Write a JSON-formatted log entry for easy parsing downstream
    local entry
    entry=$(printf '{"timestamp":"%s","level":"%s","service":"%s","message":"%s"}\n' \
        "$timestamp" "$level" "$service" "$message")

    echo "$entry" | tee -a "$LOG_FILE"
}

# upload_log_to_s3
#   Uploads today's log file to S3 under a date-partitioned prefix.
#   If the upload fails, the log is retained locally and a warning is printed.
upload_log_to_s3() {
    local date_prefix
    date_prefix="$(date +%Y/%m/%d)"
    local s3_key="logs/recovery/${date_prefix}/recovery-$(date +%Y-%m-%d).log"

    if aws s3 cp "$LOG_FILE" "s3://${S3_BUCKET}/${s3_key}" \
        --region "$AWS_REGION" \
        --quiet 2>/dev/null; then
        log_event "INFO" "s3-upload" "Log uploaded to s3://${S3_BUCKET}/${s3_key}"
    else
        # Non-fatal: retain log locally and retry on next cycle
        log_event "WARN" "s3-upload" "S3 upload failed — log retained locally at ${LOG_FILE}"
    fi
}

# publish_sns_alert <service> <message>
#   Publishes an incident notification to the configured SNS topic.
#   Logs an error if the publish call fails (non-fatal).
publish_sns_alert() {
    local service="$1"
    local message="$2"
    local subject="[INCIDENT] Recovery failed for service: ${service}"

    if aws sns publish \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "$subject" \
        --message "$message" \
        --region "$AWS_REGION" \
        --output text \
        --query 'MessageId' > /dev/null 2>&1; then
        log_event "INFO" "$service" "SNS alert published successfully"
    else
        # Log the failure but do not exit — monitoring must continue
        log_event "ERROR" "$service" "SNS publish failed — check IAM permissions for SNS:Publish"
    fi
}

# check_and_recover <service>
#   Checks whether <service> is active. If not, attempts to restart it up to
#   MAX_RETRIES times. Publishes an SNS alert if all retries are exhausted.
check_and_recover() {
    local service="$1"

    # Query systemd for the service's active state
    local status
    status="$(systemctl is-active "$service" 2>/dev/null || true)"

    if [[ "$status" == "active" ]]; then
        # Service is healthy — log at DEBUG level (low noise)
        log_event "DEBUG" "$service" "Health check passed — status: active"
        return 0
    fi

    # Service is not active — begin recovery attempts
    log_event "WARN" "$service" "Health check failed — status: ${status}. Starting recovery..."

    local attempt=0
    while (( attempt < MAX_RETRIES )); do
        (( attempt++ ))
        log_event "INFO" "$service" "Restart attempt ${attempt}/${MAX_RETRIES}"

        # Attempt to restart the service via systemctl
        if systemctl restart "$service" 2>/dev/null; then
            # Wait briefly and re-check the status
            sleep 5
            local new_status
            new_status="$(systemctl is-active "$service" 2>/dev/null || true)"

            if [[ "$new_status" == "active" ]]; then
                log_event "INFO" "$service" \
                    "Recovery successful on attempt ${attempt} — service is now active"
                upload_log_to_s3
                return 0
            fi
        fi

        # Restart did not succeed — wait before next attempt
        log_event "WARN" "$service" \
            "Attempt ${attempt} did not restore service — waiting ${RETRY_DELAY}s before retry"
        sleep "$RETRY_DELAY"
    done

    # All retries exhausted — publish an SNS incident alert
    local alert_message
    alert_message="$(printf \
        'INCIDENT: Service "%s" on EC2 instance could not be recovered after %d attempts.\nLast known status: %s\nTimestamp: %s\nLog file: %s' \
        "$service" "$MAX_RETRIES" "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_FILE")"

    log_event "ERROR" "$service" \
        "All ${MAX_RETRIES} recovery attempts failed — publishing SNS alert"
    publish_sns_alert "$service" "$alert_message"
    upload_log_to_s3
}

# load_services
#   Reads the config file and returns a list of service names to monitor.
#   Exits with an error if the config file is missing or contains no entries.
load_services() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: Configuration file not found: ${CONFIG_FILE}" >&2
        exit 1
    fi

    # Strip comments and blank lines; collect non-empty service names
    local services=()
    while IFS= read -r line; do
        # Remove inline comments and trim whitespace
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n "$line" ]] && services+=("$line")
    done < "$CONFIG_FILE"

    if (( ${#services[@]} == 0 )); then
        echo "ERROR: No services defined in ${CONFIG_FILE}" >&2
        exit 1
    fi

    printf '%s\n' "${services[@]}"
}

# ---------------------------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------------------------

log_event "INFO" "recovery-agent" \
    "Recovery agent started — check interval: ${CHECK_INTERVAL}s, max retries: ${MAX_RETRIES}"

while true; do
    # Reload the service list on every cycle so config changes take effect
    # without restarting the agent
    mapfile -t SERVICES < <(load_services)

    log_event "DEBUG" "recovery-agent" \
        "Starting health-check cycle for ${#SERVICES[@]} service(s): ${SERVICES[*]}"

    for service in "${SERVICES[@]}"; do
        check_and_recover "$service"
    done

    log_event "DEBUG" "recovery-agent" \
        "Health-check cycle complete — sleeping ${CHECK_INTERVAL}s"
    sleep "$CHECK_INTERVAL"
done
