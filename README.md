# Automated Cloud Monitoring & Recovery Systems

A portfolio-grade AWS infrastructure project demonstrating automated EC2 health monitoring, self-healing recovery, real-time SNS alerting, centralized S3 log storage, and least-privilege IAM access control — all orchestrated with Bash and AWS CLI.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Tech Stack](#tech-stack)
- [Folder Structure](#folder-structure)
- [Prerequisites](#prerequisites)
- [Deployment Guide](#deployment-guide)
- [How It Works](#how-it-works)
- [Teardown](#teardown)
- [Security Notes](#security-notes)
- [License](#license)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS Account                              │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    EC2 Instance                          │   │
│  │                                                          │   │
│  │  ┌─────────────────────┐   ┌──────────────────────────┐ │   │
│  │  │  Recovery Agent     │   │  CloudWatch Agent        │ │   │
│  │  │  (recovery.sh)      │   │  (amazon-cloudwatch-     │ │   │
│  │  │                     │   │   agent)                 │ │   │
│  │  │  - Health checks    │   │  - CPU / Mem / Disk      │ │   │
│  │  │  - Auto-restart     │   │  - Network I/O           │ │   │
│  │  │  - Log upload → S3  │   │  - Ships to CWAgent NS   │ │   │
│  │  └────────┬────────────┘   └────────────┬─────────────┘ │   │
│  └───────────┼────────────────────────────┼───────────────┘   │
│              │                            │                     │
│              ▼                            ▼                     │
│  ┌───────────────────────┐   ┌────────────────────────────┐    │
│  │   S3 Log Store        │   │   CloudWatch               │    │
│  │                       │   │                            │    │
│  │  logs/recovery/...    │   │  Metrics → Alarms          │    │
│  │  config/cw-agent/...  │   │  Dashboard                 │    │
│  │  (versioned, SSE-S3)  │   │                            │    │
│  └───────────────────────┘   └────────────┬───────────────┘    │
│                                           │                     │
│                                           ▼                     │
│                              ┌────────────────────────────┐    │
│                              │   SNS Topic                │    │
│                              │   (Incident Alerts)        │    │
│                              │   → Email subscribers      │    │
│                              └────────────────────────────┘    │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  IAM Role (EC2 Instance Profile)                         │   │
│  │  - CloudWatch:PutMetricData                              │   │
│  │  - SNS:Publish (scoped to topic ARN)                     │   │
│  │  - S3:GetObject / PutObject (scoped to log bucket)       │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Service / Tool | Role |
|---|---|
| **AWS EC2** | Compute — hosts the recovery agent and CloudWatch agent |
| **Bash** | Scripting — recovery logic, health checks, deployment automation |
| **AWS CloudWatch** | Metrics collection, alarms, and observability dashboard |
| **AWS SNS** | Real-time incident and recovery notifications via email |
| **AWS IAM** | Least-privilege roles and instance profiles |
| **AWS S3** | Centralized log storage and configuration management |
| **AWS CLI** | Infrastructure provisioning and resource management |

---

## Folder Structure

```
aws-cloud-monitoring-recovery/
│
├── README.md                        # This file
│
├── scripts/
│   ├── recovery/
│   │   ├── recovery.sh              # Main auto-recovery agent (runs as systemd service)
│   │   └── recovery-config.conf     # Configurable list of services to monitor
│   │
│   ├── cloudwatch/
│   │   └── cloudwatch-agent-config.json  # CloudWatch Agent metric collection config
│   │
│   └── deploy/
│       ├── deploy.sh                # Provisions all AWS resources in dependency order
│       └── teardown.sh              # Removes all provisioned AWS resources
│
├── iam/
│   ├── ec2-monitoring-role-policy.json   # IAM policy document (CloudWatch + SNS + S3)
│   └── ec2-trust-policy.json             # IAM trust policy (EC2 service principal)
│
├── cloudwatch/
│   ├── alarms.sh                    # Creates all CloudWatch metric alarms via AWS CLI
│   └── dashboard.json               # CloudWatch dashboard definition (JSON)
│
├── s3/
│   └── bucket-policy.json           # S3 bucket policy enforcing least-privilege access
│
└── systemd/
    └── recovery-agent.service       # systemd unit file for the recovery agent
```

---

## Prerequisites

1. **AWS CLI v2** installed and configured (`aws configure`)
2. **An AWS account** with permissions to create EC2, IAM, S3, SNS, and CloudWatch resources
3. **An EC2 instance** (Amazon Linux 2 or Ubuntu 22.04 recommended) with the IAM instance profile attached
4. **jq** installed on the EC2 instance (`sudo yum install jq -y` or `sudo apt install jq -y`)

---

## Deployment Guide

### Step 1 — Clone the repository

```bash
git clone https://github.com/your-username/aws-cloud-monitoring-recovery.git
cd aws-cloud-monitoring-recovery
```

### Step 2 — Configure deployment variables

Open `scripts/deploy/deploy.sh` and set the variables at the top of the file:

```bash
AWS_REGION="us-east-1"           # Your target AWS region
ALERT_EMAIL="you@example.com"    # Email address for SNS incident alerts
EC2_INSTANCE_ID="i-0abc123..."   # Your EC2 instance ID (for alarms)
```

### Step 3 — Run the deployment script

```bash
chmod +x scripts/deploy/deploy.sh
./scripts/deploy/deploy.sh
```

The script will:
1. Create the S3 log bucket with versioning, encryption, and lifecycle rules
2. Create the IAM role and instance profile
3. Create the SNS topic and subscribe your email
4. Upload the CloudWatch Agent config to S3
5. Create CloudWatch alarms for CPU, memory, and disk
6. Create the CloudWatch dashboard

### Step 4 — Install the recovery agent on EC2

SSH into your EC2 instance and run:

```bash
# Copy scripts to the instance
scp -r scripts/recovery/ ec2-user@<your-ec2-ip>:/opt/recovery-agent/
scp systemd/recovery-agent.service ec2-user@<your-ec2-ip>:/etc/systemd/system/

# On the EC2 instance:
sudo chmod +x /opt/recovery-agent/recovery.sh
sudo systemctl daemon-reload
sudo systemctl enable recovery-agent
sudo systemctl start recovery-agent
sudo systemctl status recovery-agent
```

### Step 5 — Install the CloudWatch Agent on EC2

```bash
# Amazon Linux 2
sudo yum install amazon-cloudwatch-agent -y

# Download config from S3 (replace BUCKET_NAME with your bucket)
aws s3 cp s3://BUCKET_NAME/config/cloudwatch-agent/cloudwatch-agent-config.json \
    /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# Start the agent
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
    -s
```

### Step 6 — Confirm SNS subscription

Check your email inbox and confirm the SNS subscription to start receiving alerts.

---

## How It Works

### Auto-Recovery Flow

```
Every 60 seconds:
  For each service in recovery-config.conf:
    1. Run: systemctl is-active <service>
    2. If ACTIVE  → log "OK" and continue
    3. If FAILED  → attempt restart (up to 3 retries)
       - Success  → log recovery event, upload log to S3
       - Failure  → log failure, publish SNS alert
```

### Alerting Flow

```
CloudWatch Agent → ships metrics → CloudWatch namespace (CWAgent)
CloudWatch Alarm → threshold breach → transitions to ALARM state
CloudWatch Alarm → triggers SNS Publish → email notification delivered
CloudWatch Alarm → recovers → transitions to OK state → recovery email sent
```

---

## Teardown

To remove all provisioned AWS resources and avoid ongoing charges:

```bash
chmod +x scripts/deploy/teardown.sh
./scripts/deploy/teardown.sh
```

> **Warning:** This will permanently delete the S3 bucket and all its contents, the IAM role, SNS topic, CloudWatch alarms, and dashboard.

---

## Security Notes

- The IAM role follows **least-privilege**: EC2 instances can only write to the designated S3 prefix, publish to the specific SNS topic, and push metrics to CloudWatch.
- The S3 bucket has **public access blocked** at the bucket level.
- All S3 objects are encrypted at rest using **SSE-S3**.
- No long-lived IAM access keys are used — all EC2 access is via **instance profiles**.

---

## License

MIT License — free to use, modify, and distribute for personal and commercial projects.
