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
├── lambda/                  # AWS Lambda functions
│   ├── teams-notifier/      # Alert notifications (Bot Framework + Email)
│   │   └── handler.py
│   ├── rca-analyzer/        # Automated root cause analysis
│   │   └── handler.py
│   ├── bot-endpoint/        # Bot messaging endpoint (handles button clicks)
│   │   └── handler.py
│   ├── upgrade-analyzer/    # Version upgrade plan generator (Claude + Notion + SSM)
│   │   └── handler.py
│   └── docs-fetcher/        # Chain knowledge fetcher (GitHub + docs → S3 + Notion)
│       └── handler.py
├── tests/                   # Unit tests (run locally before deploy)
│   ├── test_teams_notifier.py
│   ├── test_bot_endpoint.py
│   └── test_upgrade_analyzer.py
└── scripts/                 # Deployment scripts
    ├── validate.sh          # Local validation script
    ├── deploy.sh            # Master deployment script
    ├── deploy-dashboards-amg.sh    # Deploy dashboards to AMG
    ├── deploy-alerts-amg.sh        # Deploy alert rules to AMG
    ├── deploy-notifications-amg.sh # Deploy contact points and policies
    ├── deploy-sns-lambda.sh        # Deploy SNS topics + teams-notifier Lambda
    ├── deploy-rca-lambda.sh        # Deploy RCA analyzer Lambda
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

## Automated Root Cause Analysis (RCA) and Upgrade Planning

On-demand root cause analysis and upgrade plan generation triggered via card buttons in Teams. Uses SSM + AMP metrics + Claude AI with chain-specific knowledge.

### How It Works

```
AMG Alert → SNS → teams-notifier Lambda → Bot Framework API → Teams Adaptive Card
                                                                (with "🔍 Analyze" per instance,
                                                                 "📋 {Chain} Upgrade Plan" per version group)
                                        → SES Email (critical only)

User clicks "🔍 Analyze" → bot-endpoint → rca-analyzer Lambda (async)
    ├→ Claude API: generate diagnostic commands (chain-aware)
    ├→ SSM: execute commands on the machine
    ├→ AMP: query historical metric trends
    ├→ Claude API: analyze root cause
    └→ Bot Framework: reply-in-thread with diagnosis card

User clicks "📋 {Chain} Upgrade Plan" → bot-endpoint → upgrade-analyzer Lambda (async)
    ├→ GitHub: fetch release notes for version range
    ├→ validator-context: fetch internal upgrade guide + scripts
    ├→ Claude API: generate structured JSON upgrade plan
    ├→ SSM: auto-run pre-upgrade steps on each affected instance
    ├→ Notion: create/update upgrade plan page (one page per chain+version)
    │    ├── Pre-Upgrade Steps + SSM execution results
    │    ├── Upgrade Steps (list only — human engineer must execute)
    │    └── Post-Upgrade Verification (pending)
    └→ Bot Framework: reply-in-thread with short card
         ├── "📄 View Upgrade Plan" → Notion link
         └── "✅ Run Post-Upgrade Verification" button

Engineer completes manual upgrade, clicks verify button → bot-endpoint → upgrade-analyzer (async)
    ├→ SSM: run post-upgrade verification on each instance
    ├→ Notion: append verification results to upgrade page
    └→ Bot Framework: reply-in-thread with verification summary
```

### RCA Output

