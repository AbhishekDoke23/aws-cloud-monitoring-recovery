#!/usr/bin/env bash
# =============================================================================
# deploy.sh — AWS Resource Provisioning Script
#
# Purpose:
#   Provisions all AWS resources required by the Automated Cloud Monitoring &
#   Recovery System in the correct dependency order:
#     1. S3 log bucket (with versioning, encryption, lifecycle, and policy)
#     2. IAM role and instance profile
#     3. SNS topic and email subscription
#     4. Upload CloudWatch Agent config to S3
#     5. CloudWatch alarms
#     6. CloudWatch dashboard
#
# Usage:
#   Edit the CONFIG section below, then run:
#     chmod +x deploy.sh && ./deploy.sh
#
# Prerequisites:
#   - AWS CLI v2 installed and configured (aws configure)
#   - Sufficient IAM permissions to create S3, IAM, SNS, and CloudWatch resources
#
# Exit codes:
#   0 — All resources provisioned successfully
#   1 — An AWS CLI command failed (error message printed before exit)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG — edit these values before running
# ---------------------------------------------------------------------------

AWS_REGION="us-east-1"
ALERT_EMAIL="you@example.com"
EC2_INSTANCE_ID="i-0000000000000000"

# S3 bucket name must be globally unique — append your account ID or a random suffix
S3_BUCKET="monitoring-logs-$(aws sts get-caller-identity \
    --query Account --output text 2>/dev/null || echo "changeme")"

SNS_TOPIC_NAME="MonitoringAlerts"
IAM_ROLE_NAME="EC2MonitoringRole"
IAM_INSTANCE_PROFILE_NAME="EC2MonitoringInstanceProfile"
DASHBOARD_NAME="EC2MonitoringDashboard"

# Paths to supporting files (relative to the repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

IAM_TRUST_POLICY="${REPO_ROOT}/iam/ec2-trust-policy.json"
IAM_ROLE_POLICY="${REPO_ROOT}/iam/ec2-monitoring-role-policy.json"
S3_BUCKET_POLICY="${REPO_ROOT}/s3/bucket-policy.json"
CW_AGENT_CONFIG="${REPO_ROOT}/scripts/cloudwatch/cloudwatch-agent-config.json"
CW_ALARMS_SCRIPT="${REPO_ROOT}/cloudwatch/alarms.sh"
CW_DASHBOARD="${REPO_ROOT}/cloudwatch/dashboard.json"

# ---------------------------------------------------------------------------
# HELPER FUNCTIONS
# ---------------------------------------------------------------------------

# log <message>
#   Prints a timestamped status message to stdout.
log() {
    echo "[$(date +%H:%M:%S)] $*"
}

# die <message>
#   Prints an error message and exits with code 1.
die() {
    echo "ERROR: $*" >&2
    exit 1
}

# check_aws_cli
#   Verifies that AWS CLI v2 is installed and the caller is authenticated.
check_aws_cli() {
    log "Checking AWS CLI..."
    aws --version > /dev/null 2>&1 || die "AWS CLI not found. Install AWS CLI v2."
    ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
        || die "AWS CLI not configured. Run 'aws configure'."
    log "Authenticated as account: ${ACCOUNT_ID}"
}

# ---------------------------------------------------------------------------
# STEP 1: Create S3 Log Bucket
# ---------------------------------------------------------------------------

