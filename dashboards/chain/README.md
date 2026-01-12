# Chain-Specific Dashboards

This directory contains Grafana dashboard JSON files specific to blockchain networks and chain operations.

## Supported Chains

Chain-specific dashboards should be organized by chain name (e.g., `solana-overview.json`, `ethereum-metrics.json`, `avalanche-health.json`).

## Conventions

- Use descriptive dashboard titles with chain name prefix
- Include chain-specific metrics (e.g., block height, validator status, transaction throughput)
- Follow Grafana dashboard JSON schema version 27+
- Use datasource variables for flexibility (`$datasource`)
- Tag dashboards appropriately for easy discovery

## Example Structure

```
chain/
├── README.md
├── solana-overview.json      # Solana validator overview
├── ethereum-metrics.json     # Ethereum node metrics
└── avalanche-health.json     # Avalanche node health
```

## Getting Started

1. Identify chain-specific metrics exposed by your node exporters
2. Create a new JSON dashboard file for your chain
3. Import into Grafana using the UI or API
4. Reference corresponding alert rules in `../../alerting/chain/`

## Dashboard Import

Dashboards can be imported into Grafana via:
- **UI**: Dashboard → Import → Paste JSON
- **API**: `POST /api/dashboards/db`
- **GitOps**: Using Grafana provisioning or Terraform
