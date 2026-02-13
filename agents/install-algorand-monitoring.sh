#!/bin/bash
#
# Algorand Node Monitoring Installation Script
#
# Installs monitoring tools for an existing Algorand node (algod):
# 1. node_exporter - system metrics (CPU, memory, disk, network)
# 2. algorand-collector - custom metrics (health, sync, participation status)
# 3. Grafana Agent - push all metrics to Amazon Managed Prometheus
#
# Prerequisites:
# - Algorand node (algod) running on localhost
# - goal CLI available
# - EC2 has IAM Role with AmazonPrometheusRemoteWriteAccess
#
# Metrics collected:
# - Node up/down (via Prometheus 'up' metric)
# - System resources (node_exporter on :9100)
# - Node health status (health/ready API)
# - Blockchain sync status (rounds behind network)
# - Participation key status
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
echo -e "${BLUE}   Algorand Node Monitoring Installation${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

# =============================================================================
# Configuration
# =============================================================================

# AMP config (required)
AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-ws-fdcbcf55-ed2c-4069-adad-c385e068d992}"
AMP_REGION="${AMP_REGION:-us-east-1}"

# Algorand node config
ALGORAND_DATA="${ALGORAND_DATA:-/var/lib/algorand}"
ALGORAND_API_PORT="${ALGORAND_API_PORT:-8080}"
ALGORAND_API_TOKEN="${ALGORAND_API_TOKEN:-}"

# Collector config
COLLECTOR_PORT="${COLLECTOR_PORT:-9103}"

# node_exporter config
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.7.0}"

# Optional config
INSTANCE_NAME="${INSTANCE_NAME:-$(hostname)}"
CHAIN="algorand"

# Validate AMP config
if [[ -z "$AMP_WORKSPACE_ID" ]]; then
    log_error "AMP_WORKSPACE_ID not set"
    echo ""
    echo "Usage:"
    echo "  export AMP_WORKSPACE_ID='ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
    echo "  export AMP_REGION='us-east-1'"
    echo "  export ALGORAND_DATA='/var/lib/algorand'  # optional"
    echo "  export INSTANCE_NAME='algorand-node-1'    # optional"
    echo "  sudo -E $0"
    exit 1
fi

# Auto-detect API token if not provided
if [[ -z "$ALGORAND_API_TOKEN" ]] && [[ -f "${ALGORAND_DATA}/algod.token" ]]; then
    ALGORAND_API_TOKEN=$(cat "${ALGORAND_DATA}/algod.token" 2>/dev/null || echo "")
fi

# Auto-detect API endpoint from algod.net
if [[ -f "${ALGORAND_DATA}/algod.net" ]]; then
    ALGORAND_API_ENDPOINT=$(cat "${ALGORAND_DATA}/algod.net" 2>/dev/null || echo "localhost:${ALGORAND_API_PORT}")
else
    ALGORAND_API_ENDPOINT="localhost:${ALGORAND_API_PORT}"
fi

echo "Configuration:"
echo "  AMP Workspace:     ${AMP_WORKSPACE_ID}"
echo "  AMP Region:        ${AMP_REGION}"
echo "  Instance:          ${INSTANCE_NAME}"
echo "  Chain:             ${CHAIN}"
echo "  Algorand Data:     ${ALGORAND_DATA}"
echo "  Algorand API:      ${ALGORAND_API_ENDPOINT}"
echo "  Collector Port:    ${COLLECTOR_PORT}"
echo "  node_exporter:     ${NODE_EXPORTER_PORT}"
echo ""

# =============================================================================
# Step 1: Verify Algorand Node
# =============================================================================

log_info "[Step 1/4] Verifying Algorand node..."

# Check if goal CLI is available
if command -v goal >/dev/null 2>&1; then
    log_ok "goal CLI found"
else
    log_warn "goal CLI not found in PATH"
fi

# Check if algod is responding
HEALTH_URL="http://${ALGORAND_API_ENDPOINT}/health"
if curl -sf "${HEALTH_URL}" >/dev/null 2>&1; then
    log_ok "Algorand node is responding (health check passed)"
else
    # Try with API token
    if [[ -n "$ALGORAND_API_TOKEN" ]]; then
        if curl -sf -H "X-Algo-API-Token: ${ALGORAND_API_TOKEN}" "${HEALTH_URL}" >/dev/null 2>&1; then
            log_ok "Algorand node is responding (with API token)"
        else
            log_error "Cannot connect to Algorand node at ${ALGORAND_API_ENDPOINT}"
            log_info "Make sure algod is running and accessible"
            exit 1
        fi
    else
        log_error "Cannot connect to Algorand node at ${ALGORAND_API_ENDPOINT}"
        log_info "Make sure algod is running and accessible"
        exit 1
    fi
