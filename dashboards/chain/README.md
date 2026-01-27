# Chain-Specific Dashboards

This directory will contain Grafana dashboards for blockchain validator monitoring.

## Planned Dashboards

| Dashboard | Chain | Description |
|-----------|-------|-------------|
| `ethereum-validator.json` | Ethereum | Execution + consensus client metrics, sync status, peer connectivity |
| `solana-validator.json` | Solana | Validator health, vote status, slot sync |
| `avalanche-validator.json` | Avalanche | Node health, P/X/C chain status, staking metrics |

## Metrics Source

These dashboards visualize metrics collected by the Blueprint Validator Agent:

```
agents/
├── collectors/
│   ├── ethereum.sh   → ethereum_* metrics
│   ├── solana.sh     → solana_* metrics
│   └── avalanche.sh  → avalanche_* metrics
```

## Key Panels (per chain)

### Overview Row
- Validator status (healthy/degraded/down)
- Sync percentage
- Peer count
- Node uptime

### Sync Status Row
- Current block/slot
- Blocks/slots behind
- Sync progress over time

### Network Row
- Peer count over time
- Peer connection stability

### Container Health (Docker deployments)
- Container status
- Restart count
- Health check history

## Installation

```bash
# Deploy all dashboards to Grafana
./scripts/deploy.sh --dashboards-only

# Or deploy specific chain dashboard
./scripts/deploy-dashboards-amg.sh dashboards/chain/ethereum-validator.json
```

## Creating Dashboards

When creating new dashboards:

1. Use the `chain` label for filtering: `{chain="ethereum"}`
2. Use the `instance` label for multi-node views
3. Include links to alert rules and runbooks
4. Add appropriate time range defaults (15m for real-time, 24h for trends)
