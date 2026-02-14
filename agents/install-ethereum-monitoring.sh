#!/bin/bash
#
# Ethereum Validator Monitoring Installation Script
#
# Installs monitoring for Ethereum validator (Besu + Teku):
# 1. ethereum-collector - external data (latest versions, network block height)
# 2. Grafana Agent - federate from existing Prometheus + collector, push to AMP
#
# Prerequisites:
# - Prometheus running on :9090 (scraping besu, teku, node_exporter)
# - EC2 has IAM Role with AmazonPrometheusRemoteWriteAccess
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
echo -e "${BLUE}   Ethereum Validator Monitoring Installation${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

# =============================================================================
# Configuration
# =============================================================================

# AMP config (required)
AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-ws-fdcbcf55-ed2c-4069-adad-c385e068d992}"
AMP_REGION="${AMP_REGION:-us-east-1}"

# Optional config
INSTANCE_NAME="${INSTANCE_NAME:-$(hostname)}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
COLLECTOR_PORT="${COLLECTOR_PORT:-9104}"
CHAIN="ethereum"

# Validate AMP config
if [[ -z "$AMP_WORKSPACE_ID" ]]; then
    log_error "AMP_WORKSPACE_ID not set"
    echo ""
    echo "Usage:"
    echo "  export AMP_WORKSPACE_ID='ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
    echo "  export AMP_REGION='us-east-1'"
    echo "  sudo -E $0"
    exit 1
fi

echo "Configuration:"
echo "  AMP Workspace:   ${AMP_WORKSPACE_ID}"
echo "  AMP Region:      ${AMP_REGION}"
echo "  Instance:        ${INSTANCE_NAME}"
echo "  Chain:           ${CHAIN}"
echo "  Prometheus:      :${PROMETHEUS_PORT}"
echo "  Collector Port:  :${COLLECTOR_PORT}"
echo ""

# =============================================================================
# Step 1: Verify Prometheus
# =============================================================================

log_info "[Step 1/4] Verifying Prometheus..."

if curl -sf "http://localhost:${PROMETHEUS_PORT}/-/ready" >/dev/null 2>&1; then
    log_ok "Prometheus is running on :${PROMETHEUS_PORT}"

    # Check targets
    TARGET_COUNT=$(curl -s "http://localhost:${PROMETHEUS_PORT}/api/v1/targets" | grep -c '"health":"up"' || echo "0")
    log_info "Active targets: ${TARGET_COUNT}"
else
    log_error "Cannot connect to Prometheus (localhost:${PROMETHEUS_PORT})"
    log_info "This script requires an existing Prometheus to federate from"
    exit 1
fi

# =============================================================================
# Step 2: Install Ethereum Collector (external data)
# =============================================================================

log_info "[Step 2/4] Installing Ethereum metrics collector..."

# Create collector directory
mkdir -p /opt/ethereum-collector

# Create the collector script
cat > /opt/ethereum-collector/collector.sh <<'COLLECTOR_SCRIPT'
#!/bin/bash
#
# Ethereum External Data Collector
# Fetches latest versions from GitHub and network block height from public API
# Exposes metrics in Prometheus format
#

set -euo pipefail

LISTEN_PORT="${LISTEN_PORT:-9104}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-15}"

# Metrics file
METRICS_FILE="/tmp/ethereum_collector_metrics.prom"
METRICS_FILE_TMP="/tmp/ethereum_collector_metrics.prom.tmp"

# External data cache
EXTERNAL_DATA_FILE="/tmp/ethereum_external_data.cache"
EXTERNAL_DATA_INTERVAL=300  # 5 minutes

# Cached external data
CACHED_BESU_LATEST_VERSION=""
CACHED_TEKU_LATEST_VERSION=""
CACHED_NETWORK_BLOCK_HEIGHT=""