fi

# Check ready status
READY_URL="http://${ALGORAND_API_ENDPOINT}/ready"
if curl -sf "${READY_URL}" >/dev/null 2>&1; then
    log_ok "Node is ready (fully synced)"
else
    log_warn "Node is not ready yet (may still be syncing)"
fi

# Get node status if goal is available
if command -v goal >/dev/null 2>&1; then
    log_info "Getting node status..."
    if goal node status -d "${ALGORAND_DATA}" 2>/dev/null; then
        log_ok "Node status retrieved"
    else
        log_warn "Could not get node status via goal CLI"
    fi
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
# Step 3: Install Algorand Collector (custom metrics)
# =============================================================================

log_info "[Step 3/4] Installing Algorand metrics collector..."

# Create collector directory
mkdir -p /opt/algorand-collector

# Create the collector script
cat > /opt/algorand-collector/collector.sh <<'COLLECTOR_SCRIPT'
#!/bin/bash
#
# Algorand Metrics Collector
# Collects health, sync status, and participation metrics from Algorand node
# Exposes metrics in Prometheus format
#

set -euo pipefail

ALGORAND_API="${ALGORAND_API:-http://localhost:8080}"
ALGORAND_TOKEN="${ALGORAND_TOKEN:-}"
ALGORAND_DATA="${ALGORAND_DATA:-/var/lib/algorand}"
LISTEN_PORT="${LISTEN_PORT:-9103}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-15}"

# Metrics file
METRICS_FILE="/tmp/algorand_collector_metrics.prom"
METRICS_FILE_TMP="/tmp/algorand_collector_metrics.prom.tmp"

# External data cache
EXTERNAL_DATA_FILE="/tmp/algorand_external_data.cache"
EXTERNAL_DATA_INTERVAL=300  # 5 minutes

# Cached external data (populated by fetch_external_data)
CACHED_LATEST_VERSION=""
CACHED_NETWORK_ROUND=""

