# Chain-Specific Alerts

This directory contains Prometheus alert rules specific to blockchain networks and chain operations.

## Supported Chains

Chain-specific alerts should be organized by chain name (e.g., `solana.yaml`, `ethereum.yaml`, `avalanche.yaml`).

## Conventions

- Follow the same conventions as parent alerting rules (severity labels, runbook_url annotations)
- Use chain-specific metrics when available (e.g., `chain_block_height`, `chain_validator_status`)
- Keep alerts failure-mode-driven and actionable
- Document chain-specific metric requirements in each file's header comments

## Example Structure

```
chain/
├── README.md
├── solana.yaml      # Solana validator alerts
├── ethereum.yaml    # Ethereum node alerts
└── avalanche.yaml   # Avalanche node alerts
```

## Getting Started

1. Identify chain-specific metrics exposed by your node exporters
2. Create a new YAML file for your chain
3. Define alert rules following the same format as parent rules
4. Add corresponding runbooks in `../../runbooks/chain/`