# Fetch latest Besu version from GitHub
fetch_besu_latest_version() {
    local latest_version=""
    local github_response

    github_response=$(curl -s --max-time 10 \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/hyperledger/besu/releases/latest" 2>/dev/null || echo "{}")

    if echo "$github_response" | grep -q '"tag_name"'; then
        latest_version=$(echo "$github_response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[0-9][^"]*"' | tr -d '"' || echo "")
    fi

    echo "$latest_version"
}

# Fetch latest Teku version from GitHub
fetch_teku_latest_version() {
    local latest_version=""
    local github_response

    github_response=$(curl -s --max-time 10 \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/Consensys/teku/releases/latest" 2>/dev/null || echo "{}")

    if echo "$github_response" | grep -q '"tag_name"'; then
        latest_version=$(echo "$github_response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[0-9][^"]*"' | tr -d '"' || echo "")
    fi

    echo "$latest_version"
}

# Fetch network block height from public API
fetch_network_block_height() {
    local block_height=""
    local api_response

    # Try Etherscan API (no API key needed for this endpoint)
    api_response=$(curl -s --max-time 10 \
        "https://api.etherscan.io/api?module=proxy&action=eth_blockNumber" 2>/dev/null || echo "{}")

    if echo "$api_response" | grep -q '"result"'; then
        local hex_block
        hex_block=$(echo "$api_response" | grep -o '"result":"0x[^"]*"' | cut -d'"' -f4 || echo "")
        if [[ -n "$hex_block" ]]; then
            # Convert hex to decimal
            block_height=$((16#${hex_block#0x}))
        fi
    fi

    # Fallback to public RPC if Etherscan fails
    if [[ -z "$block_height" ]] || [[ "$block_height" -eq 0 ]]; then
        api_response=$(curl -s --max-time 10 \
            -X POST \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            "https://ethereum-rpc.publicnode.com" 2>/dev/null || echo "{}")

        if echo "$api_response" | grep -q '"result"'; then
            local hex_block
            hex_block=$(echo "$api_response" | grep -o '"result":"0x[^"]*"' | cut -d'"' -f4 || echo "")
            if [[ -n "$hex_block" ]]; then
                block_height=$((16#${hex_block#0x}))
            fi
        fi
    fi

    echo "$block_height"
}

# Fetch and cache external data (rate-limited)
fetch_external_data() {
    local current_time=$(date +%s)
    local cache_time=0
    local cached_besu=""
    local cached_teku=""
    local cached_block=""

    # Read cache if exists
    if [[ -f "$EXTERNAL_DATA_FILE" ]]; then
        cache_time=$(sed -n '1p' "$EXTERNAL_DATA_FILE" 2>/dev/null || echo "0")
        cached_besu=$(sed -n '2p' "$EXTERNAL_DATA_FILE" 2>/dev/null || echo "")
        cached_teku=$(sed -n '3p' "$EXTERNAL_DATA_FILE" 2>/dev/null || echo "")
        cached_block=$(sed -n '4p' "$EXTERNAL_DATA_FILE" 2>/dev/null || echo "")
    fi

    # Check if cache is still valid
    local cache_age=$((current_time - cache_time))
    if [[ "$cache_age" -lt "$EXTERNAL_DATA_INTERVAL" ]] && [[ -n "$cached_besu" || -n "$cached_teku" || -n "$cached_block" ]]; then
        CACHED_BESU_LATEST_VERSION="$cached_besu"
        CACHED_TEKU_LATEST_VERSION="$cached_teku"
        CACHED_NETWORK_BLOCK_HEIGHT="$cached_block"
        return 0
    fi

    # Fetch fresh data
    local new_besu new_teku new_block

    new_besu=$(fetch_besu_latest_version)
    new_teku=$(fetch_teku_latest_version)
    new_block=$(fetch_network_block_height)

    # Use new data if available, otherwise keep cached
    CACHED_BESU_LATEST_VERSION="${new_besu:-$cached_besu}"
    CACHED_TEKU_LATEST_VERSION="${new_teku:-$cached_teku}"
    CACHED_NETWORK_BLOCK_HEIGHT="${new_block:-$cached_block}"

    # Update cache file
    {
        echo "$current_time"
        echo "$CACHED_BESU_LATEST_VERSION"
        echo "$CACHED_TEKU_LATEST_VERSION"
        echo "$CACHED_NETWORK_BLOCK_HEIGHT"
    } > "$EXTERNAL_DATA_FILE"
}

collect_metrics() {
    local timestamp=$(date +%s)

    # Fetch external data at start of collection (rate-limited internally)
    fetch_external_data

    cat > "$METRICS_FILE_TMP" <<EOF
# HELP ethereum_collector_scrape_timestamp_seconds Unix timestamp of last scrape
# TYPE ethereum_collector_scrape_timestamp_seconds gauge
ethereum_collector_scrape_timestamp_seconds ${timestamp}

EOF

    # =========================================================================
    # Latest Versions from GitHub
    # =========================================================================
    local besu_latest="${CACHED_BESU_LATEST_VERSION:-unknown}"
    local teku_latest="${CACHED_TEKU_LATEST_VERSION:-unknown}"

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP ethereum_besu_latest_version_info Latest Besu version from GitHub
# TYPE ethereum_besu_latest_version_info gauge
ethereum_besu_latest_version_info{version="${besu_latest}"} 1

# HELP ethereum_teku_latest_version_info Latest Teku version from GitHub
# TYPE ethereum_teku_latest_version_info gauge
ethereum_teku_latest_version_info{version="${teku_latest}"} 1

EOF

    # =========================================================================
    # Network Block Height
    # =========================================================================
    local network_block_height=0
    local cached_block_num="${CACHED_NETWORK_BLOCK_HEIGHT//[^0-9]/}"

    if [[ -n "$cached_block_num" ]] && [[ "$cached_block_num" -gt 0 ]]; then
        network_block_height="$cached_block_num"
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP ethereum_network_block_height Network block height from public API
# TYPE ethereum_network_block_height gauge
ethereum_network_block_height ${network_block_height}

EOF

    # =========================================================================
    # Collector metadata
    # =========================================================================
    local scrape_success=1

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP ethereum_collector_scrape_success Whether the last scrape was successful (1=yes, 0=no)
# TYPE ethereum_collector_scrape_success gauge
ethereum_collector_scrape_success ${scrape_success}
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
    echo "Starting Ethereum external data collector..."
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

chmod +x /opt/ethereum-collector/collector.sh

# Create systemd service for collector
cat > /etc/systemd/system/ethereum-collector.service <<EOF
[Unit]
Description=Ethereum External Data Collector
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment="LISTEN_PORT=${COLLECTOR_PORT}"
Environment="SCRAPE_INTERVAL=15"
ExecStart=/opt/ethereum-collector/collector.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ethereum-collector
systemctl restart ethereum-collector

sleep 3

if systemctl is-active --quiet ethereum-collector; then
    log_ok "Ethereum collector running on :${COLLECTOR_PORT}"
else
    log_warn "Ethereum collector may have issues, check: journalctl -u ethereum-collector -f"
fi

# =============================================================================
# Step 3: Install and Configure Grafana Agent
# =============================================================================

log_info "[Step 3/4] Installing Grafana Agent..."

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

# Check Prometheus targets
log_info "Checking existing Prometheus configuration..."

PROM_TARGETS=""
if curl -sf "http://localhost:${PROMETHEUS_PORT}/api/v1/targets" >/dev/null 2>&1; then
    PROM_TARGETS=$(curl -s "http://localhost:${PROMETHEUS_PORT}/api/v1/targets" | grep -o '"job":"[^"]*"' | cut -d'"' -f4 | sort -u | tr '\n' ', ')
    log_ok "Found Prometheus on :${PROMETHEUS_PORT}"
    log_info "Prometheus targets: ${PROM_TARGETS}"
fi

# Generate configuration
log_info "Configuring Grafana Agent..."

cat > /etc/grafana-agent.yaml <<EOF
# Grafana Agent configuration - Ethereum Validator Monitoring
# Generated: $(date -Iseconds)
# Mode: Federation from existing Prometheus + custom collector
# Prometheus targets: ${PROM_TARGETS}

metrics:
  global:
    scrape_interval: 15s
    external_labels:
      instance: '${INSTANCE_NAME}'
      chain: '${CHAIN}'
      env: 'production'

  configs:
    - name: ethereum_metrics
      scrape_configs:
        # Federate all metrics from existing Prometheus
        - job_name: 'prometheus_federation'
          honor_labels: true
          metrics_path: '/federate'
          params:
            'match[]':
              - '{job=~".+"}'
          static_configs:
            - targets: ['localhost:${PROMETHEUS_PORT}']
          relabel_configs:
            - source_labels: [__address__]
              target_label: prometheus_server
              replacement: '${INSTANCE_NAME}'
          metric_relabel_configs:
            - source_labels: [instance]
              target_label: instance
              regex: '(.+)'
              replacement: '${INSTANCE_NAME}'

        # Custom collector metrics (external data)
        - job_name: 'ethereum_collector'
          static_configs:
            - targets: ['localhost:${COLLECTOR_PORT}']
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
# Step 4: Summary
# =============================================================================

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   Installation Complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Architecture:"
echo ""
echo "  ┌─────────────────────┐"
echo "  │   Prometheus        │"
echo "  │   :${PROMETHEUS_PORT} (federation)│──┐"
echo "  └─────────────────────┘  │"
echo "                           │"
echo "  ┌─────────────────────┐  │     ┌─────────────────┐     ┌─────────┐"
echo "  │ ethereum-collector  │  ├────▶│  Grafana Agent  │────▶│   AMP   │"
echo "  │   :${COLLECTOR_PORT}              │──┘     └─────────────────┘     └─────────┘"
echo "  └─────────────────────┘"
echo ""
echo "Metrics collected:"
echo ""
echo "  From Prometheus (federated):"
echo "    - besu_* (execution client)"
echo "    - ethereum_blockchain_height, ethereum_peer_count"
echo "    - beacon_*, validator_* (consensus client)"
echo "    - node_* (system metrics)"
echo ""
echo "  From ethereum-collector (external data):"
echo "    - ethereum_besu_latest_version_info     # Latest Besu from GitHub"
echo "    - ethereum_teku_latest_version_info     # Latest Teku from GitHub"
echo "    - ethereum_network_block_height         # Network block height"
echo ""
echo "Verify installation:"
echo ""
echo "  # Check services"
echo "  systemctl status grafana-agent"
echo "  systemctl status ethereum-collector"
echo ""
echo "  # View logs"
echo "  journalctl -u grafana-agent -f"
echo "  journalctl -u ethereum-collector -f"
echo ""
echo "  # Test collector metrics"
echo "  curl -s localhost:${COLLECTOR_PORT}/metrics"
echo ""
echo "  # After 1-2 minutes, verify in AMP/AMG:"
echo "  #   ethereum_besu_latest_version_info"
echo "  #   ethereum_teku_latest_version_info"
echo "  #   ethereum_network_block_height"
echo ""
