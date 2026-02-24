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
AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-ws-fdcbcf55-ed2c-4069-adad-c385e068d992}"
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

# External data cache (refreshed every 5 minutes)
EXTERNAL_DATA_INTERVAL=300  # 5 minutes

# Cached values
CACHED_LATEST_VERSION=""
CACHED_NETWORK_SLOT=""
CACHED_CLIENT_TYPE=""  # "agave" or "firedancer"
LAST_EXTERNAL_FETCH=0

# Helper to make RPC calls (must be defined before functions that use it)
rpc_call() {
    local method="$1"
    local params="${2:-[]}"
    curl -s --max-time 10 -X POST -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
        "${SOLANA_RPC}" 2>/dev/null || echo '{}'
}

# Detect client type (Firedancer or Agave)
detect_client_type() {
    if [[ -n "$CACHED_CLIENT_TYPE" ]]; then
        return 0
    fi

    local version_response
    version_response=$(rpc_call "getVersion")

    # Both Firedancer and Agave return "solana-core" field
    # Firedancer uses version format "0.xxx.xxxxx" (e.g., "0.808.30014")
    # Agave uses version format "x.y.z" where x >= 1 (e.g., "2.1.8", "3.1.8")
    local solana_core_version
    solana_core_version=$(echo "$version_response" | grep -o '"solana-core"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[0-9][^"]*"' | tr -d '"' || echo "")

    if [[ "$solana_core_version" =~ ^0\.[0-9]+\.[0-9]+$ ]]; then
        # Version starts with 0. -> Firedancer
        CACHED_CLIENT_TYPE="firedancer"
    else
        # Version starts with 1+ -> Agave
        CACHED_CLIENT_TYPE="agave"
    fi
}

