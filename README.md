# Monitoring and Alerting as Code

This repository contains Grafana dashboards, alert rules, notification configuration, and operational runbooks for production blockchain validator monitoring. Designed to be GitOps-friendly and deployed to Amazon Managed Grafana (AMG).

## Repository Layout

```
monitoring/
├── README.md                 # This file
├── .gitignore               # Git ignore patterns
├── alerting/                # Alert rule definitions
│   ├── node-health.yaml     # Node availability and scrape errors
│   ├── disk.yaml            # Disk space alerts
│   ├── cpu-memory.yaml      # CPU, memory, and network alerts
│   ├── docker.yaml          # Docker container health alerts
│   ├── chain/               # Chain-specific consensus alerts
│   │   ├── ethereum.yaml    # Ethereum (Besu + Teku) alerts
│   │   ├── solana.yaml      # Solana validator alerts
│   │   ├── avalanche.yaml   # Avalanche validator alerts
│   │   └── algorand.yaml    # Algorand node alerts
│   └── operational/         # Operational / business alerts
│       ├── algorand-participation.yaml  # Participation key expiry
│       ├── audius-eth-balance.yaml      # Audius claims ETH balance
│       └── solana-stake.yaml            # Solana stake change monitoring
├── notifications/           # Notification configuration
│   ├── contact-points.json  # Teams webhook + email contact points
│   └── notification-policies.json  # Severity-based routing rules
├── alertmanager/            # Alertmanager config template (reference)
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
│   ├── high-cpu.md
│   ├── docker-unhealthy.md
│   ├── solana-delinquent.md
│   ├── avalanche-stake-low.md
│   ├── algorand-participation.md
│   ├── audius-eth-balance.md
│   └── solana-stake-change.md
├── agents/                  # Node monitoring installation scripts
│   ├── install-ethereum-monitoring.sh
│   ├── install-solana-monitoring.sh
│   ├── install-avalanche-monitoring.sh
│   ├── install-algorand-monitoring.sh
│   └── install-audius-monitoring.sh
└── scripts/                 # Deployment scripts
    ├── validate.sh          # Local validation script
    ├── deploy.sh            # Master deployment script
    ├── deploy-dashboards-amg.sh    # Deploy dashboards to AMG
    ├── deploy-alerts-amg.sh        # Deploy alert rules to AMG
    ├── deploy-notifications-amg.sh # Deploy contact points and policies
    └── env.example          # Environment variable template
```

## Alert Rules

### Severity Levels

| Severity | Notification Channel | Description |
|----------|---------------------|-------------|
| `critical` | Teams + Email | Immediate action required — service outage or imminent failure |
| `high` | Teams only | Sustained resource saturation or degraded consensus participation |
| `warning` | Teams only | Attention needed — may escalate if not addressed |

### System-Level Alerts

| Alert | Threshold | Severity | File |
|-------|-----------|----------|------|
| NodeDown | Target unreachable for 2m | critical | node-health.yaml |
| TargetScrapeError | Up but no samples for 5m | warning | node-health.yaml |
| HighCPU | >85% for 10m | warning | cpu-memory.yaml |
| HighCPUCritical | >95% for 5m | high | cpu-memory.yaml |
| MemoryPressure | <15% available for 10m | warning | cpu-memory.yaml |
| MemoryPressureCritical | <5% available for 5m | high | cpu-memory.yaml |
| NetworkUtilizationHigh | >95% interface saturation for 5m | high | cpu-memory.yaml |
| DiskSpaceLow | <15% free for 10m | warning | disk.yaml |
| DiskSpaceCritical | <5% free for 5m | critical | disk.yaml |
| DockerContainerUnhealthy | Health != healthy for 5m | high | docker.yaml |
| DockerContainerRestarting | >3 restarts in 15m | high | docker.yaml |
| DockerContainerDown | Container stopped for 5m | critical | docker.yaml |

### Chain-Specific Alerts

**Ethereum** (alerting/chain/ethereum.yaml) — 17 rules covering Besu + Teku node health, sync status, peer connectivity, validator performance, and version drift.

**Solana** (alerting/chain/solana.yaml) — 9 rules covering node health, sync status (slots behind), peer connectivity, validator delinquency, and version drift.

**Avalanche** (alerting/chain/avalanche.yaml) — 10 rules covering node health, C-Chain bootstrapping/sync, peer connectivity, rewarding stake percentage, and version drift.

