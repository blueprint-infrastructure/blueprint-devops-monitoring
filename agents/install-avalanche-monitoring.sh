#!/bin/bash
#
# Avalanche Node Monitoring Installation Script
#
# Installs monitoring tools for an existing Avalanche node (AvalancheGo):
# 1. node_exporter - system metrics (CPU, memory, disk, network)
# 2. avalanche-collector - custom metrics (health, sync, validator status)
# 3. Grafana Agent - push all metrics to Amazon Managed Prometheus
#
# Prerequisites:
# - AvalancheGo node running on localhost:9650
# - EC2 has IAM Role with AmazonPrometheusRemoteWriteAccess
#
# Metrics collected:
# - Node up/down (via Prometheus 'up' metric)
# - System resources (node_exporter on :9100)
# - Validator/node health status (health API)
# - Blockchain sync status (blocks behind network)
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
echo -e "${BLUE}   Avalanche Node Monitoring Installation${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

# =============================================================================
# Configuration
# =============================================================================

# AMP config (required)
AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-}"
AMP_REGION="${AMP_REGION:-us-east-1}"

# Avalanche node config
AVALANCHE_RPC_PORT="${AVALANCHE_RPC_PORT:-9650}"
AVALANCHE_METRICS_PORT="${AVALANCHE_METRICS_PORT:-9650}"

# Collector config
COLLECTOR_PORT="${COLLECTOR_PORT:-9101}"

# node_exporter config
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.7.0}"

# Optional config
INSTANCE_NAME="${INSTANCE_NAME:-$(hostname)}"
CHAIN="avalanche"

# Validate AMP config
if [[ -z "$AMP_WORKSPACE_ID" ]]; then
    log_error "AMP_WORKSPACE_ID not set"
    echo ""
    echo "Usage:"
    echo "  export AMP_WORKSPACE_ID='ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
    echo "  export AMP_REGION='us-east-1'"
    echo "  export INSTANCE_NAME='avalanche-validator-1'  # optional"
    echo "  sudo -E $0"
    exit 1
fi

echo "Configuration:"
echo "  AMP Workspace:     ${AMP_WORKSPACE_ID}"
echo "  AMP Region:        ${AMP_REGION}"
echo "  Instance:          ${INSTANCE_NAME}"
echo "  Chain:             ${CHAIN}"
echo "  Avalanche RPC:     localhost:${AVALANCHE_RPC_PORT}"
echo "  Collector Port:    ${COLLECTOR_PORT}"
echo "  node_exporter:     ${NODE_EXPORTER_PORT}"
echo ""

# =============================================================================
# Step 1: Verify Avalanche Node
# =============================================================================

log_info "[Step 1/4] Verifying Avalanche node..."

# Check if AvalancheGo is responding
if curl -sf "http://localhost:${AVALANCHE_RPC_PORT}/ext/health" >/dev/null 2>&1; then
    log_ok "Avalanche node is responding on :${AVALANCHE_RPC_PORT}"

    # Check health status
    HEALTH_RESPONSE=$(curl -s "http://localhost:${AVALANCHE_RPC_PORT}/ext/health" 2>/dev/null || echo '{}')
    IS_HEALTHY=$(echo "$HEALTH_RESPONSE" | grep -o '"healthy":[^,}]*' | head -1 | cut -d':' -f2 | tr -d ' ' || echo "unknown")
    log_info "Node healthy: ${IS_HEALTHY}"

    # Check bootstrap status for each chain
    for chain in P X C; do
        BOOTSTRAP_RESPONSE=$(curl -s -X POST --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"${chain}\"}}" \
            -H 'content-type:application/json;' "http://localhost:${AVALANCHE_RPC_PORT}/ext/info" 2>/dev/null || echo '{}')
        IS_BOOTSTRAPPED=$(echo "$BOOTSTRAP_RESPONSE" | grep -o '"isBootstrapped":[^,}]*' | cut -d':' -f2 | tr -d ' ' || echo "unknown")
        log_info "${chain}-Chain bootstrapped: ${IS_BOOTSTRAPPED}"
    done
else
    log_error "Cannot connect to Avalanche node (localhost:${AVALANCHE_RPC_PORT})"
    log_info "Make sure AvalancheGo is running and accessible"
    exit 1
fi

# Check metrics endpoint
if curl -sf "http://localhost:${AVALANCHE_METRICS_PORT}/ext/metrics" >/dev/null 2>&1; then
    log_ok "Avalanche metrics endpoint available at /ext/metrics"
else
    log_warn "Avalanche metrics endpoint not responding - may need to enable metrics"
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
# Step 3: Install Avalanche Collector (custom metrics)
# =============================================================================

log_info "[Step 3/4] Installing Avalanche metrics collector..."

# Create collector directory
mkdir -p /opt/avalanche-collector