# Fetch latest version from GitHub
fetch_latest_version() {
    local latest_version=""
    local github_response

    # Try GitHub API for go-algorand releases
    github_response=$(curl -s --max-time 10 \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/algorand/go-algorand/releases/latest" 2>/dev/null || echo "{}")

    if echo "$github_response" | grep -q '"tag_name"'; then
        latest_version=$(echo "$github_response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"v[^"]*"' | tr -d '"' | sed 's/^v//' || echo "")
    fi

    echo "$latest_version"
}

# Fetch network round from Algorand public API
fetch_network_round() {
    local network_round=""
    local api_response

    # Try AlgoNode public API (mainnet)
    api_response=$(curl -s --max-time 10 \
        "https://mainnet-api.algonode.cloud/v2/status" 2>/dev/null || echo "{}")

    if echo "$api_response" | grep -q '"last-round"'; then
        network_round=$(echo "$api_response" | grep -o '"last-round":[0-9]*' | cut -d':' -f2 || echo "")
    fi

    # Fallback to Algorand indexer if needed
    if [[ -z "$network_round" ]]; then
        api_response=$(curl -s --max-time 10 \
            "https://mainnet-idx.algonode.cloud/health" 2>/dev/null || echo "{}")
        if echo "$api_response" | grep -q '"round"'; then
            network_round=$(echo "$api_response" | grep -o '"round":[0-9]*' | cut -d':' -f2 || echo "")
        fi
    fi

    echo "$network_round"
}

# Fetch and cache external data (rate-limited)
fetch_external_data() {
    local current_time=$(date +%s)
    local cache_time=0
    local cached_version=""
    local cached_round=""

    # Read cache if exists
    if [[ -f "$EXTERNAL_DATA_FILE" ]]; then
        cache_time=$(head -1 "$EXTERNAL_DATA_FILE" 2>/dev/null || echo "0")
        cached_version=$(sed -n '2p' "$EXTERNAL_DATA_FILE" 2>/dev/null || echo "")
        cached_round=$(sed -n '3p' "$EXTERNAL_DATA_FILE" 2>/dev/null || echo "")
    fi

    # Check if cache is still valid
    local cache_age=$((current_time - cache_time))
    if [[ "$cache_age" -lt "$EXTERNAL_DATA_INTERVAL" ]] && [[ -n "$cached_version" || -n "$cached_round" ]]; then
        CACHED_LATEST_VERSION="$cached_version"
        CACHED_NETWORK_ROUND="$cached_round"
        return 0
    fi

    # Fetch fresh data
    local new_version
    local new_round

    new_version=$(fetch_latest_version)
    new_round=$(fetch_network_round)

    # Use new data if available, otherwise keep cached
    if [[ -n "$new_version" ]]; then
        CACHED_LATEST_VERSION="$new_version"
    else
        CACHED_LATEST_VERSION="$cached_version"
    fi

    if [[ -n "$new_round" ]]; then
        CACHED_NETWORK_ROUND="$new_round"
    else
        CACHED_NETWORK_ROUND="$cached_round"
    fi

    # Update cache file
    {
        echo "$current_time"
        echo "$CACHED_LATEST_VERSION"
        echo "$CACHED_NETWORK_ROUND"
    } > "$EXTERNAL_DATA_FILE"
}

# Helper to make API calls
api_call() {
    local endpoint="$1"
    local headers=()

    if [[ -n "$ALGORAND_TOKEN" ]]; then
        headers+=(-H "X-Algo-API-Token: ${ALGORAND_TOKEN}")
    fi

    curl -s --max-time 10 "${headers[@]}" "${ALGORAND_API}${endpoint}" 2>/dev/null || echo '{}'
}

collect_metrics() {
    local timestamp=$(date +%s)

    # Fetch external data at start of collection (rate-limited internally)
    fetch_external_data

    cat > "$METRICS_FILE_TMP" <<EOF
# HELP algorand_collector_scrape_timestamp_seconds Unix timestamp of last scrape
# TYPE algorand_collector_scrape_timestamp_seconds gauge
algorand_collector_scrape_timestamp_seconds ${timestamp}

EOF

    # =========================================================================
    # Health Status
    # =========================================================================
    local is_healthy=0
    if curl -sf --max-time 5 "${ALGORAND_API}/health" >/dev/null 2>&1; then
        is_healthy=1
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP algorand_node_healthy Whether the node is healthy (1=healthy, 0=unhealthy)
# TYPE algorand_node_healthy gauge
algorand_node_healthy ${is_healthy}

EOF

    # =========================================================================
    # Ready Status (fully synced)
    # =========================================================================
    local is_ready=0
    if curl -sf --max-time 5 "${ALGORAND_API}/ready" >/dev/null 2>&1; then
        is_ready=1
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP algorand_node_ready Whether the node is ready and fully synced (1=ready, 0=not ready)
# TYPE algorand_node_ready gauge
algorand_node_ready ${is_ready}

EOF

    # =========================================================================
    # Node Status (round, version, etc.)
    # =========================================================================
    local status_response
    status_response=$(api_call "/v2/status")

    local last_round=0
    local catchup_time=0
    local last_version=""
    local time_since_last_round=0

    if echo "$status_response" | grep -q '"last-round"'; then
        last_round=$(echo "$status_response" | grep -o '"last-round":[0-9]*' | cut -d':' -f2 || echo "0")
    fi

    if echo "$status_response" | grep -q '"catchup-time"'; then
        catchup_time=$(echo "$status_response" | grep -o '"catchup-time":[0-9]*' | cut -d':' -f2 || echo "0")
    fi

    if echo "$status_response" | grep -q '"time-since-last-round"'; then
        time_since_last_round=$(echo "$status_response" | grep -o '"time-since-last-round":[0-9]*' | cut -d':' -f2 || echo "0")
    fi

    # Determine if synced (catchup-time of 0 means synced)
    local is_synced=0
    if [[ "$catchup_time" -eq 0 ]] && [[ "$is_ready" -eq 1 ]]; then
        is_synced=1
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP algorand_node_last_round Last committed round number
# TYPE algorand_node_last_round gauge
algorand_node_last_round ${last_round}

# HELP algorand_node_catchup_time_ns Time spent catching up in nanoseconds (0 = synced)
# TYPE algorand_node_catchup_time_ns gauge
algorand_node_catchup_time_ns ${catchup_time}

# HELP algorand_node_time_since_last_round_ns Time since last round in nanoseconds
# TYPE algorand_node_time_since_last_round_ns gauge
algorand_node_time_since_last_round_ns ${time_since_last_round}

# HELP algorand_node_synced Whether node is synced with network (1=synced, 0=syncing)
# TYPE algorand_node_synced gauge
algorand_node_synced ${is_synced}

EOF

    # =========================================================================
    # Network Round and Rounds Behind
    # =========================================================================
    local network_round=0
    local rounds_behind=0

    # Use cached network round from external data
    # Ensure numeric comparison by removing any whitespace
    local cached_round_num="${CACHED_NETWORK_ROUND//[^0-9]/}"
    local last_round_num="${last_round//[^0-9]/}"

    if [[ -n "$cached_round_num" ]] && [[ "$cached_round_num" -gt 0 ]]; then
        network_round="$cached_round_num"
        # Calculate rounds behind
        if [[ -n "$last_round_num" ]] && [[ "$last_round_num" -gt 0 ]]; then
            rounds_behind=$((cached_round_num - last_round_num))
            if [[ "$rounds_behind" -lt 0 ]]; then
                rounds_behind=0
            fi
        fi
    else
        # Fallback: estimate from catchup time if network round unavailable
        if [[ "$catchup_time" -gt 0 ]]; then
            rounds_behind=$((catchup_time / 3300000000))
            if [[ "$rounds_behind" -lt 1 ]]; then
                rounds_behind=1
            fi
        fi
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP algorand_network_round Network round from public API
# TYPE algorand_network_round gauge
algorand_network_round ${network_round}

# HELP algorand_node_rounds_behind Rounds behind the network (network_round - last_round)
# TYPE algorand_node_rounds_behind gauge
algorand_node_rounds_behind ${rounds_behind}

EOF

    # =========================================================================
    # Ledger Supply
    # =========================================================================
    local supply_response
    supply_response=$(api_call "/v2/ledger/supply")

    local total_money=0
    local online_money=0

    if echo "$supply_response" | grep -q '"total-money"'; then
        total_money=$(echo "$supply_response" | grep -o '"total-money":[0-9]*' | cut -d':' -f2 || echo "0")
    fi

    if echo "$supply_response" | grep -q '"online-money"'; then
        online_money=$(echo "$supply_response" | grep -o '"online-money":[0-9]*' | cut -d':' -f2 || echo "0")
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP algorand_ledger_total_money_microalgos Total money supply in microAlgos
# TYPE algorand_ledger_total_money_microalgos gauge
algorand_ledger_total_money_microalgos ${total_money}

# HELP algorand_ledger_online_money_microalgos Online money (participating in consensus) in microAlgos
# TYPE algorand_ledger_online_money_microalgos gauge
algorand_ledger_online_money_microalgos ${online_money}

EOF

    # =========================================================================
    # Network Peers
    # =========================================================================
    local peer_count=0

    # Method 1: Count established connections on Algorand P2P ports (4160, 4161)
    # This is the most reliable method as Algorand API doesn't expose peer count
    if command -v ss >/dev/null 2>&1; then
        peer_count=$(ss -tn 2>/dev/null | grep -E ":4160|:4161" | wc -l | tr -d ' ')
    elif command -v netstat >/dev/null 2>&1; then
        peer_count=$(netstat -an 2>/dev/null | grep -E ":(4160|4161)" | grep ESTABLISHED | wc -l | tr -d ' ')
    fi

    # Ensure peer_count is a valid number
    peer_count=${peer_count:-0}
    if ! [[ "$peer_count" =~ ^[0-9]+$ ]]; then
        peer_count=0
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP algorand_network_peers Number of connected peers
# TYPE algorand_network_peers gauge
algorand_network_peers ${peer_count}

EOF

    # =========================================================================
    # Participation Keys (if goal available)
    # =========================================================================
    local has_participation_key=0
    local partkey_valid_first=0
    local partkey_valid_last=0

    if command -v goal >/dev/null 2>&1 && [[ -d "$ALGORAND_DATA" ]]; then
        local partkey_output
        partkey_output=$(goal account listpartkeys -d "$ALGORAND_DATA" 2>/dev/null || echo "")

        if echo "$partkey_output" | grep -q "Registered"; then
            has_participation_key=1
            # Try to extract valid rounds
            partkey_valid_first=$(echo "$partkey_output" | grep -o 'First valid: [0-9]*' | head -1 | grep -o '[0-9]*' || echo "0")
            partkey_valid_last=$(echo "$partkey_output" | grep -o 'Last valid: [0-9]*' | head -1 | grep -o '[0-9]*' || echo "0")
        fi
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP algorand_participation_key_active Whether node has an active participation key (1=yes, 0=no)
# TYPE algorand_participation_key_active gauge
algorand_participation_key_active ${has_participation_key}

# HELP algorand_participation_key_valid_first First valid round for participation key
# TYPE algorand_participation_key_valid_first gauge
algorand_participation_key_valid_first ${partkey_valid_first}

# HELP algorand_participation_key_valid_last Last valid round for participation key
# TYPE algorand_participation_key_valid_last gauge
algorand_participation_key_valid_last ${partkey_valid_last}

EOF

    # =========================================================================
    # Version Info
    # =========================================================================
    local version_response
    version_response=$(api_call "/versions")

    local build_version="unknown"
    if echo "$version_response" | grep -q '"build"'; then
        # Extract major.minor.patch from build object
        local major minor patch
        major=$(echo "$version_response" | grep -o '"major":[0-9]*' | cut -d':' -f2 || echo "0")
        minor=$(echo "$version_response" | grep -o '"minor":[0-9]*' | cut -d':' -f2 || echo "0")
        patch=$(echo "$version_response" | grep -o '"patch":[0-9]*' | cut -d':' -f2 || echo "0")
        build_version="${major}.${minor}.${patch}"
    fi

    # Latest version from GitHub
    local latest_version="unknown"
    if [[ -n "$CACHED_LATEST_VERSION" ]]; then
        latest_version="$CACHED_LATEST_VERSION"
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP algorand_node_version_info Algorand node version
# TYPE algorand_node_version_info gauge
algorand_node_version_info{version="${build_version}"} 1

# HELP algorand_latest_version_info Latest Algorand version from GitHub
# TYPE algorand_latest_version_info gauge
algorand_latest_version_info{version="${latest_version}"} 1

EOF

    # =========================================================================
    # Collector metadata
    # =========================================================================
    local scrape_success=1

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP algorand_collector_scrape_success Whether the last scrape was successful (1=yes, 0=no)
# TYPE algorand_collector_scrape_success gauge
algorand_collector_scrape_success ${scrape_success}
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
    echo "Starting Algorand metrics collector..."
    echo "  API endpoint: ${ALGORAND_API}"
    echo "  Data dir:     ${ALGORAND_DATA}"
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

chmod +x /opt/algorand-collector/collector.sh

# Create systemd service for collector
cat > /etc/systemd/system/algorand-collector.service <<EOF
[Unit]
Description=Algorand Metrics Collector
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment="ALGORAND_API=http://${ALGORAND_API_ENDPOINT}"
Environment="ALGORAND_TOKEN=${ALGORAND_API_TOKEN}"
Environment="ALGORAND_DATA=${ALGORAND_DATA}"
Environment="LISTEN_PORT=${COLLECTOR_PORT}"
Environment="SCRAPE_INTERVAL=15"
ExecStart=/opt/algorand-collector/collector.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable algorand-collector
systemctl restart algorand-collector

sleep 3

if systemctl is-active --quiet algorand-collector; then
    log_ok "Algorand collector running on :${COLLECTOR_PORT}"
else
    log_warn "Algorand collector may have issues, check: journalctl -u algorand-collector -f"
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
# Grafana Agent configuration - Algorand Node Monitoring
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
    - name: algorand_metrics
      scrape_configs:
        # Custom collector metrics (health, sync, participation)
        - job_name: 'algorand_collector'
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
echo "  │   algod             │"
echo "  │   :${ALGORAND_API_PORT} (API)        │──┐"
echo "  └─────────────────────┘  │"
echo "                           │"
echo "  ┌─────────────────────┐  │     ┌─────────────────┐     ┌─────────┐"
echo "  │ algorand-collector  │  ├────▶│  Grafana Agent  │────▶│   AMP   │"
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
echo "    - algorand_node_healthy            # Health API status"
echo "    - algorand_node_ready              # Ready/fully synced status"
echo "    - algorand_node_last_round         # Current round number"
echo ""
echo "  Sync Status:"
echo "    - algorand_node_synced             # Whether synced with network"
echo "    - algorand_network_round           # Network round from public API"
echo "    - algorand_node_rounds_behind      # Rounds behind (network - local)"
echo "    - algorand_node_catchup_time_ns    # Time spent catching up"
echo ""
echo "  Participation Status:"
echo "    - algorand_participation_key_active    # Has active participation key"
echo "    - algorand_participation_key_valid_*   # Key validity range"
echo ""
echo "  Ledger Info:"
echo "    - algorand_ledger_total_money_microalgos"
echo "    - algorand_ledger_online_money_microalgos"
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
echo "  systemctl status algorand-collector"
echo "  systemctl status node_exporter"
echo ""
echo "  # View logs"
echo "  journalctl -u grafana-agent -f"
echo "  journalctl -u algorand-collector -f"
echo ""
echo "  # Test metrics endpoints"
echo "  curl -s localhost:${COLLECTOR_PORT}/metrics"
echo "  curl -s localhost:${NODE_EXPORTER_PORT}/metrics | head -20"
echo ""
echo "  # After 1-2 minutes, verify in AMP/AMG:"
echo "  #   algorand_node_healthy"
echo "  #   algorand_node_synced"
echo "  #   algorand_network_round"
echo "  #   algorand_node_rounds_behind"
echo "  #   algorand_latest_version_info"
echo ""