**Algorand** (alerting/chain/algorand.yaml) — 7 rules covering node health/readiness, sync status (rounds behind), peer connectivity, and version drift.

### Operational Alerts

| Alert | Condition | Severity | File |
|-------|-----------|----------|------|
| AlgorandParticipationKeyExpiring | ≤600,000 rounds remaining | warning | operational/algorand-participation.yaml |
| AlgorandParticipationKeyCritical | ≤300,000 rounds remaining | critical | operational/algorand-participation.yaml |
| AudiusClaimsBalanceLow | <0.1 ETH | warning | operational/audius-eth-balance.yaml |
| AudiusClaimsBalanceCritical | <0.04 ETH | critical | operational/audius-eth-balance.yaml |
| SolanaStakeSignificantChange | >10% change in 24h | high | operational/solana-stake.yaml |

## Notification Routing

Contact points and notification policies are defined in `notifications/` and deployed via `deploy-notifications-amg.sh`.

**Contact points:**
- `teams-webhook` — Microsoft Teams incoming webhook
- `ses-email` — AWS SES email for critical alerts

**Routing:**
```
root policy (default: teams-webhook)
├── severity=critical → teams-webhook + ses-email  (group_wait: 10s)
├── severity=high     → teams-webhook              (group_wait: 30s)
└── severity=warning  → teams-webhook              (group_wait: 60s)
```

## Deployment

### Prerequisites

- AWS CLI installed and configured
- Appropriate IAM permissions for AMG
- `yq` installed for alert rule conversion
- `jq` installed for JSON processing

### Quick Start

1. **Configure environment variables:**
   ```bash
   cp scripts/env.example .env
   # Edit .env with your workspace ID, Teams webhook URL, etc.
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

```bash
# Deploy everything (notifications + dashboards + alerts)
AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh

# Deploy only notifications (contact points + policies)
AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh --notifications-only

# Deploy only dashboards
AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh --dashboards-only

# Deploy only alert rules
AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh --alerts-only

# Skip validation
AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh --skip-validation
```

### Environment Variables

See `scripts/env.example` for all available configuration options:

| Variable | Required | Description |
|----------|----------|-------------|
| `AMG_WORKSPACE_ID` | Yes | Amazon Managed Grafana workspace ID |
| `AMG_REGION` | No | AWS region (default: us-east-1) |
| `DATASOURCE_UID` | No | Prometheus datasource UID (default: prometheus) |
| `OVERWRITE` | No | Overwrite existing dashboards (default: true) |
| `TEAMS_WEBHOOK_URL` | For notifications | Microsoft Teams incoming webhook URL |
| `ALERT_EMAIL_RECIPIENTS` | For notifications | Comma-separated email recipients |

### IAM Permissions

The deployment scripts require:
- `grafana:CreateWorkspaceApiKey`
- `grafana:DescribeWorkspace`
- Grafana API permissions for dashboard/alert/notification management

## Node Agent Deployment

The monitoring agent scripts in `agents/` are uploaded to S3 and then downloaded onto target nodes for execution.

**S3 location:** `s3://blueprint-infra-devops/agents/`

**Deploy to a node:**
```bash
# On the target node, download and run the install script
aws s3 cp s3://blueprint-infra-devops/agents/install-<chain>-monitoring.sh /tmp/ && \
  chmod +x /tmp/install-<chain>-monitoring.sh && \
  sudo /tmp/install-<chain>-monitoring.sh
```

**Upload updated scripts to S3:**
```bash
aws s3 cp agents/install-<chain>-monitoring.sh s3://blueprint-infra-devops/agents/
```

Each script installs three components: node_exporter (system metrics), a chain-specific collector (business metrics), and Grafana Agent (pushes to AMP via SigV4).

## Conventions

### Alert Annotations

All alerts include:
- `summary`: Brief description of the alert condition
- `description`: Detailed explanation with metric values
- `runbook_url`: Link to the corresponding runbook

### Alert Design Principles

- **Failure-mode-driven**: Alerts indicate actual problems requiring human intervention
- **Avoid alert fatigue**: Use appropriate thresholds and durations
- **Actionable**: Each alert maps to a clear remediation path in a runbook
- **Per-instance**: All alerts include the `instance` label for targeting
