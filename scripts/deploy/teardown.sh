#!/usr/bin/env bash
# =============================================================================
# teardown.sh — AWS Resource Cleanup Script
#
# Purpose:
#   Removes all AWS resources provisioned by deploy.sh to avoid ongoing charges.
#   Resources removed (in reverse dependency order):
#     1. CloudWatch dashboard
#     2. CloudWatch alarms
#     3. SNS topic and subscriptions
#     4. IAM instance profile and role
#     5. S3 bucket (all objects and versions deleted first)
#
# Usage:
#   chmod +x teardown.sh && ./teardown.sh
#
# WARNING:
#   This script permanently deletes the S3 bucket and ALL its contents,
#   including recovery logs. This action is IRREVERSIBLE.
#   You will be prompted to confirm before any resources are deleted.
#
# Exit codes:
#   0 — All resources removed successfully (or did not exist)
#   1 — A required AWS CLI command failed
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG — must match the values used in deploy.sh
# ---------------------------------------------------------------------------

AWS_REGION="us-east-1"
SNS_TOPIC_NAME="MonitoringAlerts"
IAM_ROLE_NAME="EC2MonitoringRole"
IAM_INSTANCE_PROFILE_NAME="EC2MonitoringInstanceProfile"
DASHBOARD_NAME="EC2MonitoringDashboard"
EC2_INSTANCE_ID="i-0000000000000000"

# Derive the S3 bucket name the same way deploy.sh does
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null \
    || echo "unknown")"
S3_BUCKET="monitoring-logs-${ACCOUNT_ID}"