create_s3_bucket() {
    log "==> Step 1: Creating S3 log bucket: ${S3_BUCKET}"

    # Create the bucket (us-east-1 does not accept a LocationConstraint)
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket \
            --bucket "${S3_BUCKET}" \
            --region "${AWS_REGION}" \
            --output text > /dev/null \
            || die "Failed to create S3 bucket ${S3_BUCKET}"
    else
        aws s3api create-bucket \
            --bucket "${S3_BUCKET}" \
            --region "${AWS_REGION}" \
            --create-bucket-configuration "LocationConstraint=${AWS_REGION}" \
            --output text > /dev/null \
            || die "Failed to create S3 bucket ${S3_BUCKET}"
    fi
    log "    Bucket created: ${S3_BUCKET}"

    # Block all public access
    aws s3api put-public-access-block \
        --bucket "${S3_BUCKET}" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        || die "Failed to block public access on ${S3_BUCKET}"
    log "    Public access blocked"

    # Enable versioning
    aws s3api put-bucket-versioning \
        --bucket "${S3_BUCKET}" \
        --versioning-configuration "Status=Enabled" \
        || die "Failed to enable versioning on ${S3_BUCKET}"
    log "    Versioning enabled"

    # Enable server-side encryption (SSE-S3)
    aws s3api put-bucket-encryption \
        --bucket "${S3_BUCKET}" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                },
                "BucketKeyEnabled": true
            }]
        }' \
        || die "Failed to enable encryption on ${S3_BUCKET}"
    log "    Server-side encryption (SSE-S3) enabled"

    # Apply lifecycle policy: Glacier after 90 days, expire after 365 days
    aws s3api put-bucket-lifecycle-configuration \
        --bucket "${S3_BUCKET}" \
        --lifecycle-configuration '{
            "Rules": [{
                "ID": "LogRetentionPolicy",
                "Status": "Enabled",
                "Filter": {"Prefix": "logs/"},
                "Transitions": [{
                    "Days": 90,
                    "StorageClass": "GLACIER"
                }],
                "Expiration": {
                    "Days": 365
                },
                "NoncurrentVersionExpiration": {
                    "NoncurrentDays": 30
                }
            }]
        }' \
        || die "Failed to apply lifecycle policy on ${S3_BUCKET}"
    log "    Lifecycle policy applied (Glacier@90d, Expire@365d)"

    # Apply bucket policy (substitute ACCOUNT_ID placeholder)
    local policy
    policy="$(sed "s/ACCOUNT_ID/${ACCOUNT_ID}/g; s/your-monitoring-log-bucket/${S3_BUCKET}/g" \
        "${S3_BUCKET_POLICY}")"
    aws s3api put-bucket-policy \
        --bucket "${S3_BUCKET}" \
        --policy "${policy}" \
        || die "Failed to apply bucket policy on ${S3_BUCKET}"
    log "    Bucket policy applied"

    log "    ✓ S3 bucket ready: ${S3_BUCKET}"
}

# ---------------------------------------------------------------------------
# STEP 2: Create IAM Role and Instance Profile
# ---------------------------------------------------------------------------

create_iam_role() {
    log "==> Step 2: Creating IAM role: ${IAM_ROLE_NAME}"

    # Create the IAM role with the EC2 trust policy
    aws iam create-role \
        --role-name "${IAM_ROLE_NAME}" \
        --assume-role-policy-document "file://${IAM_TRUST_POLICY}" \
        --description "Least-privilege role for EC2 monitoring and recovery agent" \
        --output text > /dev/null \
        || die "Failed to create IAM role ${IAM_ROLE_NAME}"
    log "    Role created: ${IAM_ROLE_NAME}"

    # Substitute the bucket name placeholder in the role policy and attach it
    local policy
    policy="$(sed "s/your-monitoring-log-bucket/${S3_BUCKET}/g" "${IAM_ROLE_POLICY}")"
    aws iam put-role-policy \
        --role-name "${IAM_ROLE_NAME}" \
        --policy-name "EC2MonitoringPolicy" \
        --policy-document "${policy}" \
        || die "Failed to attach inline policy to ${IAM_ROLE_NAME}"
    log "    Inline policy attached"

    # Create the instance profile and add the role to it
    aws iam create-instance-profile \
        --instance-profile-name "${IAM_INSTANCE_PROFILE_NAME}" \
        --output text > /dev/null \
        || die "Failed to create instance profile ${IAM_INSTANCE_PROFILE_NAME}"

    aws iam add-role-to-instance-profile \
        --instance-profile-name "${IAM_INSTANCE_PROFILE_NAME}" \
        --role-name "${IAM_ROLE_NAME}" \
        || die "Failed to add role to instance profile"
    log "    Instance profile created: ${IAM_INSTANCE_PROFILE_NAME}"

    log "    ✓ IAM role and instance profile ready"
    log "    Attach the instance profile to your EC2 instance:"
    log "      aws ec2 associate-iam-instance-profile \\"
    log "        --instance-id ${EC2_INSTANCE_ID} \\"
    log "        --iam-instance-profile Name=${IAM_INSTANCE_PROFILE_NAME}"
}

# ---------------------------------------------------------------------------
# STEP 3: Create SNS Topic and Email Subscription
# ---------------------------------------------------------------------------

