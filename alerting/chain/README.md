# Chain-Specific Alert Rules

Prometheus alert rules for Ethereum validators using Besu + Teku.

## Files

| File | Description |
|------|-------------|
| `ethereum.yaml` | Besu execution + Teku consensus alerts |

## Alert Categories

### Node Health
- `BesuDown` - Execution client unreachable
- `TekuBeaconDown` - Beacon node unreachable
- `TekuValidatorDown` - Validator client unreachable

### Sync Status
- `BesuNotSynced` - Execution client out of sync
- `BesuBlocksBehind` - Execution client falling behind
- `TekuSyncing` - Beacon node syncing
- `TekuSlotsBehind` - Beacon node falling behind

### Network Connectivity
- `BesuLowPeers` / `BesuNoPeers` - Execution peer issues
- `TekuLowPeers` / `TekuNoPeers` - Consensus peer issues

### Validator Performance
- `ValidatorMissedAttestations` - Failed to publish attestations
- `ValidatorMissedBlocks` - Failed to publish blocks

### System Resources
- `HighCPU` - CPU above 85%
- `HighMemory` - Memory above 85%
- `DiskSpaceLow` / `DiskSpaceCritical` - Disk space alerts

## Metrics Source

These alerts use native metrics from:
- **Besu**: `ethereum_*`, `besu_*`
- **Teku**: `beacon_*`, `validator_*`
- **node_exporter**: `node_*`

## Deployment

```bash
# Deploy to AMG using existing scripts
./scripts/deploy.sh --alerts-only
```

## Customization

Adjust thresholds in alert expressions:

```yaml
# Example: change blocks behind threshold
expr: (ethereum_best_known_block_number - ethereum_blockchain_height) > 50
```

Adjust duration before firing:

```yaml
# Example: fire faster
for: 5m
```
