#!/bin/bash
#
# Solana Node Monitoring Installation Script
#
# Installs monitoring tools for an existing Solana validator node:
# 1. node_exporter - system metrics (CPU, memory, disk, network)
# 2. solana-collector - custom metrics (health, sync, validator status)
# 3. Grafana Agent - push all metrics to Amazon Managed Prometheus
#
# Prerequisites:
# - Solana validator running (solana-validator or agave-validator)
# - Solana CLI installed and configured
# - EC2 has IAM Role with AmazonPrometheusRemoteWriteAccess
#
# Metrics collected:
# - Node up/down (via Prometheus 'up' metric)
# - System resources (node_exporter on :9100)
# - Validator/node health status
# - Sync status (slots behind network)
# - Vote account and stake status
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Solana Node Monitoring Installation${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

# =============================================================================
# Configuration
# =============================================================================

# AMP config (required)
AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-}"
AMP_REGION="${AMP_REGION:-us-east-1}"

# Solana RPC config
SOLANA_RPC_URL="${SOLANA_RPC_URL:-http://localhost:8899}"

# Collector config
COLLECTOR_PORT="${COLLECTOR_PORT:-9102}"

# node_exporter config
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.7.0}"

# Optional config
INSTANCE_NAME="${INSTANCE_NAME:-$(hostname)}"
CHAIN="solana"

# Validate AMP config
if [[ -z "$AMP_WORKSPACE_ID" ]]; then
    log_error "AMP_WORKSPACE_ID not set"
    echo ""
    echo "Usage:"
    echo "  export AMP_WORKSPACE_ID='ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
    echo "  export AMP_REGION='us-east-1'"
    echo "  export INSTANCE_NAME='solana-validator-1'  # optional"
    echo "  export SOLANA_RPC_URL='http://localhost:8899'  # optional"
    echo "  sudo -E $0"
    exit 1
fi

echo "Configuration:"
echo "  AMP Workspace:     ${AMP_WORKSPACE_ID}"
echo "  AMP Region:        ${AMP_REGION}"
echo "  Instance:          ${INSTANCE_NAME}"
echo "  Chain:             ${CHAIN}"
echo "  Solana RPC:        ${SOLANA_RPC_URL}"
echo "  Collector Port:    ${COLLECTOR_PORT}"
echo "  node_exporter:     ${NODE_EXPORTER_PORT}"
echo ""

# =============================================================================
# Step 1: Verify Solana Node
# =============================================================================

log_info "[Step 1/4] Verifying Solana node..."

# Check if Solana CLI is available
if ! command -v solana >/dev/null 2>&1; then
    log_error "Solana CLI not found in PATH"
    log_info "Please ensure Solana is installed and in PATH"
    exit 1
fi

SOLANA_VERSION=$(solana --version 2>/dev/null || echo "unknown")
log_ok "Solana CLI found: ${SOLANA_VERSION}"

# Check if RPC is responding
if curl -sf -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' \
    "${SOLANA_RPC_URL}" >/dev/null 2>&1; then
    log_ok "Solana RPC is responding at ${SOLANA_RPC_URL}"
else
    log_warn "Solana RPC not responding at ${SOLANA_RPC_URL}"
    log_info "Metrics collection may fail until RPC is available"
fi

# Check validator identity
VALIDATOR_IDENTITY=""
if solana address 2>/dev/null; then
    VALIDATOR_IDENTITY=$(solana address 2>/dev/null || echo "")
    log_info "Validator identity: ${VALIDATOR_IDENTITY}"
fi

# =============================================================================
# Step 2: Install node_exporter
# =============================================================================

log_info "[Step 2/4] Installing node_exporter..."

if command -v node_exporter >/dev/null 2>&1 || systemctl is-active --quiet node_exporter 2>/dev/null; then
    log_info "node_exporter already installed"
