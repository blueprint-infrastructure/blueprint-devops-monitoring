# Monitoring and Alerting as Code

This repository contains Grafana dashboards, alert rule templates, and operational runbooks for production infrastructure monitoring. Designed to be GitOps-friendly and compatible with Amazon Managed Grafana (AMG).

## Repository Layout

```
monitoring/
├── README.md                 # This file
├── .gitignore               # Git ignore patterns
├── alerting/                # Alert rule templates (for reference)
│   ├── node-health.yaml     # Node availability and scrape errors
│   ├── disk.yaml            # Disk space alerts
│   ├── cpu-memory.yaml      # CPU and memory alerts
│   └── chain/               # Chain-specific alerts
│       └── README.md
├── alertmanager/            # Alertmanager config template (for reference)
│   └── alertmanager.yaml    # Routing tree and receiver definitions
├── dashboards/              # Grafana dashboard JSON files
│   ├── infra/               # Infrastructure dashboards
│   │   ├── node-overview.json
│   │   ├── infrastructure-overview.json
│   │   └── alert-debug.json
│   └── chain/               # Chain-specific dashboards
│       └── README.md
├── runbooks/                # Operational runbooks
│   ├── README.md            # Runbook conventions
│   ├── node-down.md
│   ├── disk-full.md
│   └── high-cpu.md
└── scripts/                 # Deployment scripts
    ├── validate.sh          # Local validation script
    ├── deploy.sh            # Master deployment script
    ├── deploy-dashboards-amg.sh # Deploy dashboards to AMG
    ├── deploy-alerts-amg.sh # Deploy alert rules to AMG
    └── env.example          # Environment variable template
```

## Alert Management

Alerts are deployed to Grafana using the Grafana Provisioning API.

See: [Migrating to Grafana Alerting](https://docs.aws.amazon.com/grafana/latest/userguide/v10-alerting-use-grafana-alerts.html)

### Why Grafana Alerting?

- **Multi-dimensional alerting**: Create alerts with system-wide visibility
- **Unified management**: Manage alerts, contact points, and notification policies in one place
- **Built-in support**: Native integration with Prometheus, Loki, and other data sources
- **GitOps friendly**: Deploy alerts from code using the Grafana API

### Deploying Alerts

Alert rules in `alerting/` are automatically converted and deployed to Grafana:

```bash
# Deploy both dashboards and alerts
AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh

# Deploy alerts only
AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh --alerts-only
```

### Post-Deployment Setup

After deploying alerts, configure notifications in Grafana UI:

1. **Configure Contact Points**: Alerting → Contact points → Add contact point
2. **Set Notification Policies**: Alerting → Notification policies

## Conventions

### Severity Labels
- `severity: critical` - Immediate action required, potential service outage
- `severity: warning` - Attention needed, may escalate to critical if not addressed

### Alert Annotations
All alerts should include:
- `summary`: Brief description of the alert condition
- `description`: Detailed explanation with metric values
- `runbook_url`: Link to the corresponding runbook

### Alert Design Principles
- **Failure-mode-driven**: Alerts should indicate actual problems that require human intervention
- **Avoid alert fatigue**: Use appropriate thresholds and durations
- **Actionable**: Each alert should map to a clear remediation path in a runbook

## Local Validation

Validate dashboards locally before committing:

```bash
./scripts/validate.sh
```

This script validates:
- JSON syntax for Grafana dashboards
- YAML syntax for alert templates
- Alert rule format (if `promtool` is installed)

## Deployment

### Prerequisites

- AWS CLI installed and configured
- Appropriate IAM permissions for AMG

### Quick Start

1. **Configure environment variables:**
   ```bash
   cp scripts/env.example .env
   # Edit .env with your workspace ID
   ```

2. **Validate before deployment:**
   ```bash
   ./scripts/validate.sh
   ```

3. **Deploy dashboards:**
   ```bash
   ./scripts/deploy.sh
   ```

### Deployment Options

**Deploy dashboards to AMG:**
```bash
AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh
```

**Skip validation:**
```bash
AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh --skip-validation
```

### Environment Variables

See `scripts/env.example` for all available configuration options:

- `AMG_WORKSPACE_ID` - Amazon Managed Grafana workspace ID (required)
- `AMG_REGION` - AWS region for AMG (default: us-east-1)
- `OVERWRITE` - Overwrite existing dashboards (default: true)

### IAM Permissions

The deployment scripts require the following IAM permissions:

**For AMG:**
- `grafana:CreateWorkspaceApiKey` (if auto-creating API keys)
- `grafana:DescribeWorkspace`
- Grafana API permissions for dashboard creation/update

## Getting Started

1. Deploy dashboards using `./scripts/deploy.sh`
2. Open Grafana UI and configure alerts:
   - Create alert rules based on templates in `alerting/`
   - Set up contact points (SNS, Slack, PagerDuty, etc.)
   - Configure notification policies
3. Update runbooks in `runbooks/` with environment-specific procedures
