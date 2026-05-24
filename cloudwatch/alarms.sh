#!/usr/bin/env bash
# =============================================================================
# alarms.sh — CloudWatch Alarm Provisioning Script
#
# Purpose:
#   Creates all CloudWatch metric alarms for the monitoring system.
#   Alarms cover CPU utilization, memory utilization, disk utilization,
#   and network anomalies. Each alarm publishes to the SNS topic when
#   it transitions to ALARM or back to OK state.
#
# Usage:
#   Called automatically by deploy.sh, or run standalone:
#   AWS_REGION=us-east-1 SNS_TOPIC_ARN=arn:aws:sns:... \
#     EC2_INSTANCE_ID=i-0abc123 bash alarms.sh
#
# Dependencies:
#   - AWS CLI v2
#   - Environment variables: AWS_REGION, SNS_TOPIC_ARN, EC2_INSTANCE_ID
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# VARIABLES — sourced from environment or set defaults
# ---------------------------------------------------------------------------

AWS_REGION="${AWS_REGION:-us-east-1}"
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:us-east-1:123456789012:MonitoringAlerts}"
EC2_INSTANCE_ID="${EC2_INSTANCE_ID:-i-0000000000000000}"

echo "==> Creating CloudWatch alarms for instance: ${EC2_INSTANCE_ID}"
echo "    Region:        ${AWS_REGION}"
echo "    SNS Topic ARN: ${SNS_TOPIC_ARN}"
echo ""

# ---------------------------------------------------------------------------
# ALARM 1: High CPU Utilization
# Triggers when CPU usage exceeds 90% for 2 consecutive 60-second periods.
# Uses the standard AWS/EC2 namespace (no CloudWatch Agent required).
# ---------------------------------------------------------------------------

echo "--> Creating alarm: HighCPUUtilization"
aws cloudwatch put-metric-alarm \
    --alarm-name "HighCPUUtilization-${EC2_INSTANCE_ID}" \
    --alarm-description "CPU utilization exceeded 90% for 2 consecutive minutes on ${EC2_INSTANCE_ID}" \
    --namespace "AWS/EC2" \
    --metric-name "CPUUtilization" \
    --dimensions "Name=InstanceId,Value=${EC2_INSTANCE_ID}" \
    --statistic "Average" \
    --period 60 \
    --evaluation-periods 2 \
    --threshold 90 \
    --comparison-operator "GreaterThanOrEqualToThreshold" \
    --alarm-actions "${SNS_TOPIC_ARN}" \
    --ok-actions "${SNS_TOPIC_ARN}" \
    --treat-missing-data "breaching" \
    --region "${AWS_REGION}"

echo "    ✓ HighCPUUtilization alarm created"

# ---------------------------------------------------------------------------
# ALARM 2: High Memory Utilization
# Triggers when memory usage exceeds 80% for 2 consecutive 60-second periods.
# Requires the CloudWatch Agent (CWAgent namespace) — not available natively.
# ---------------------------------------------------------------------------

echo "--> Creating alarm: HighMemoryUtilization"
aws cloudwatch put-metric-alarm \
    --alarm-name "HighMemoryUtilization-${EC2_INSTANCE_ID}" \
    --alarm-description "Memory utilization exceeded 80% for 2 consecutive minutes on ${EC2_INSTANCE_ID}" \
    --namespace "CWAgent" \
    --metric-name "mem_used_percent" \
    --dimensions "Name=InstanceId,Value=${EC2_INSTANCE_ID}" \
    --statistic "Average" \
    --period 60 \
    --evaluation-periods 2 \
    --threshold 80 \
    --comparison-operator "GreaterThanOrEqualToThreshold" \
    --alarm-actions "${SNS_TOPIC_ARN}" \
    --ok-actions "${SNS_TOPIC_ARN}" \
    --treat-missing-data "breaching" \
    --region "${AWS_REGION}"

echo "    ✓ HighMemoryUtilization alarm created"

# ---------------------------------------------------------------------------
# ALARM 3: High Disk Utilization (root volume)
# Triggers when disk usage on the root filesystem exceeds 85%.
# Requires the CloudWatch Agent (CWAgent namespace).
# ---------------------------------------------------------------------------

echo "--> Creating alarm: HighDiskUtilization"
aws cloudwatch put-metric-alarm \
    --alarm-name "HighDiskUtilization-${EC2_INSTANCE_ID}" \
    --alarm-description "Disk utilization exceeded 85% on ${EC2_INSTANCE_ID}" \
    --namespace "CWAgent" \
    --metric-name "disk_used_percent" \
    --dimensions \
        "Name=InstanceId,Value=${EC2_INSTANCE_ID}" \
        "Name=path,Value=/" \
        "Name=fstype,Value=xfs" \
    --statistic "Average" \
    --period 60 \
    --evaluation-periods 1 \
    --threshold 85 \
    --comparison-operator "GreaterThanOrEqualToThreshold" \
    --alarm-actions "${SNS_TOPIC_ARN}" \
    --ok-actions "${SNS_TOPIC_ARN}" \
    --treat-missing-data "breaching" \
    --region "${AWS_REGION}"

echo "    ✓ HighDiskUtilization alarm created"

# ---------------------------------------------------------------------------
# ALARM 4: EC2 Status Check Failed
# Triggers when the EC2 instance or underlying host fails a status check.
# Uses the standard AWS/EC2 namespace — no agent required.
# ---------------------------------------------------------------------------

echo "--> Creating alarm: EC2StatusCheckFailed"
aws cloudwatch put-metric-alarm \
    --alarm-name "EC2StatusCheckFailed-${EC2_INSTANCE_ID}" \
    --alarm-description "EC2 status check failed on ${EC2_INSTANCE_ID}" \
    --namespace "AWS/EC2" \
    --metric-name "StatusCheckFailed" \
    --dimensions "Name=InstanceId,Value=${EC2_INSTANCE_ID}" \
    --statistic "Maximum" \
    --period 60 \
    --evaluation-periods 2 \
    --threshold 1 \
    --comparison-operator "GreaterThanOrEqualToThreshold" \
    --alarm-actions "${SNS_TOPIC_ARN}" \
    --ok-actions "${SNS_TOPIC_ARN}" \
    --treat-missing-data "breaching" \
    --region "${AWS_REGION}"

echo "    ✓ EC2StatusCheckFailed alarm created"

# ---------------------------------------------------------------------------
# ALARM 5: CloudWatch Agent Heartbeat Missing
# Triggers when no metrics are received from the CWAgent for 5 minutes,
# indicating the CloudWatch Agent may have stopped.
# ---------------------------------------------------------------------------

echo "--> Creating alarm: CloudWatchAgentHeartbeatMissing"
aws cloudwatch put-metric-alarm \
    --alarm-name "CloudWatchAgentHeartbeatMissing-${EC2_INSTANCE_ID}" \
    --alarm-description "No CWAgent metrics received for 5 minutes from ${EC2_INSTANCE_ID} — agent may be down" \
    --namespace "CWAgent" \
    --metric-name "mem_used_percent" \
    --dimensions "Name=InstanceId,Value=${EC2_INSTANCE_ID}" \
    --statistic "SampleCount" \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 1 \
    --comparison-operator "LessThanThreshold" \
    --alarm-actions "${SNS_TOPIC_ARN}" \
    --ok-actions "${SNS_TOPIC_ARN}" \
    --treat-missing-data "breaching" \
    --region "${AWS_REGION}"

echo "    ✓ CloudWatchAgentHeartbeatMissing alarm created"

echo ""
echo "==> All CloudWatch alarms created successfully."
