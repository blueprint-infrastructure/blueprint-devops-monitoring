# Validator Monitoring Agent

Pushes metrics from existing Prometheus to Amazon Managed Prometheus (AMP) via federation.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Validator Server (Docker)                                  │
│                                                             │
│  ┌─────────┐  ┌─────────┐  ┌───────────┐  ┌─────────────┐ │
│  │  besu   │  │  teku   │  │   teku    │  │node_exporter│ │
│  │ :9545   │  │ beacon  │  │ validator │  │   :9100     │ │
│  └────┬────┘  └────┬────┘  └─────┬─────┘  └──────┬──────┘ │
│       │            │             │               │         │
│       └────────────┴─────────────┴───────────────┘         │
│                           │                                 │
│                           ▼                                 │
│                   ┌───────────────┐                        │
│                   │  Prometheus   │ (existing)             │
│                   │    :9090      │                        │
│                   └───────┬───────┘                        │
│                           │ /federate                      │
│                           ▼                                 │
│                   ┌───────────────┐                        │
│                   │ Grafana Agent │ (installed by script)  │
│                   └───────┬───────┘                        │
│                           │ remote_write (SigV4)           │
└───────────────────────────┼────────────────────────────────┘
                            ▼
                     ┌──────────┐       ┌──────────┐
                     │   AMP    │ ────▶ │   AMG    │
                     └──────────┘       └──────────┘
```

## Prerequisites

- Existing Prometheus running on `:9090` (scraping validator metrics)
- EC2 instance with IAM role that has `AmazonPrometheusRemoteWriteAccess`

## Installation

```bash
# Set AMP configuration
export AMP_WORKSPACE_ID="ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export AMP_REGION="us-east-1"

# Optional: custom instance name (default: hostname)
export INSTANCE_NAME="eth-prod-or-1"

# Run install script
sudo -E ./install-existing-stack.sh ethereum
```

## What it does

1. Verifies Prometheus is running and has active targets
2. Installs Grafana Agent (via apt)
3. Configures federation from Prometheus → AMP
4. Starts systemd service

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `AMP_WORKSPACE_ID` | AMP Workspace ID | (required) |
| `AMP_REGION` | AWS region | `us-east-1` |
| `INSTANCE_NAME` | Instance label in metrics | `$(hostname)` |
| `PROMETHEUS_PORT` | Local Prometheus port | `9090` |

## Metrics Available

### System (node_exporter)
- `node_cpu_seconds_total`
- `node_memory_MemAvailable_bytes`
- `node_filesystem_avail_bytes`
- `node_disk_*`
- `node_network_*`

### Besu (execution client)
- `ethereum_blockchain_height` - current block
- `ethereum_best_known_block_number` - highest known block
- `besu_synchronizer_in_sync` - sync status
- `ethereum_peer_count` - connected peers

### Teku (consensus client)
- `beacon_head_slot` - current slot
- `beacon_finalized_epoch` - finalized epoch
- `beacon_peer_count` - connected peers
- `validator_*` - validator metrics

## Verify Installation

```bash
# Check Grafana Agent status
systemctl status grafana-agent

# View logs
journalctl -u grafana-agent -f

# Test federation
curl -s 'localhost:9090/federate?match[]={job=~".+"}' | head -20
```

## Troubleshooting

### Grafana Agent not starting
```bash
# Check logs
journalctl -u grafana-agent -e

# Verify config
cat /etc/grafana-agent.yaml

# Test AMP connectivity (requires awscurl)
awscurl --service aps --region us-east-1 \
  "https://aps-workspaces.us-east-1.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/api/v1/query?query=up"
```

### No data in AMG
1. Check Grafana Agent logs for remote_write errors
2. Verify IAM role has `AmazonPrometheusRemoteWriteAccess`
3. Ensure AMP workspace ID is correct

## Uninstall

```bash
sudo systemctl stop grafana-agent
sudo systemctl disable grafana-agent
sudo apt remove grafana-agent
sudo rm /etc/grafana-agent.yaml
```