# Create the collector script
cat > /opt/avalanche-collector/collector.sh <<'COLLECTOR_SCRIPT'
#!/bin/bash
#
# Avalanche Metrics Collector
# Collects health, sync status, and validator metrics from AvalancheGo APIs
# Exposes metrics in Prometheus format
#

set -euo pipefail

AVALANCHE_RPC="${AVALANCHE_RPC:-http://localhost:9650}"
LISTEN_PORT="${LISTEN_PORT:-9101}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-15}"

# Metrics file
METRICS_FILE="/tmp/avalanche_collector_metrics.prom"
METRICS_FILE_TMP="/tmp/avalanche_collector_metrics.prom.tmp"

collect_metrics() {
    local timestamp=$(date +%s)

    cat > "$METRICS_FILE_TMP" <<EOF
# HELP avalanche_collector_scrape_timestamp_seconds Unix timestamp of last scrape
# TYPE avalanche_collector_scrape_timestamp_seconds gauge
avalanche_collector_scrape_timestamp_seconds ${timestamp}

EOF

    # =========================================================================
    # Health Status
    # =========================================================================
    local health_response
    health_response=$(curl -s --max-time 5 "${AVALANCHE_RPC}/ext/health" 2>/dev/null || echo '{"healthy":false}')

    local is_healthy=0
    if echo "$health_response" | grep -q '"healthy":true'; then
        is_healthy=1
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP avalanche_node_healthy Whether the node is healthy (1=healthy, 0=unhealthy)
# TYPE avalanche_node_healthy gauge
avalanche_node_healthy ${is_healthy}

EOF

    # =========================================================================
    # Bootstrap Status per Chain
    # =========================================================================
    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP avalanche_chain_bootstrapped Whether a chain is bootstrapped (1=yes, 0=no)
# TYPE avalanche_chain_bootstrapped gauge
EOF

    for chain in P X C; do
        local bootstrap_response
        bootstrap_response=$(curl -s --max-time 5 -X POST \
            --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"${chain}\"}}" \
            -H 'content-type:application/json;' "${AVALANCHE_RPC}/ext/info" 2>/dev/null || echo '{}')

        local is_bootstrapped=0
        if echo "$bootstrap_response" | grep -q '"isBootstrapped":true'; then
            is_bootstrapped=1
        fi

        echo "avalanche_chain_bootstrapped{chain=\"${chain}\"} ${is_bootstrapped}" >> "$METRICS_FILE_TMP"
    done

    echo "" >> "$METRICS_FILE_TMP"

    # =========================================================================
    # Sync Status - C-Chain (blocks behind)
    # =========================================================================

    # Get local C-Chain block height
    local local_height_response
    local_height_response=$(curl -s --max-time 5 -X POST \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        -H 'content-type:application/json;' "${AVALANCHE_RPC}/ext/bc/C/rpc" 2>/dev/null || echo '{}')

    local local_height_hex
    local_height_hex=$(echo "$local_height_response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4 || echo "0x0")
    local local_height=$((${local_height_hex}))

    # Get network height from info API (peers' reported height)
    local network_height_response
    network_height_response=$(curl -s --max-time 5 -X POST \
        --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
        -H 'content-type:application/json;' "${AVALANCHE_RPC}/ext/bc/C/rpc" 2>/dev/null || echo '{}')

    local is_syncing=0
    local blocks_behind=0
    local highest_block=$local_height

    # Check if syncing (false means fully synced)
    if echo "$network_height_response" | grep -q '"result":false'; then
        is_syncing=0
        blocks_behind=0
    elif echo "$network_height_response" | grep -q '"highestBlock"'; then
        is_syncing=1
        local highest_hex
        highest_hex=$(echo "$network_height_response" | grep -o '"highestBlock":"[^"]*"' | cut -d'"' -f4 || echo "0x0")
        highest_block=$((${highest_hex}))
        blocks_behind=$((highest_block - local_height))
        if [[ $blocks_behind -lt 0 ]]; then
            blocks_behind=0
        fi
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP avalanche_c_chain_block_height Current C-Chain block height
# TYPE avalanche_c_chain_block_height gauge
avalanche_c_chain_block_height ${local_height}

# HELP avalanche_c_chain_highest_block Highest known C-Chain block from peers
# TYPE avalanche_c_chain_highest_block gauge
avalanche_c_chain_highest_block ${highest_block}

# HELP avalanche_c_chain_blocks_behind Number of blocks behind the network
# TYPE avalanche_c_chain_blocks_behind gauge
avalanche_c_chain_blocks_behind ${blocks_behind}

# HELP avalanche_c_chain_syncing Whether C-Chain is currently syncing (1=syncing, 0=synced)
# TYPE avalanche_c_chain_syncing gauge
avalanche_c_chain_syncing ${is_syncing}

EOF

    # =========================================================================
    # Network Peers
    # =========================================================================
    local peers_response
    peers_response=$(curl -s --max-time 5 -X POST \
        --data '{"jsonrpc":"2.0","method":"info.peers","params":[],"id":1}' \
        -H 'content-type:application/json;' "${AVALANCHE_RPC}/ext/info" 2>/dev/null || echo '{}')

    local peer_count=0
    if echo "$peers_response" | grep -q '"peers"'; then
        # Count peers in the array
        peer_count=$(echo "$peers_response" | grep -o '"nodeID"' | wc -l || echo "0")
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP avalanche_network_peers Number of connected peers
# TYPE avalanche_network_peers gauge
avalanche_network_peers ${peer_count}

EOF

    # =========================================================================
    # Validator Status
    # =========================================================================

    # Get node ID
    local nodeid_response
    nodeid_response=$(curl -s --max-time 5 -X POST \
        --data '{"jsonrpc":"2.0","method":"info.getNodeID","params":[],"id":1}' \
        -H 'content-type:application/json;' "${AVALANCHE_RPC}/ext/info" 2>/dev/null || echo '{}')

    local node_id
    node_id=$(echo "$nodeid_response" | grep -o '"nodeID":"[^"]*"' | cut -d'"' -f4 || echo "")

    local is_validator=0
    local validator_stake=0
    local validator_start=0
    local validator_end=0

    if [[ -n "$node_id" ]]; then
        # Check if this node is a validator on primary network
        local validators_response
        validators_response=$(curl -s --max-time 10 -X POST \
            --data "{\"jsonrpc\":\"2.0\",\"method\":\"platform.getCurrentValidators\",\"params\":{\"nodeIDs\":[\"${node_id}\"]},\"id\":1}" \
            -H 'content-type:application/json;' "${AVALANCHE_RPC}/ext/bc/P" 2>/dev/null || echo '{}')

        if echo "$validators_response" | grep -q "\"nodeID\":\"${node_id}\""; then
            is_validator=1

            # Extract stake amount (in nAVAX)
            validator_stake=$(echo "$validators_response" | grep -o '"stakeAmount":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "0")

            # Extract start and end times
            validator_start=$(echo "$validators_response" | grep -o '"startTime":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "0")
            validator_end=$(echo "$validators_response" | grep -o '"endTime":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "0")
        fi
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP avalanche_validator_active Whether this node is an active validator (1=yes, 0=no)
# TYPE avalanche_validator_active gauge
avalanche_validator_active ${is_validator}

# HELP avalanche_validator_stake_navax Validator stake amount in nAVAX
# TYPE avalanche_validator_stake_navax gauge
avalanche_validator_stake_navax ${validator_stake}

# HELP avalanche_validator_start_timestamp Validator start time (unix timestamp)
# TYPE avalanche_validator_start_timestamp gauge
avalanche_validator_start_timestamp ${validator_start}

# HELP avalanche_validator_end_timestamp Validator end time (unix timestamp)
# TYPE avalanche_validator_end_timestamp gauge
avalanche_validator_end_timestamp ${validator_end}

EOF

    # =========================================================================
    # Uptime (from health API)
    # =========================================================================
    local uptime_response
    uptime_response=$(curl -s --max-time 5 -X POST \
        --data '{"jsonrpc":"2.0","method":"info.uptime","params":[],"id":1}' \
        -H 'content-type:application/json;' "${AVALANCHE_RPC}/ext/info" 2>/dev/null || echo '{}')

    local rewarding_stake_pct=0
    local weighted_avg_pct=0

    if echo "$uptime_response" | grep -q '"rewardingStakePercentage"'; then
        rewarding_stake_pct=$(echo "$uptime_response" | grep -o '"rewardingStakePercentage":"[^"]*"' | cut -d'"' -f4 || echo "0")
        weighted_avg_pct=$(echo "$uptime_response" | grep -o '"weightedAveragePercentage":"[^"]*"' | cut -d'"' -f4 || echo "0")
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP avalanche_uptime_rewarding_stake_percent Percentage of stake that has rewarding uptime
# TYPE avalanche_uptime_rewarding_stake_percent gauge
avalanche_uptime_rewarding_stake_percent ${rewarding_stake_pct}

# HELP avalanche_uptime_weighted_avg_percent Weighted average uptime percentage
# TYPE avalanche_uptime_weighted_avg_percent gauge
avalanche_uptime_weighted_avg_percent ${weighted_avg_pct}

EOF

    # =========================================================================
    # Version Info
    # =========================================================================
    local version_response
    version_response=$(curl -s --max-time 5 -X POST \
        --data '{"jsonrpc":"2.0","method":"info.getNodeVersion","params":[],"id":1}' \
        -H 'content-type:application/json;' "${AVALANCHE_RPC}/ext/info" 2>/dev/null || echo '{}')

    local node_version="unknown"
    if echo "$version_response" | grep -q '"version"'; then
        # Extract version like "avalanchego/1.14.1" and remove prefix
        node_version=$(echo "$version_response" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 | sed 's|.*/||' || echo "unknown")
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP avalanche_node_version_info Avalanche node version
# TYPE avalanche_node_version_info gauge
avalanche_node_version_info{version="${node_version}"} 1

EOF

    # =========================================================================
    # Collector metadata
    # =========================================================================
    local scrape_success=1

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP avalanche_collector_scrape_success Whether the last scrape was successful (1=yes, 0=no)
# TYPE avalanche_collector_scrape_success gauge
avalanche_collector_scrape_success ${scrape_success}
EOF

    # Atomically replace the metrics file
    mv "$METRICS_FILE_TMP" "$METRICS_FILE"
}

serve_metrics() {
    while true; do
        {
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n"
            cat "$METRICS_FILE" 2>/dev/null || echo "# No metrics available yet"
        } | nc -l -p "$LISTEN_PORT" -q 1 2>/dev/null || true
    done
}

# Main loop
main() {
    echo "Starting Avalanche metrics collector..."
    echo "  RPC endpoint: ${AVALANCHE_RPC}"
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

chmod +x /opt/avalanche-collector/collector.sh

# Create systemd service for collector
cat > /etc/systemd/system/avalanche-collector.service <<EOF
[Unit]
Description=Avalanche Metrics Collector
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment="AVALANCHE_RPC=http://localhost:${AVALANCHE_RPC_PORT}"
Environment="LISTEN_PORT=${COLLECTOR_PORT}"
Environment="SCRAPE_INTERVAL=15"
ExecStart=/opt/avalanche-collector/collector.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable avalanche-collector
systemctl restart avalanche-collector

sleep 3

if systemctl is-active --quiet avalanche-collector; then
    log_ok "Avalanche collector running on :${COLLECTOR_PORT}"
else
    log_warn "Avalanche collector may have issues, check: journalctl -u avalanche-collector -f"
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
# Grafana Agent configuration - Avalanche Node Monitoring
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
    - name: avalanche_metrics
      scrape_configs:
        # Avalanche node native metrics
        - job_name: 'avalanchego'
          metrics_path: '/ext/metrics'
          static_configs:
            - targets: ['localhost:${AVALANCHE_METRICS_PORT}']
          relabel_configs:
            - target_label: instance
              replacement: '${INSTANCE_NAME}'
            - target_label: chain
              replacement: '${CHAIN}'

        # Custom collector metrics (health, sync, validator)
        - job_name: 'avalanche_collector'
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
echo "  │   AvalancheGo       │"
echo "  │   :${AVALANCHE_RPC_PORT}/ext/metrics  │──┐"
echo "  └─────────────────────┘  │"
echo "                           │"
echo "  ┌─────────────────────┐  │     ┌─────────────────┐     ┌─────────┐"
echo "  │ avalanche-collector │  ├────▶│  Grafana Agent  │────▶│   AMP   │"
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
echo "    - up{job=\"avalanchego\"}           # Node up/down"
echo "    - avalanche_node_healthy           # Health API status"
echo "    - avalanche_chain_bootstrapped     # Per-chain bootstrap status"
echo ""
echo "  Sync Status:"
echo "    - avalanche_c_chain_block_height   # Current block height"
echo "    - avalanche_c_chain_blocks_behind  # Blocks behind network"
echo "    - avalanche_c_chain_syncing        # Syncing status"
echo ""
echo "  Validator Status:"
echo "    - avalanche_validator_active       # Is active validator"
echo "    - avalanche_validator_stake_navax  # Staked amount"
echo "    - avalanche_uptime_*               # Uptime metrics"
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
echo "  systemctl status avalanche-collector"
echo "  systemctl status node_exporter"
echo ""
echo "  # View logs"
echo "  journalctl -u grafana-agent -f"
echo "  journalctl -u avalanche-collector -f"
echo ""
echo "  # Test metrics endpoints"
echo "  curl -s localhost:${AVALANCHE_METRICS_PORT}/ext/metrics | head -20"
echo "  curl -s localhost:${COLLECTOR_PORT}/metrics"
echo "  curl -s localhost:${NODE_EXPORTER_PORT}/metrics | head -20"
echo ""
echo "  # After 1-2 minutes, verify in AMP/AMG:"
echo "  #   up{job=\"avalanchego\"}"
echo "  #   avalanche_node_healthy"
echo "  #   avalanche_c_chain_blocks_behind"
echo "  #   node_cpu_seconds_total"
echo ""