# ---------------------------------------------------------------------------
# HELPER FUNCTIONS
# ---------------------------------------------------------------------------

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# confirm_destructive_action
#   Prompts the user to type "yes" before proceeding with deletion.
confirm_destructive_action() {
    echo ""
    echo "⚠  WARNING: This will permanently delete the following AWS resources:"
    echo "   - S3 bucket:          ${S3_BUCKET} (and ALL its contents)"
    echo "   - IAM role:           ${IAM_ROLE_NAME}"
    echo "   - IAM instance profile: ${IAM_INSTANCE_PROFILE_NAME}"
    echo "   - SNS topic:          ${SNS_TOPIC_NAME}"
    echo "   - CloudWatch alarms:  (all alarms for instance ${EC2_INSTANCE_ID})"
    echo "   - CloudWatch dashboard: ${DASHBOARD_NAME}"
    echo ""
    read -r -p "Type 'yes' to confirm deletion: " confirmation
    if [[ "$confirmation" != "yes" ]]; then
        echo "Teardown cancelled."
        exit 0
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# STEP 1: Delete CloudWatch Dashboard
# ---------------------------------------------------------------------------

delete_dashboard() {
    log "==> Step 1: Deleting CloudWatch dashboard: ${DASHBOARD_NAME}"

    if aws cloudwatch delete-dashboards \
        --dashboard-names "${DASHBOARD_NAME}" \
        --region "${AWS_REGION}" \
        --output text > /dev/null 2>&1; then
        log "    ✓ Dashboard deleted"
    else
        log "    Dashboard not found or already deleted — skipping"
    fi
}

# ---------------------------------------------------------------------------
# STEP 2: Delete CloudWatch Alarms
# ---------------------------------------------------------------------------

delete_alarms() {
    log "==> Step 2: Deleting CloudWatch alarms for instance: ${EC2_INSTANCE_ID}"

    local alarm_names=(
        "HighCPUUtilization-${EC2_INSTANCE_ID}"
        "HighMemoryUtilization-${EC2_INSTANCE_ID}"
        "HighDiskUtilization-${EC2_INSTANCE_ID}"
        "EC2StatusCheckFailed-${EC2_INSTANCE_ID}"
        "CloudWatchAgentHeartbeatMissing-${EC2_INSTANCE_ID}"
    )

    # delete-alarms accepts up to 100 alarm names at once
    aws cloudwatch delete-alarms \
        --alarm-names "${alarm_names[@]}" \
        --region "${AWS_REGION}" \
        --output text > /dev/null 2>&1 \
        || log "    Some alarms not found — continuing"

    log "    ✓ CloudWatch alarms deleted"
}

# ---------------------------------------------------------------------------
# STEP 3: Delete SNS Topic and Subscriptions
# ---------------------------------------------------------------------------

delete_sns_topic() {
    log "==> Step 3: Deleting SNS topic: ${SNS_TOPIC_NAME}"

    # Look up the topic ARN by name
    local topic_arn
    topic_arn="$(aws sns list-topics \
        --region "${AWS_REGION}" \
        --query "Topics[?ends_with(TopicArn, ':${SNS_TOPIC_NAME}')].TopicArn" \
        --output text 2>/dev/null || true)"

    if [[ -z "$topic_arn" ]]; then
        log "    SNS topic not found — skipping"
        return 0
    fi

    # Delete all subscriptions before deleting the topic
    local sub_arns
    mapfile -t sub_arns < <(aws sns list-subscriptions-by-topic \
        --topic-arn "${topic_arn}" \
        --region "${AWS_REGION}" \
        --query 'Subscriptions[].SubscriptionArn' \
        --output text 2>/dev/null | tr '\t' '\n' || true)

    for sub_arn in "${sub_arns[@]}"; do
        [[ "$sub_arn" == "PendingConfirmation" ]] && continue
        aws sns unsubscribe \
            --subscription-arn "${sub_arn}" \
            --region "${AWS_REGION}" \
            --output text > /dev/null 2>&1 || true
    done

    aws sns delete-topic \
        --topic-arn "${topic_arn}" \
        --region "${AWS_REGION}" \
        --output text > /dev/null \
        || die "Failed to delete SNS topic ${topic_arn}"

    log "    ✓ SNS topic deleted: ${topic_arn}"
}

# ---------------------------------------------------------------------------
# STEP 4: Delete IAM Instance Profile and Role
# ---------------------------------------------------------------------------

delete_iam_resources() {
    log "==> Step 4: Deleting IAM role and instance profile"

    # Remove the role from the instance profile first
    aws iam remove-role-from-instance-profile \
        --instance-profile-name "${IAM_INSTANCE_PROFILE_NAME}" \
        --role-name "${IAM_ROLE_NAME}" \
        --output text > /dev/null 2>&1 \
        || log "    Role not in instance profile — skipping removal"

    # Delete the instance profile
    aws iam delete-instance-profile \
        --instance-profile-name "${IAM_INSTANCE_PROFILE_NAME}" \
        --output text > /dev/null 2>&1 \
        || log "    Instance profile not found — skipping"
    log "    Instance profile deleted: ${IAM_INSTANCE_PROFILE_NAME}"

    # Delete the inline policy attached to the role
    aws iam delete-role-policy \
        --role-name "${IAM_ROLE_NAME}" \
        --policy-name "EC2MonitoringPolicy" \
        --output text > /dev/null 2>&1 \
        || log "    Inline policy not found — skipping"

    # Delete the role itself
    aws iam delete-role \
        --role-name "${IAM_ROLE_NAME}" \
        --output text > /dev/null 2>&1 \
        || log "    IAM role not found — skipping"
    log "    IAM role deleted: ${IAM_ROLE_NAME}"

    log "    ✓ IAM resources deleted"
}

# ---------------------------------------------------------------------------
# STEP 5: Empty and Delete S3 Bucket
# ---------------------------------------------------------------------------

delete_s3_bucket() {
    log "==> Step 5: Deleting S3 bucket: ${S3_BUCKET}"

    # Check if the bucket exists before attempting deletion
    if ! aws s3api head-bucket --bucket "${S3_BUCKET}" --region "${AWS_REGION}" \
        > /dev/null 2>&1; then
        log "    Bucket not found — skipping"
        return 0
    fi

    # Delete all object versions (required before bucket deletion when versioning is on)
    log "    Deleting all object versions..."
    aws s3api list-object-versions \
        --bucket "${S3_BUCKET}" \
        --region "${AWS_REGION}" \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
        --output json 2>/dev/null \
    | jq -c 'select(.Objects != null)' \
    | while IFS= read -r batch; do
        aws s3api delete-objects \
            --bucket "${S3_BUCKET}" \
            --delete "${batch}" \
            --region "${AWS_REGION}" \
            --output text > /dev/null 2>&1 || true
    done

    # Delete all delete markers
    log "    Deleting delete markers..."
    aws s3api list-object-versions \
        --bucket "${S3_BUCKET}" \
        --region "${AWS_REGION}" \
        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
        --output json 2>/dev/null \
    | jq -c 'select(.Objects != null)' \
    | while IFS= read -r batch; do
        aws s3api delete-objects \
            --bucket "${S3_BUCKET}" \
            --delete "${batch}" \
            --region "${AWS_REGION}" \
            --output text > /dev/null 2>&1 || true
    done

    # Delete the now-empty bucket
    aws s3api delete-bucket \
        --bucket "${S3_BUCKET}" \
        --region "${AWS_REGION}" \
        --output text > /dev/null \
        || die "Failed to delete S3 bucket ${S3_BUCKET}"

    log "    ✓ S3 bucket deleted: ${S3_BUCKET}"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
    echo "============================================================"
    echo "  Automated Cloud Monitoring & Recovery — Teardown Script"
    echo "============================================================"

    confirm_destructive_action

    delete_dashboard
    delete_alarms
    delete_sns_topic
    delete_iam_resources
    delete_s3_bucket

    echo ""
    echo "============================================================"
    echo "  Teardown complete — all resources removed."
    echo "============================================================"
}

main "$@"