create_sns_topic() {
    log "==> Step 3: Creating SNS topic: ${SNS_TOPIC_NAME}"

    SNS_TOPIC_ARN="$(aws sns create-topic \
        --name "${SNS_TOPIC_NAME}" \
        --region "${AWS_REGION}" \
        --query 'TopicArn' \
        --output text)" \
        || die "Failed to create SNS topic ${SNS_TOPIC_NAME}"
    log "    Topic ARN: ${SNS_TOPIC_ARN}"

    # Subscribe the alert email address to the topic
    aws sns subscribe \
        --topic-arn "${SNS_TOPIC_ARN}" \
        --protocol "email" \
        --notification-endpoint "${ALERT_EMAIL}" \
        --region "${AWS_REGION}" \
        --output text > /dev/null \
        || die "Failed to subscribe ${ALERT_EMAIL} to SNS topic"
    log "    Email subscription created for: ${ALERT_EMAIL}"
    log "    ⚠  Check your inbox and confirm the subscription to receive alerts"

    log "    ✓ SNS topic ready: ${SNS_TOPIC_ARN}"
}

# ---------------------------------------------------------------------------
# STEP 4: Upload CloudWatch Agent Config to S3
# ---------------------------------------------------------------------------

upload_cw_agent_config() {
    log "==> Step 4: Uploading CloudWatch Agent config to S3"

    aws s3 cp "${CW_AGENT_CONFIG}" \
        "s3://${S3_BUCKET}/config/cloudwatch-agent/cloudwatch-agent-config.json" \
        --region "${AWS_REGION}" \
        || die "Failed to upload CloudWatch Agent config to S3"

    log "    ✓ Config uploaded to s3://${S3_BUCKET}/config/cloudwatch-agent/"
}

# ---------------------------------------------------------------------------
# STEP 5: Create CloudWatch Alarms
# ---------------------------------------------------------------------------

create_cloudwatch_alarms() {
    log "==> Step 5: Creating CloudWatch alarms"

    export AWS_REGION SNS_TOPIC_ARN EC2_INSTANCE_ID
    bash "${CW_ALARMS_SCRIPT}" \
        || die "Failed to create CloudWatch alarms"

    log "    ✓ CloudWatch alarms created"
}

# ---------------------------------------------------------------------------
# STEP 6: Create CloudWatch Dashboard
# ---------------------------------------------------------------------------

create_cloudwatch_dashboard() {
    log "==> Step 6: Creating CloudWatch dashboard: ${DASHBOARD_NAME}"

    # Substitute placeholder values in the dashboard JSON
    local dashboard_body
    dashboard_body="$(sed \
        -e "s/INSTANCE_ID/${EC2_INSTANCE_ID}/g" \
        -e "s/REGION/${AWS_REGION}/g" \
        -e "s/ACCOUNT_ID/${ACCOUNT_ID}/g" \
        "${CW_DASHBOARD}")"

    aws cloudwatch put-dashboard \
        --dashboard-name "${DASHBOARD_NAME}" \
        --dashboard-body "${dashboard_body}" \
        --region "${AWS_REGION}" \
        --output text > /dev/null \
        || die "Failed to create CloudWatch dashboard ${DASHBOARD_NAME}"

    log "    ✓ Dashboard created: ${DASHBOARD_NAME}"
    log "    View at: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#dashboards:name=${DASHBOARD_NAME}"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
    echo "============================================================"
    echo "  Automated Cloud Monitoring & Recovery — Deployment Script"
    echo "============================================================"
    echo ""

    check_aws_cli

    create_s3_bucket
    create_iam_role
    create_sns_topic
    upload_cw_agent_config
    create_cloudwatch_alarms
    create_cloudwatch_dashboard

    echo ""
    echo "============================================================"
    echo "  Deployment complete!"
    echo ""
    echo "  S3 Bucket:        ${S3_BUCKET}"
    echo "  IAM Role:         ${IAM_ROLE_NAME}"
    echo "  SNS Topic ARN:    ${SNS_TOPIC_ARN}"
    echo "  Dashboard:        ${DASHBOARD_NAME}"
    echo ""
    echo "  Next steps:"
    echo "  1. Confirm the SNS email subscription in your inbox"
    echo "  2. Attach the IAM instance profile to your EC2 instance"
    echo "  3. Install the recovery agent on EC2 (see README.md)"
    echo "  4. Install the CloudWatch Agent on EC2 (see README.md)"
    echo "============================================================"
}

main "$@"
