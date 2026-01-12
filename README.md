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
└── scripts/                 # Validation and utility scripts
    └── validate.sh          # Local validation script
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

## Getting Started

1. Review alert rules in `alerting/` directory
2. Customize Alertmanager routing in `alertmanager/alertmanager.yaml` with your receiver configurations
3. Import dashboards from `dashboards/` into your Grafana instance
4. Update runbooks in `runbooks/` with environment-specific procedures
