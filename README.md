# Monitoring and Alerting as Code

This repository contains Prometheus-compatible alert rules, Grafana dashboards, Alertmanager routing configuration, and operational runbooks for production infrastructure monitoring. Designed to be GitOps-friendly and compatible with Amazon Managed Prometheus (AMP) and Amazon Managed Grafana (AMG).

## Repository Layout

```
monitoring/
├── README.md                 # This file
├── .gitignore               # Git ignore patterns
├── alerting/                # Prometheus alert rules
│   ├── node-health.yaml     # Node availability and scrape errors
│   ├── disk.yaml            # Disk space alerts
│   ├── cpu-memory.yaml      # CPU and memory alerts
│   └── chain/               # Chain-specific alerts (Solana, Ethereum, etc.)
│       └── README.md
├── alertmanager/            # Alertmanager routing configuration
│   └── alertmanager.yaml    # Routing tree and receiver definitions
├── dashboards/              # Grafana dashboard JSON files
│   ├── infra/               # Infrastructure dashboards
│   │   ├── node-overview.json
│   │   └── alert-debug.json
│   └── chain/               # Chain-specific dashboards
│       └── README.md
├── runbooks/                # Operational runbooks
│   ├── README.md            # Runbook conventions
│   ├── node-down.md
│   ├── disk-full.md
│   └── high-cpu.md
└── scripts/                 # Validation and deployment scripts
    ├── validate.sh          # Local validation script
    ├── deploy.sh            # Master deployment script
    ├── deploy-alerts-amp.sh # Deploy alerts to Amazon Managed Prometheus
    ├── deploy-dashboards-amg.sh # Deploy dashboards to Amazon Managed Grafana
    └── env.example          # Environment variable template
```

## Conventions

### Severity Labels
- `severity: critical` - Immediate action required, potential service outage
- `severity: warning` - Attention needed, may escalate to critical if not addressed

### Alert Annotations
All alerts must include:
- `summary`: Brief description of the alert condition
- `description`: Detailed explanation with metric values
- `runbook_url`: Link to the corresponding runbook (relative or placeholder URL)

### Alert Design Principles
- **Failure-mode-driven**: Alerts should indicate actual problems that require human intervention
- **Avoid alert fatigue**: Use appropriate thresholds and durations
- **Actionable**: Each alert should map to a clear remediation path in a runbook

## Local Validation

Validate alert rules and dashboards locally before committing:

```bash
./scripts/validate.sh
```

This script uses:
- `promtool check rules` to validate Prometheus alert rule syntax
- JSON validation for Grafana dashboards (using `jq` or `python -m json.tool`)

Ensure `promtool` is installed (part of Prometheus distribution) before running validation.

## Compatibility

- **Prometheus**: Compatible with Prometheus 2.x alert rule format
- **Amazon Managed Prometheus (AMP)**: All rules use standard PromQL compatible with AMP
- **Amazon Managed Grafana (AMG)**: Dashboards use standard Grafana JSON format
- **Alertmanager**: Compatible with Alertmanager 0.24+ routing configuration

## Deployment

### Prerequisites

- AWS CLI installed and configured
- Appropriate IAM permissions for AMP and AMG
- `promtool` (optional, for validation)

### Quick Start

1. **Configure environment variables:**
   ```bash
   cp scripts/env.example .env
   # Edit .env with your workspace IDs and configuration
   ```

2. **Validate before deployment:**
   ```bash
   ./scripts/validate.sh
   ```

3. **Deploy everything:**
   ```bash
   ./scripts/deploy.sh
   ```

### Deployment Options

**Deploy alerts only to AMP:**
```bash
AMP_WORKSPACE_ID=ws-xxx ./scripts/deploy-alerts-amp.sh
```

**Deploy dashboards only to AMG:**
```bash
AMG_WORKSPACE_ID=g-xxx ./scripts/deploy-dashboards-amg.sh
```

**Deploy with custom options:**
```bash
AMP_WORKSPACE_ID=ws-xxx \
AMG_WORKSPACE_ID=g-xxx \
AMP_REGION=us-west-2 \
./scripts/deploy.sh --alerts-only
```

### Environment Variables

See `scripts/env.example` for all available configuration options:

- `AMP_WORKSPACE_ID` - Amazon Managed Prometheus workspace ID (required)
- `AMP_REGION` - AWS region for AMP (default: us-east-1)
- `AMP_RULE_NAMESPACE` - Rule namespace in AMP (default: default)
- `AMG_WORKSPACE_ID` - Amazon Managed Grafana workspace ID (required)
- `AMG_REGION` - AWS region for AMG (default: us-east-1)
- `AMG_API_KEY` - Grafana API key (optional, script can create one)
- `AMG_ENDPOINT` - Grafana endpoint (optional, auto-detected)
- `OVERWRITE` - Overwrite existing dashboards (default: true)

### IAM Permissions

The deployment scripts require the following IAM permissions:

**For AMP:**
- `aps:PutRuleGroupsNamespace`
- `aps:DescribeWorkspace`

**For AMG:**
- `grafana:CreateWorkspaceApiKey` (if auto-creating API keys)
- `grafana:DescribeWorkspace`
- Grafana API permissions for dashboard creation/update

## Getting Started

1. Review alert rules in `alerting/` directory
2. Customize Alertmanager routing in `alertmanager/alertmanager.yaml` with your receiver configurations
3. Deploy alerts and dashboards using the deployment scripts
4. Update runbooks in `runbooks/` with environment-specific procedures