else
    log_info "Downloading node_exporter v${NODE_EXPORTER_VERSION}..."

    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) log_error "Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    cd /tmp
    curl -sSLO "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    tar xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    mv "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/
    rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}"*

    # Create user
    useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true

    # Create systemd service
    cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:${NODE_EXPORTER_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable node_exporter
    systemctl start node_exporter

    log_ok "node_exporter installed and running on :${NODE_EXPORTER_PORT}"
fi

# Verify node_exporter
sleep 2
if curl -sf "http://localhost:${NODE_EXPORTER_PORT}/metrics" >/dev/null 2>&1; then
    log_ok "node_exporter responding on :${NODE_EXPORTER_PORT}"
else
    log_error "node_exporter not responding"
    exit 1
fi

# =============================================================================
# Step 3: Install Solana Collector (custom metrics)
# =============================================================================

log_info "[Step 3/4] Installing Solana metrics collector..."

# Create collector directory
mkdir -p /opt/solana-collector

# Create the collector script
cat > /opt/solana-collector/collector.sh <<'COLLECTOR_SCRIPT'
#!/bin/bash
#
# Solana Metrics Collector
# Collects health, sync status, and validator metrics from Solana RPC/CLI
# Exposes metrics in Prometheus format
#

set -euo pipefail

SOLANA_RPC="${SOLANA_RPC:-http://localhost:8899}"
LISTEN_PORT="${LISTEN_PORT:-9102}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-15}"

# Metrics file
METRICS_FILE="/tmp/solana_collector_metrics.prom"
METRICS_FILE_TMP="/tmp/solana_collector_metrics.prom.tmp"

# Helper to make RPC calls
rpc_call() {
    local method="$1"
    local params="${2:-[]}"
    curl -s --max-time 10 -X POST -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
        "${SOLANA_RPC}" 2>/dev/null || echo '{}'
}

collect_metrics() {
    local timestamp=$(date +%s)

    cat > "$METRICS_FILE_TMP" <<EOF
# HELP solana_collector_scrape_timestamp_seconds Unix timestamp of last scrape
# TYPE solana_collector_scrape_timestamp_seconds gauge
solana_collector_scrape_timestamp_seconds ${timestamp}

EOF

    # =========================================================================
    # Node Health
    # =========================================================================
    local health_response
    health_response=$(rpc_call "getHealth")

    local is_healthy=0
    if echo "$health_response" | grep -q '"result":"ok"'; then
        is_healthy=1
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_node_healthy Whether the node is healthy (1=healthy, 0=unhealthy)
# TYPE solana_node_healthy gauge
solana_node_healthy ${is_healthy}

EOF

    # =========================================================================
    # Slot Information & Sync Status
    # =========================================================================

    # Get current slot
    local slot_response
    slot_response=$(rpc_call "getSlot")
    local current_slot=0
    current_slot=$(echo "$slot_response" | grep -o '"result":[0-9]*' | cut -d':' -f2 || echo "0")

    # Get slot leader and check sync by comparing with cluster
    local epoch_info_response
    epoch_info_response=$(rpc_call "getEpochInfo")

    local absolute_slot=0
    local slot_index=0
    local slots_in_epoch=0
    local epoch=0

    if echo "$epoch_info_response" | grep -q '"absoluteSlot"'; then
        absolute_slot=$(echo "$epoch_info_response" | grep -o '"absoluteSlot":[0-9]*' | cut -d':' -f2 || echo "0")
        slot_index=$(echo "$epoch_info_response" | grep -o '"slotIndex":[0-9]*' | cut -d':' -f2 || echo "0")
        slots_in_epoch=$(echo "$epoch_info_response" | grep -o '"slotsInEpoch":[0-9]*' | cut -d':' -f2 || echo "0")
        epoch=$(echo "$epoch_info_response" | grep -o '"epoch":[0-9]*' | cut -d':' -f2 || echo "0")
    fi

    # Calculate slots behind using solana catchup if available
    local slots_behind=0
    local is_synced=1

    # Try to get slots behind from getBlockHeight comparison
    local block_height_response
    block_height_response=$(rpc_call "getBlockHeight")
    local block_height=0
    block_height=$(echo "$block_height_response" | grep -o '"result":[0-9]*' | cut -d':' -f2 || echo "0")

    # Get highest snapshot slot to estimate sync status
    # If we can't determine, assume synced if healthy
    if [[ "$is_healthy" -eq 0 ]]; then
        is_synced=0
    fi

    # Try using solana catchup for more accurate slots behind
    if command -v solana >/dev/null 2>&1; then
        local catchup_output
        catchup_output=$(timeout 10 solana catchup --our-localhost --url "${SOLANA_RPC}" 2>&1 || echo "")
        if echo "$catchup_output" | grep -q "slot(s) behind"; then
            slots_behind=$(echo "$catchup_output" | grep -o '[0-9]* slot(s) behind' | grep -o '^[0-9]*' || echo "0")
            if [[ "$slots_behind" -gt 0 ]]; then
                is_synced=0
            fi
        elif echo "$catchup_output" | grep -qi "caught up\|has caught up"; then
            slots_behind=0
            is_synced=1
        fi
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_node_slot Current slot number
# TYPE solana_node_slot gauge
solana_node_slot ${current_slot}

# HELP solana_node_absolute_slot Absolute slot number
# TYPE solana_node_absolute_slot gauge
solana_node_absolute_slot ${absolute_slot}

# HELP solana_node_block_height Current block height
# TYPE solana_node_block_height gauge
solana_node_block_height ${block_height}

# HELP solana_node_epoch Current epoch
# TYPE solana_node_epoch gauge
solana_node_epoch ${epoch}

# HELP solana_node_slot_index Slot index within current epoch
# TYPE solana_node_slot_index gauge
solana_node_slot_index ${slot_index}

# HELP solana_node_slots_in_epoch Total slots in current epoch
# TYPE solana_node_slots_in_epoch gauge
solana_node_slots_in_epoch ${slots_in_epoch}

# HELP solana_node_slots_behind Number of slots behind the cluster
# TYPE solana_node_slots_behind gauge
solana_node_slots_behind ${slots_behind}

# HELP solana_node_synced Whether node is synced with cluster (1=synced, 0=syncing)
# TYPE solana_node_synced gauge
solana_node_synced ${is_synced}

EOF

    # =========================================================================
    # Validator Identity & Vote Account
    # =========================================================================

    local identity=""
    if command -v solana >/dev/null 2>&1; then
        identity=$(solana address 2>/dev/null || echo "")
    fi

    # Get vote accounts to check if we're a validator
    local is_validator=0
    local is_delinquent=0
    local activated_stake=0
    local last_vote=0
    local root_slot=0
    local commission=0

    if [[ -n "$identity" ]]; then
        local vote_accounts_response
        vote_accounts_response=$(rpc_call "getVoteAccounts")

        # Check current validators
        if echo "$vote_accounts_response" | grep -q "\"nodePubkey\":\"${identity}\""; then
            is_validator=1

            # Check if in current or delinquent list
            if echo "$vote_accounts_response" | grep -A20 '"current"' | grep -q "\"nodePubkey\":\"${identity}\""; then
                is_delinquent=0
            elif echo "$vote_accounts_response" | grep -A20 '"delinquent"' | grep -q "\"nodePubkey\":\"${identity}\""; then
                is_delinquent=1
            fi

            # Extract stake (this is simplified - actual parsing would need jq)
            # For now, we'll use solana CLI if available
            if command -v solana >/dev/null 2>&1; then
                local stakes_output
                stakes_output=$(solana stakes --url "${SOLANA_RPC}" "${identity}" 2>/dev/null || echo "")
                if echo "$stakes_output" | grep -q "Active Stake"; then
                    activated_stake=$(echo "$stakes_output" | grep "Active Stake" | head -1 | grep -o '[0-9.]*' | head -1 || echo "0")
                    # Convert SOL to lamports (1 SOL = 1e9 lamports)
                    activated_stake=$(echo "$activated_stake * 1000000000" | bc 2>/dev/null || echo "0")
                fi
            fi
        fi
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_validator_active Whether this node is an active validator (1=yes, 0=no)
# TYPE solana_validator_active gauge
solana_validator_active ${is_validator}

# HELP solana_validator_delinquent Whether validator is delinquent (1=yes, 0=no)
# TYPE solana_validator_delinquent gauge
solana_validator_delinquent ${is_delinquent}

# HELP solana_validator_activated_stake_lamports Activated stake in lamports
# TYPE solana_validator_activated_stake_lamports gauge
solana_validator_activated_stake_lamports ${activated_stake}

EOF

    # =========================================================================
    # Network Peers
    # =========================================================================
    local peer_count=0

    # Method 1: Try solana gossip command (most reliable)
    if command -v solana >/dev/null 2>&1; then
        local gossip_output
        gossip_output=$(timeout 30 solana gossip --url "${SOLANA_RPC}" 2>/dev/null | wc -l || echo "0")
        if [[ "$gossip_output" -gt 1 ]]; then
            # Subtract header line
            peer_count=$((gossip_output - 1))
        fi
    fi

    # Method 2: Fallback to getClusterNodes RPC
    if [[ "$peer_count" -eq 0 ]]; then
        local cluster_nodes_response
        cluster_nodes_response=$(rpc_call "getClusterNodes")
        if echo "$cluster_nodes_response" | grep -q '"pubkey"'; then
            peer_count=$(echo "$cluster_nodes_response" | grep -o '"pubkey"' | wc -l || echo "0")
            # Subtract 1 for self
            peer_count=$((peer_count > 0 ? peer_count - 1 : 0))
        fi
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_network_peers Number of cluster nodes (peers)
# TYPE solana_network_peers gauge
solana_network_peers ${peer_count}

EOF

    # =========================================================================
    # Transaction Count
    # =========================================================================
    local tx_count_response
    tx_count_response=$(rpc_call "getTransactionCount")
    local tx_count=0
    tx_count=$(echo "$tx_count_response" | grep -o '"result":[0-9]*' | cut -d':' -f2 || echo "0")

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_transaction_count Total transaction count
# TYPE solana_transaction_count counter
solana_transaction_count ${tx_count}

EOF

    # =========================================================================
    # Version Info
    # =========================================================================
    local version_response
    version_response=$(rpc_call "getVersion")
    local solana_version="unknown"
    if echo "$version_response" | grep -q '"solana-core"'; then
        solana_version=$(echo "$version_response" | grep -o '"solana-core":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_node_version_info Solana node version
# TYPE solana_node_version_info gauge
solana_node_version_info{version="${solana_version}"} 1

EOF

    # =========================================================================
    # Collector metadata
    # =========================================================================
    local scrape_success=1

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_collector_scrape_success Whether the last scrape was successful (1=yes, 0=no)
# TYPE solana_collector_scrape_success gauge
solana_collector_scrape_success ${scrape_success}
EOF

    # Atomically replace the metrics file
    mv "$METRICS_FILE_TMP" "$METRICS_FILE"
}

serve_metrics() {
    while true; do
        {
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n"
            cat "$METRICS_FILE" 2>/dev/null || echo "# No metrics available yet"
        } | nc -l "$LISTEN_PORT" -q 1 2>/dev/null || nc -l -p "$LISTEN_PORT" -q 1 2>/dev/null || true
    done
}

# Main loop
main() {
    echo "Starting Solana metrics collector..."
    echo "  RPC endpoint: ${SOLANA_RPC}"
    echo "  Listen port:  ${LISTEN_PORT}"
    echo "  Interval:     ${SCRAPE_INTERVAL}s"

    # Initial metrics collection
    collect_metrics || true

    # Start HTTP server in background
    serve_metrics &
    local server_pid=$!

    # Collect metrics periodically
    while true; do
        sleep "$SCRAPE_INTERVAL"
        collect_metrics || true
    done
}

main "$@"
COLLECTOR_SCRIPT

chmod +x /opt/solana-collector/collector.sh

# Create systemd service for collector
cat > /etc/systemd/system/solana-collector.service <<EOF
[Unit]
Description=Solana Metrics Collector
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment="SOLANA_RPC=${SOLANA_RPC_URL}"
Environment="LISTEN_PORT=${COLLECTOR_PORT}"
Environment="SCRAPE_INTERVAL=15"
ExecStart=/opt/solana-collector/collector.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable solana-collector
systemctl restart solana-collector

sleep 3

if systemctl is-active --quiet solana-collector; then
    log_ok "Solana collector running on :${COLLECTOR_PORT}"
else
    log_warn "Solana collector may have issues, check: journalctl -u solana-collector -f"
fi

# =============================================================================
# Step 4: Install and Configure Grafana Agent
# =============================================================================

log_info "[Step 4/4] Installing Grafana Agent..."

# Check if already installed
if command -v grafana-agent >/dev/null 2>&1 || systemctl is-active --quiet grafana-agent 2>/dev/null; then
    log_info "Grafana Agent already installed, updating configuration..."
else
    # Install Grafana Agent
    log_info "Adding Grafana APT repository..."

    mkdir -p /etc/apt/keyrings/
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg 2>/dev/null || true

    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | \
        tee /etc/apt/sources.list.d/grafana.list >/dev/null

    apt-get update -qq
    apt-get install -y grafana-agent

    log_ok "Grafana Agent installed"
fi

# Generate configuration
log_info "Configuring Grafana Agent..."

cat > /etc/grafana-agent.yaml <<EOF
# Grafana Agent configuration - Solana Node Monitoring
# Generated: $(date -Iseconds)
# Pushes metrics to Amazon Managed Prometheus

metrics:
  global:
    scrape_interval: 15s
    external_labels:
      instance: '${INSTANCE_NAME}'
      chain: '${CHAIN}'
      env: 'production'

  configs:
    - name: solana_metrics
      scrape_configs:
        # Custom collector metrics (health, sync, validator)
        - job_name: 'solana_collector'
          static_configs:
            - targets: ['localhost:${COLLECTOR_PORT}']
          relabel_configs:
            - target_label: instance
              replacement: '${INSTANCE_NAME}'
            - target_label: chain
              replacement: '${CHAIN}'

        # System metrics from node_exporter
        - job_name: 'node_exporter'
          static_configs:
            - targets: ['localhost:${NODE_EXPORTER_PORT}']
          relabel_configs:
            - target_label: instance
              replacement: '${INSTANCE_NAME}'
            - target_label: chain
              replacement: '${CHAIN}'

      remote_write:
        - url: 'https://aps-workspaces.${AMP_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/api/v1/remote_write'
          sigv4:
            region: '${AMP_REGION}'

integrations:
  agent:
    enabled: true
EOF

# Set permissions
chmod 644 /etc/grafana-agent.yaml
chown root:grafana-agent /etc/grafana-agent.yaml 2>/dev/null || true

# Fix port conflict in /etc/default/grafana-agent
if [[ -f /etc/default/grafana-agent ]]; then
    sed -i 's/127.0.0.1:9090/127.0.0.1:12345/g' /etc/default/grafana-agent
    sed -i 's/127.0.0.1:9091/127.0.0.1:12346/g' /etc/default/grafana-agent
    log_info "Updated /etc/default/grafana-agent ports to avoid conflict"
fi

# Restart service
systemctl daemon-reload
systemctl enable grafana-agent
systemctl restart grafana-agent

sleep 2

if systemctl is-active --quiet grafana-agent; then
    log_ok "Grafana Agent is running"
else
    log_error "Grafana Agent failed to start"
    systemctl status grafana-agent --no-pager
    exit 1
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   Installation Complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Architecture:"
echo ""
echo "  ┌─────────────────────┐"
echo "  │   Solana Validator  │"
echo "  │   RPC :8899         │──┐"
echo "  └─────────────────────┘  │"
echo "                           │"
echo "  ┌─────────────────────┐  │     ┌─────────────────┐     ┌─────────┐"
echo "  │  solana-collector   │  ├────▶│  Grafana Agent  │────▶│   AMP   │"
echo "  │   :${COLLECTOR_PORT}              │──┘     └─────────────────┘     └─────────┘"
echo "  └─────────────────────┘  │"
echo "                           │"
echo "  ┌─────────────────────┐  │"
echo "  │   node_exporter     │──┘"
echo "  │   :${NODE_EXPORTER_PORT}              │"
echo "  └─────────────────────┘"
echo ""
echo "Metrics collected:"
echo ""
echo "  Node Status:"
echo "    - up{job=\"solana_collector\"}       # Node up/down"
echo "    - solana_node_healthy              # RPC health status"
echo "    - solana_node_synced               # Sync status"
echo ""
echo "  Sync Status:"
echo "    - solana_node_slot                 # Current slot"
echo "    - solana_node_block_height         # Block height"
echo "    - solana_node_slots_behind         # Slots behind cluster"
echo "    - solana_node_epoch                # Current epoch"
echo ""
echo "  Validator Status:"
echo "    - solana_validator_active          # Is active validator"
echo "    - solana_validator_delinquent      # Delinquency status"
echo "    - solana_validator_activated_stake_lamports  # Staked amount"
echo ""
echo "  Network:"
echo "    - solana_network_peers             # Connected peers"
echo "    - solana_transaction_count         # Total transactions"
echo ""
echo "  System Resources (node_exporter):"
echo "    - node_cpu_seconds_total"
echo "    - node_memory_MemAvailable_bytes"
echo "    - node_filesystem_avail_bytes"
echo "    - node_network_receive_bytes_total"
echo ""
echo "Verify installation:"
echo ""
echo "  # Check services"
echo "  systemctl status grafana-agent"
echo "  systemctl status solana-collector"
echo "  systemctl status node_exporter"
echo ""
echo "  # View logs"
echo "  journalctl -u grafana-agent -f"
echo "  journalctl -u solana-collector -f"
echo ""
echo "  # Test metrics endpoints"
echo "  curl -s localhost:${COLLECTOR_PORT}/metrics"
echo "  curl -s localhost:${NODE_EXPORTER_PORT}/metrics | head -20"
echo ""
echo "  # After 1-2 minutes, verify in AMP/AMG:"
echo "  #   up{job=\"solana_collector\"}"
echo "  #   solana_node_healthy"
echo "  #   solana_node_slots_behind"
echo "  #   node_cpu_seconds_total"
echo ""