Each RCA reply (in the alert message's thread) includes:
- **Root Cause** — specific process/service causing the issue, with chain-specific context
- **Severity Assessment** — urgency level with reasoning
- **Remediation Steps** — numbered steps with actual shell commands to fix the issue

### Upgrade Plan Output

Each upgrade plan is written to a Notion page (under the chain's parent page) with:
- **Pre-Upgrade Steps** — auto-executed via SSM, results captured in Notion
- **Upgrade Steps** — listed with shell commands; must be run manually by an engineer
- **Post-Upgrade Verification** — triggered via Teams button after manual steps complete
- **Rollback Steps** — recovery procedure if the upgrade fails

### Chain-Specific Knowledge

RCA prompts include per-chain architecture, diagnostic commands, failure modes, and thresholds for:
- **Solana** — Agave/Firedancer, slots behind, delinquency, vote account
- **Ethereum** — Besu (execution) + Teku (consensus), dual-layer sync, attestations
- **Avalanche** — AvalancheGo, P/X/C-Chain bootstrap, rewarding stake (80% threshold)
- **Algorand** — algod, participation key expiry, round sync
- **Audius** — Docker-based (my-node), watchtower auto-updates, CPU 100% is normal

Dynamic knowledge is fetched from GitHub releases + official docs via `docs-fetcher` Lambda, stored in S3 and [Notion](https://www.notion.so/32f09a37-0ee0-8154-9efd-cb49c3acd4dc).

#### Data Sources

**GitHub Releases** (latest 3 releases per repo):

| Chain | Repos |
|---|---|
| Solana | `anza-xyz/agave`, `firedancer-io/firedancer` |
| Ethereum | `hyperledger/besu`, `Consensys/teku` |
| Avalanche | `ava-labs/avalanchego` |
| Algorand | `algorand/go-algorand` |
| Audius | `AudiusProject/audius-protocol`, `OpenAudio/go-openaudio` |

**Official Documentation**:

| Chain | URLs |
|---|---|
| Solana | `docs.solanalabs.com/operations/best-practices/general`, `docs.solanalabs.com/operations/guides/validator-start` |
| Ethereum | `besu.hyperledger.org/stable/public-networks/how-to/troubleshoot/performance`, `docs.teku.consensys.io/how-to/troubleshoot/general` |
| Avalanche | `docs.avax.network/nodes/maintain/node-backup-and-restore`, `docs.avax.network/nodes/maintain/upgrade-your-avalanchego-node` |
| Algorand | `developer.algorand.org/docs/run-a-node/operations/switch_networks/` |
| Audius | — |

**Static Knowledge** (built into `rca-analyzer/handler.py`):

Each chain has a hardcoded `CHAIN_KNOWLEDGE` entry covering architecture (clients, ports, services), diagnostic commands, common failure modes, and key thresholds. This serves as a baseline when dynamic data is unavailable.

### Azure Bot Service

Alert cards and RCA replies are posted via Azure Bot Framework API, enabling:
- **Adaptive Cards** with Action.Submit buttons for on-demand RCA
- **Reply-in-thread** — RCA results appear in the alert message's thread
- **Bot endpoint** — Lambda Function URL behind API Gateway at `https://lambda-api-gateway.theblueprint.xyz/staking_alert_bot/`

### Deployment

```bash
# Deploy all Lambda functions (RCA + upgrade-analyzer + bot-endpoint + notifier updates)
./scripts/deploy-rca-lambda.sh

# Or via the master deploy script
./scripts/deploy.sh --rca-only
```

### Running Tests Locally

```bash
pip install pytest
python3 -m pytest tests/ -v
```

Tests cover button grouping logic, payload routing, Notion block structure, card builders, SSM delegation, and Notion search/create helpers — all without requiring AWS credentials.

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_SECRET_ARN` | Yes | Secrets Manager ARN for Anthropic API key (also contains `github_token`) |
| `AMP_WORKSPACE_ID` | Yes | Amazon Managed Prometheus workspace ID |
| `TEAMS_BOT_SECRET_ARN` | Yes | Secrets Manager ARN for Azure Bot credentials |
| `NOTION_SECRET_ARN` | Recommended | Secrets Manager ARN for Notion API token (upgrade plan pages) |
| `SSM_REGION` | Auto | AWS region for SSM commands (set by deploy script) |
| `RCA_LAMBDA_FUNCTION_NAME` | Auto | Set automatically by deploy script |

### Lambda Architecture

| Lambda | Memory | Timeout | Purpose |
|--------|--------|---------|---------|
| **teams-notifier** | 128MB | 60s | Posts alert cards via Bot Framework, sends email |
| **bot-endpoint** | 128MB | 30s | Handles Action.Submit button clicks from Teams |
| **rca-analyzer** | 256MB | 180s | SSM diagnostics + Claude analysis + thread reply |
| **upgrade-analyzer** | 256MB | 300s | GitHub releases + Claude plan + SSM pre-upgrade + Notion + Teams reply |
| **docs-fetcher** | 256MB | 300s | Fetches chain docs → S3 + Notion (weekly) |

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