# Fetch external data (GitHub latest version, network slot from public RPC)
fetch_external_data() {
    local now=$(date +%s)
    local cache_age=$((now - LAST_EXTERNAL_FETCH))

    # Only fetch if cache is older than EXTERNAL_DATA_INTERVAL
    if [[ $cache_age -lt $EXTERNAL_DATA_INTERVAL ]] && [[ -n "$CACHED_LATEST_VERSION" ]]; then
        return 0
    fi

    # Detect client type first
    detect_client_type

    # Fetch latest release version from GitHub based on client type
    local github_response
    local github_repo

    if [[ "$CACHED_CLIENT_TYPE" == "firedancer" ]]; then
        github_repo="firedancer-io/firedancer"
    else
        github_repo="anza-xyz/agave"
    fi

    github_response=$(curl -s --max-time 10 \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${github_repo}/releases/latest" 2>/dev/null || echo '{}')

    if echo "$github_response" | grep -q '"tag_name"'; then
        # Handle both "tag_name":"v1.18.x" and "tag_name": "v1.18.x" formats
        CACHED_LATEST_VERSION=$(echo "$github_response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"v[^"]*"' | tr -d '"' | sed 's/^v//' || echo "unknown")
    fi

    # Fetch network block height from public Solana mainnet RPC
    local network_response
    network_response=$(curl -s --max-time 10 -X POST \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"getBlockHeight"}' \
        "https://api.mainnet-beta.solana.com" 2>/dev/null || echo '{}')

    if echo "$network_response" | grep -q '"result"'; then
        CACHED_NETWORK_SLOT=$(echo "$network_response" | grep -o '"result":[0-9]*' | cut -d':' -f2 || echo "0")
    fi

    LAST_EXTERNAL_FETCH=$now
}

collect_metrics() {
    local timestamp=$(date +%s)

    # Fetch external data first (network block height, latest version)
    fetch_external_data

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
    local is_synced=1

    # Get local block height
    local block_height_response
    block_height_response=$(rpc_call "getBlockHeight")
    local block_height=0
    block_height=$(echo "$block_height_response" | grep -o '"result":[0-9]*' | cut -d':' -f2 || echo "0")

    # Calculate blocks behind using network block height from external data
    # fetch_external_data is called later, so we use cached value
    local blocks_behind=0
    if [[ -n "$CACHED_NETWORK_SLOT" ]] && [[ "$CACHED_NETWORK_SLOT" -gt 0 ]] && [[ "$block_height" -gt 0 ]]; then
        blocks_behind=$((CACHED_NETWORK_SLOT - block_height))
        if [[ "$blocks_behind" -lt 0 ]]; then
            blocks_behind=0
        fi
    fi

    # Determine sync status based on blocks behind
    if [[ "$is_healthy" -eq 0 ]]; then
        is_synced=0
    elif [[ "$blocks_behind" -gt 100 ]]; then
        is_synced=0
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

# HELP solana_node_slots_behind Number of blocks behind the network
# TYPE solana_node_slots_behind gauge
solana_node_slots_behind ${blocks_behind}

# HELP solana_node_synced Whether node is synced with cluster (1=synced, 0=syncing)
# TYPE solana_node_synced gauge
solana_node_synced ${is_synced}

EOF

    # =========================================================================
    # Validator Identity & Vote Account
    # =========================================================================

    local identity=""

    # Try to find validator identity keypair in common locations
    local identity_keypair=""
    for keypair_path in \
        "/home/firedancer/validator-keypair.json" \
        "/home/sol/validator-keypair.json" \
        "/var/lib/solana/validator-keypair.json" \
        "/root/validator-keypair.json"; do
        if [[ -f "$keypair_path" ]]; then
            identity_keypair="$keypair_path"
            break
        fi
    done

    # Get identity pubkey
    if [[ -n "$identity_keypair" ]] && command -v solana-keygen >/dev/null 2>&1; then
        identity=$(solana-keygen pubkey "$identity_keypair" 2>/dev/null || echo "")
    elif command -v solana >/dev/null 2>&1; then
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

            # Extract stake using solana validators command (most reliable)
            # Use public mainnet RPC to query validator info
            if command -v solana >/dev/null 2>&1; then
                local validators_output
                validators_output=$(timeout 30 solana validators --url https://api.mainnet-beta.solana.com 2>/dev/null | grep "${identity}" || echo "")
                if [[ -n "$validators_output" ]]; then
                    # Parse stake from validators output (last column before SOL, format: "343825.970070064 SOL")
                    # Output format: identity vote_account commission skip% credits credits version stake
                    activated_stake=$(echo "$validators_output" | awk '{for(i=1;i<=NF;i++) if($i=="SOL") print $(i-1)}' | head -1 || echo "0")
                    # Convert SOL to lamports (1 SOL = 1e9 lamports)
                    if [[ -n "$activated_stake" ]] && [[ "$activated_stake" != "0" ]]; then
                        activated_stake=$(echo "$activated_stake * 1000000000" | bc 2>/dev/null || echo "0")
                        # Remove decimal part if any
                        activated_stake=${activated_stake%%.*}
                    fi
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

    # Method 1: Try solana gossip command (works on validator nodes)
    if command -v solana >/dev/null 2>&1; then
        local gossip_output
        # Note: solana gossip uses gossip port directly, not RPC URL
        gossip_output=$(timeout 30 solana gossip 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
        gossip_output=${gossip_output:-0}
        if [[ "$gossip_output" =~ ^[0-9]+$ ]] && [[ "$gossip_output" -gt 1 ]]; then
            # Subtract header line
            peer_count=$((gossip_output - 1))
        fi
    fi

    # Method 2: Try getClusterNodes RPC
    if [[ "$peer_count" -eq 0 ]]; then
        local cluster_nodes_response
        cluster_nodes_response=$(rpc_call "getClusterNodes")
        if echo "$cluster_nodes_response" | grep -q '"pubkey"'; then
            peer_count=$(echo "$cluster_nodes_response" | grep -o '"pubkey"' | wc -l || echo "0")
            # Subtract 1 for self
            peer_count=$((peer_count > 0 ? peer_count - 1 : 0))
        fi
    fi

    # Method 3: Use getVoteAccounts to count active validators (RPC fallback)
    if [[ "$peer_count" -eq 0 ]]; then
        local vote_accounts_response
        vote_accounts_response=$(rpc_call "getVoteAccounts")
        if echo "$vote_accounts_response" | grep -q '"votePubkey"'; then
            peer_count=$(echo "$vote_accounts_response" | grep -o '"votePubkey"' | wc -l || echo "0")
        fi
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_network_peers Number of cluster nodes (peers)
# TYPE solana_network_peers gauge
solana_network_peers ${peer_count}

EOF

    # =========================================================================
    # Vote Latency (for validators)
    # =========================================================================
    local vote_latency_ms=0
    local last_vote_slot=0

    # Get vote latency by comparing last vote slot with current slot
    if [[ "$is_validator" -eq 1 ]] && command -v solana >/dev/null 2>&1; then
        # Try to get vote account info
        local vote_info
        vote_info=$(solana vote-account --url "${SOLANA_RPC}" "${identity}" 2>/dev/null || echo "")
        if echo "$vote_info" | grep -q "Last Timestamp Slot"; then
            last_vote_slot=$(echo "$vote_info" | grep "Last Timestamp Slot" | grep -o '[0-9]*' | head -1 || echo "0")
            if [[ "$last_vote_slot" -gt 0 ]] && [[ "$current_slot" -gt 0 ]]; then
                local slot_diff=$((current_slot - last_vote_slot))
                # Each slot is approximately 400ms
                vote_latency_ms=$((slot_diff * 400))
            fi
        fi
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_vote_latency_ms Vote latency in milliseconds (slots behind * 400ms)
# TYPE solana_vote_latency_ms gauge
solana_vote_latency_ms ${vote_latency_ms}

# HELP solana_last_vote_slot Last vote slot for this validator
# TYPE solana_last_vote_slot gauge
solana_last_vote_slot ${last_vote_slot}

EOF

    # =========================================================================
    # Epoch Progress
    # =========================================================================
    local epoch_progress_pct=0
    if [[ "$slots_in_epoch" -gt 0 ]]; then
        epoch_progress_pct=$(echo "scale=2; $slot_index * 100 / $slots_in_epoch" | bc 2>/dev/null || echo "0")
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_epoch_progress_percent Epoch progress percentage
# TYPE solana_epoch_progress_percent gauge
solana_epoch_progress_percent ${epoch_progress_pct}

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

    # Try solana-core first (standard Agave/Solana validator)
    if echo "$version_response" | grep -q '"solana-core"'; then
        solana_version=$(echo "$version_response" | grep -o '"solana-core":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
    # Try feature-set for Firedancer (extract version from result)
    elif echo "$version_response" | grep -q '"feature-set"'; then
        # Firedancer returns version in format like "0.808.30014"
        # Try to get version from CLI if available
        if command -v fdctl >/dev/null 2>&1; then
            solana_version=$(fdctl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        elif command -v solana >/dev/null 2>&1; then
            # Fallback to solana CLI version
            solana_version=$(solana --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        fi
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_node_version_info Solana node version
# TYPE solana_node_version_info gauge
solana_node_version_info{version="${solana_version}"} 1

EOF

    # =========================================================================
    # External Data (latest version, network block height)
    # =========================================================================
    # fetch_external_data is called at the start of collect_metrics()

    if [[ -n "$CACHED_LATEST_VERSION" ]]; then
        cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_latest_version_info Latest stable version from GitHub
# TYPE solana_latest_version_info gauge
solana_latest_version_info{version="${CACHED_LATEST_VERSION}"} 1

EOF
    fi

    if [[ -n "$CACHED_NETWORK_SLOT" ]] && [[ "$CACHED_NETWORK_SLOT" -gt 0 ]]; then
        cat >> "$METRICS_FILE_TMP" <<EOF
# HELP solana_network_block_height Network block height (slot) from public RPC
# TYPE solana_network_block_height gauge
solana_network_block_height ${CACHED_NETWORK_SLOT}

EOF
    fi

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

# =============================================================================
# SSM Hybrid Activation Support (On-Premise Nodes)
# =============================================================================
# Grafana Agent runs as grafana-agent user, which cannot access /root/.aws/credentials
# For SSM managed on-premise nodes, we need to copy credentials to a location
# accessible by grafana-agent and set up automatic refresh

if [[ -f /root/.aws/credentials ]]; then
    log_info "Detected SSM credentials, configuring for on-premise node..."

    # Copy credentials to grafana-agent accessible location
    mkdir -p /etc/grafana-agent
    cp /root/.aws/credentials /etc/grafana-agent/aws-credentials
    chown grafana-agent:grafana-agent /etc/grafana-agent/aws-credentials
    chmod 600 /etc/grafana-agent/aws-credentials

    # Configure grafana-agent service to use the credentials file
    mkdir -p /etc/systemd/system/grafana-agent.service.d
    cat > /etc/systemd/system/grafana-agent.service.d/aws.conf << 'AWSCONF'
[Service]
Environment="AWS_SHARED_CREDENTIALS_FILE=/etc/grafana-agent/aws-credentials"
AWSCONF

    # Create credentials refresh script (SSM credentials expire periodically)
    cat > /usr/local/bin/refresh-grafana-agent-credentials.sh << 'REFRESH'
#!/bin/bash
# Refresh AWS credentials for grafana-agent from SSM
# Only sync and restart when credentials actually change
if [[ -f /root/.aws/credentials ]]; then
    if ! diff -q /root/.aws/credentials /etc/grafana-agent/aws-credentials >/dev/null 2>&1; then
        cp /root/.aws/credentials /etc/grafana-agent/aws-credentials
        chown grafana-agent:grafana-agent /etc/grafana-agent/aws-credentials
        chmod 600 /etc/grafana-agent/aws-credentials
        systemctl restart grafana-agent
    fi
fi
REFRESH
    chmod +x /usr/local/bin/refresh-grafana-agent-credentials.sh

    # Add cron job to check credentials every 5 minutes
    echo "*/5 * * * * root /usr/local/bin/refresh-grafana-agent-credentials.sh" > /etc/cron.d/grafana-agent-credentials
    chmod 644 /etc/cron.d/grafana-agent-credentials

    log_ok "SSM credentials configured with auto-refresh (every 5 minutes)"
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
