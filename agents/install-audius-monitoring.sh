#!/bin/bash
#
# Audius Node Monitoring Installation Script
#
# Installs monitoring tools for an Audius node (go-openaudio):
# 1. node_exporter - system metrics (CPU, memory, disk, network)
# 2. audius-collector - custom metrics from /health-check endpoint
# 3. Grafana Agent - push all metrics to Amazon Managed Prometheus
#
# Prerequisites:
# - Audius node running (openaudio/go-openaudio Docker container)
# - Health check endpoint accessible via HTTPS
# - EC2 has IAM Role with AmazonPrometheusRemoteWriteAccess
#
# Metrics collected:
# - Node up/down (via Prometheus 'up' metric)
# - System resources (node_exporter on :9100)
# - Core health, readiness, sync status
# - Chain height, tx count, peer count
# - Resource usage (CPU, memory, disk, database)
# - Storage (mediorum path size/used, disk total/used)
# - Version info and latest version from GitHub
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
echo -e "${BLUE}   Audius Node Monitoring Installation${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

# =============================================================================
# Configuration
# =============================================================================

# AMP config (required)
AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-ws-fdcbcf55-ed2c-4069-adad-c385e068d992}"
AMP_REGION="${AMP_REGION:-us-east-1}"

# Audius node config
# AUDIUS_HOSTNAME: the FQDN of this node (used for TLS SNI in health check)
# Auto-detected from Docker container environment or hostname command
AUDIUS_HOSTNAME="${AUDIUS_HOSTNAME:-}"
AUDIUS_DOCKER_CONTAINER="${AUDIUS_DOCKER_CONTAINER:-}"

# Collector config
COLLECTOR_PORT="${COLLECTOR_PORT:-9106}"

# node_exporter config
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.7.0}"

# Optional config
# Auto-detect instance name: transform "creator-X.*" → "validator-audius-X"
_raw_hostname="$(hostname)"
if [[ -z "${INSTANCE_NAME:-}" ]]; then
    if [[ "$_raw_hostname" =~ ^creator-([0-9]+) ]]; then
        INSTANCE_NAME="validator-audius-${BASH_REMATCH[1]}"
    else
        INSTANCE_NAME="$_raw_hostname"
    fi
fi
CHAIN="audius"

# Validate AMP config
if [[ -z "$AMP_WORKSPACE_ID" ]]; then
    log_error "AMP_WORKSPACE_ID not set"
    echo ""
    echo "Usage:"
    echo "  export AMP_WORKSPACE_ID='ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
    echo "  export AMP_REGION='us-east-1'"
    echo "  export INSTANCE_NAME='audius-creator-1'           # optional"
    echo "  export AUDIUS_HOSTNAME='audius-creator-1.example.com'  # optional, auto-detected"
    echo "  sudo -E $0"
    exit 1
fi

# =============================================================================
# Step 1: Detect and Verify Audius Node
# =============================================================================

log_info "[Step 1/4] Detecting Audius node..."

# Auto-detect Docker container name
if [[ -z "$AUDIUS_DOCKER_CONTAINER" ]]; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^my-node$"; then
        AUDIUS_DOCKER_CONTAINER="my-node"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "audius|openaudio"; then
        AUDIUS_DOCKER_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "audius|openaudio" | head -1)
    fi
fi

if [[ -n "$AUDIUS_DOCKER_CONTAINER" ]]; then
    log_ok "Found Docker container: ${AUDIUS_DOCKER_CONTAINER}"
else
    log_warn "No Audius Docker container detected"
    log_info "Set AUDIUS_DOCKER_CONTAINER if using a custom container name"
fi

# Auto-detect hostname (needed for HTTPS SNI)
if [[ -z "$AUDIUS_HOSTNAME" ]]; then
    # Try to get hostname from Docker container environment
    if [[ -n "$AUDIUS_DOCKER_CONTAINER" ]]; then
        AUDIUS_HOSTNAME=$(docker inspect "$AUDIUS_DOCKER_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E "^(nodeEndpoint|audius_delegate_owner_wallet_hostname|creatorNodeEndpoint|AUDIUS_HOST|HOST)=" | head -1 | cut -d'=' -f2- | sed 's|https://||;s|http://||;s|/.*||' || echo "")
    fi

    # Try to get from health check response directly using IP
    if [[ -z "$AUDIUS_HOSTNAME" ]] && [[ -n "$AUDIUS_DOCKER_CONTAINER" ]]; then
        local_ip=$(docker inspect "$AUDIUS_DOCKER_CONTAINER" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
        if [[ -n "$local_ip" ]]; then
            AUDIUS_HOSTNAME=$(curl -sk --max-time 5 "http://${local_ip}/health-check" 2>/dev/null | grep -o '"hostname"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
            if [[ -z "$AUDIUS_HOSTNAME" ]]; then
                AUDIUS_HOSTNAME=$(curl -sk --max-time 5 "http://${local_ip}/health-check" 2>/dev/null | grep -o '"endpoint"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's|https://||;s|http://||;s|/.*||' || echo "")
            fi
        fi
    fi

    # Fallback: try system hostname
    if [[ -z "$AUDIUS_HOSTNAME" ]]; then
        AUDIUS_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
    fi
fi

log_info "Node hostname: ${AUDIUS_HOSTNAME}"

# Build the health check curl command (HTTPS with SNI via --resolve)
HEALTH_CHECK_CMD="curl -sk --max-time 10 --resolve ${AUDIUS_HOSTNAME}:443:127.0.0.1 https://${AUDIUS_HOSTNAME}/health-check"

# Verify health endpoint
HEALTH_RESPONSE=""
HEALTH_RESPONSE=$(eval "$HEALTH_CHECK_CMD" 2>/dev/null || echo "")

if [[ -n "$HEALTH_RESPONSE" ]] && echo "$HEALTH_RESPONSE" | grep -q '"ready"'; then
    log_ok "Health endpoint responding via HTTPS"

    # Extract info from response
    node_version=$(echo "$HEALTH_RESPONSE" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
    node_type=$(echo "$HEALTH_RESPONSE" | grep -o '"node_type"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
    node_endpoint=$(echo "$HEALTH_RESPONSE" | grep -o '"endpoint"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")

    log_info "Version:  ${node_version}"
    log_info "Type:     ${node_type}"
    log_info "Endpoint: ${node_endpoint}"
else
    log_warn "Health endpoint not responding"
    log_info "Collector will retry when node becomes available"
fi

echo ""
echo "Configuration:"
echo "  AMP Workspace:     ${AMP_WORKSPACE_ID}"
echo "  AMP Region:        ${AMP_REGION}"
echo "  Instance:          ${INSTANCE_NAME}"
echo "  Chain:             ${CHAIN}"
echo "  Node Hostname:     ${AUDIUS_HOSTNAME}"
echo "  Docker Container:  ${AUDIUS_DOCKER_CONTAINER:-none}"
echo "  Collector Port:    ${COLLECTOR_PORT}"
echo "  node_exporter:     ${NODE_EXPORTER_PORT}"
echo ""

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
# Step 3: Install Audius Collector (custom metrics)
# =============================================================================

log_info "[Step 3/4] Installing Audius metrics collector..."

# Create collector directory
mkdir -p /opt/audius-collector

# Create the collector script
cat > /opt/audius-collector/collector.sh <<'COLLECTOR_SCRIPT'
#!/bin/bash
#
# Audius Metrics Collector (go-openaudio)
#
# Collects metrics from the /health-check endpoint of an Audius node
# running openaudio/go-openaudio. The endpoint returns a rich JSON with:
#   - core: chain_info, live status, node_info, peers
#   - process_info: states of internal processes
#   - resource_info: cpu, memory, disk, db sizes
#   - storage_info: disk capacity and usage
#   - sync_info: sync status
#   - data: version, diskHasSpace
#   - storage: mediorum path size/used, healthy, database size
#
# Exposes metrics in Prometheus format via a simple HTTP server.
#

set -euo pipefail

AUDIUS_HOSTNAME="${AUDIUS_HOSTNAME:-localhost}"
LISTEN_PORT="${LISTEN_PORT:-9106}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-15}"

# Metrics file
METRICS_FILE="/tmp/audius_collector_metrics.prom"
METRICS_FILE_TMP="/tmp/audius_collector_metrics.prom.tmp"

# External data cache (refreshed every 5 minutes)
EXTERNAL_DATA_INTERVAL=300
CACHED_LATEST_VERSION=""
CACHED_NETWORK_HEIGHT=""
LAST_EXTERNAL_FETCH=0

# Public Audius peers for network height reference
NETWORK_HEIGHT_PEERS=(
    "https://creatornode.audius.co"
    "https://cn1.mainnet.audiusindex.org"
    "https://cn2.mainnet.audiusindex.org"
    "https://creatornode3.audius.co"
)

# Helper: extract JSON value by key (works for string, number, boolean)
# For deeply nested keys, caller must pre-filter the JSON context
json_val() {
    local key="$1"
    local json="$2"
    # Match "key": "string_value" or "key": number or "key": true/false
    echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[\"]*[^,}\"]*" | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '"'
}

# Fetch network height from public peers
fetch_network_height() {
    local max_height=0
    for peer_url in "${NETWORK_HEIGHT_PEERS[@]}"; do
        local peer_json
        peer_json=$(curl -sk --max-time 5 "${peer_url}/health-check" 2>/dev/null || echo "{}")
        if [[ -n "$peer_json" ]] && [[ "$peer_json" != "{}" ]]; then
            local h
            h=$(json_val "current_height" "$peer_json")
            if [[ -n "$h" ]] && [[ "$h" =~ ^[0-9]+$ ]] && [[ "$h" -gt "$max_height" ]]; then
                max_height=$h
            fi
        fi
    done
    if [[ "$max_height" -gt 0 ]]; then
        echo "$max_height"
    fi
}

# Fetch latest version from GitHub and network height from public peers
fetch_external_data() {
    local now=$(date +%s)
    local cache_age=$((now - LAST_EXTERNAL_FETCH))

    if [[ $cache_age -lt $EXTERNAL_DATA_INTERVAL ]] && [[ -n "$CACHED_LATEST_VERSION" ]]; then
        return 0
    fi

    local github_response
    github_response=$(curl -s --max-time 10 \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/AudiusProject/audius-protocol/releases/latest" 2>/dev/null || echo '{}')

    if echo "$github_response" | grep -q '"tag_name"'; then
        CACHED_LATEST_VERSION=$(echo "$github_response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^v//' || echo "unknown")
    fi

    local new_height
    new_height=$(fetch_network_height)
    if [[ -n "$new_height" ]]; then
        CACHED_NETWORK_HEIGHT="$new_height"
    fi

    LAST_EXTERNAL_FETCH=$now
}

collect_metrics() {
    local timestamp=$(date +%s)

    # Fetch external data (rate-limited)
    fetch_external_data

    cat > "$METRICS_FILE_TMP" <<EOF
# HELP audius_collector_scrape_timestamp_seconds Unix timestamp of last scrape
# TYPE audius_collector_scrape_timestamp_seconds gauge
audius_collector_scrape_timestamp_seconds ${timestamp}

EOF

    # =========================================================================
    # Fetch health-check (HTTPS with SNI via --resolve)
    # =========================================================================
    local health_json
    health_json=$(curl -sk --max-time 10 \
        --resolve "${AUDIUS_HOSTNAME}:443:127.0.0.1" \
        "https://${AUDIUS_HOSTNAME}/health-check" 2>/dev/null || echo "{}")

    local scrape_success=1
    if [[ "$health_json" == "{}" ]] || [[ -z "$health_json" ]]; then
        scrape_success=0
    fi

    # =========================================================================
    # Core: readiness, liveness, chain info
    # =========================================================================
    local is_ready=0
    if echo "$health_json" | grep -q '"ready"[[:space:]]*:[[:space:]]*true'; then
        is_ready=1
    fi

    local core_live=0
    if echo "$health_json" | grep -q '"live"[[:space:]]*:[[:space:]]*true'; then
        core_live=1
    fi

    local is_synced=0
    if echo "$health_json" | grep -q '"synced"[[:space:]]*:[[:space:]]*true'; then
        is_synced=1
    fi

    # chain_info
    local current_height
    current_height=$(json_val "current_height" "$health_json")
    current_height="${current_height:-0}"

    local total_tx_count
    total_tx_count=$(json_val "total_tx_count" "$health_json")
    total_tx_count="${total_tx_count:-0}"

    # node_info
    local node_type
    node_type=$(json_val "node_type" "$health_json")
    node_type="${node_type:-unknown}"

    local endpoint
    endpoint=$(json_val "endpoint" "$health_json")
    endpoint="${endpoint:-unknown}"

    local eth_address
    eth_address=$(json_val "eth_address" "$health_json")
    eth_address="${eth_address:-unknown}"

    # version (from data.version)
    local node_version
    node_version=$(json_val "version" "$health_json")
    node_version="${node_version:-unknown}"

    # git commit
    local git_commit
    git_commit=$(json_val "git" "$health_json")
    git_commit="${git_commit:-unknown}"

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP audius_node_ready Whether the node is ready (1=ready, 0=not ready)
# TYPE audius_node_ready gauge
audius_node_ready ${is_ready}

# HELP audius_core_live Whether the core is live (1=live, 0=down)
# TYPE audius_core_live gauge
audius_core_live ${core_live}

# HELP audius_node_synced Whether node is synced (1=synced, 0=syncing)
# TYPE audius_node_synced gauge
audius_node_synced ${is_synced}

# HELP audius_node_info Audius node metadata
# TYPE audius_node_info gauge
audius_node_info{version="${node_version}",node_type="${node_type}",endpoint="${endpoint}",eth_address="${eth_address}",git="${git_commit}"} 1

# HELP audius_chain_height Current chain block height
# TYPE audius_chain_height gauge
audius_chain_height ${current_height}

# HELP audius_chain_tx_count Total transaction count on chain
# TYPE audius_chain_tx_count gauge
audius_chain_tx_count ${total_tx_count}

EOF

    # =========================================================================
    # Peers
    # =========================================================================
    local peer_count=0
    peer_count=$(echo "$health_json" | grep -o '"comet_address"' | wc -l | tr -d ' ')
    # Subtract 1 for own node's comet_address in node_info
    if [[ "$peer_count" -gt 0 ]]; then
        peer_count=$((peer_count - 1))
    fi

    local healthy_peers=0
    healthy_peers=$(echo "$health_json" | grep -o '"connectrpc_healthy"[[:space:]]*:[[:space:]]*true' | wc -l | tr -d ' ')

    local p2p_connected_peers=0
    p2p_connected_peers=$(echo "$health_json" | grep -o '"p2p_connected"[[:space:]]*:[[:space:]]*true' | wc -l | tr -d ' ')

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP audius_peers_total Total number of known peers
# TYPE audius_peers_total gauge
audius_peers_total ${peer_count}

# HELP audius_peers_healthy Number of healthy peers (connectrpc_healthy)
# TYPE audius_peers_healthy gauge
audius_peers_healthy ${healthy_peers}

# HELP audius_peers_p2p_connected Number of P2P connected peers
# TYPE audius_peers_p2p_connected gauge
audius_peers_p2p_connected ${p2p_connected_peers}

EOF

    # =========================================================================
    # Resource Info (cpu, memory, disk, database)
    # =========================================================================
    local cpu_usage
    cpu_usage=$(json_val "cpu_usage" "$health_json")
    cpu_usage="${cpu_usage:-0}"

    local mem_usage
    mem_usage=$(json_val "mem_usage" "$health_json")
    mem_usage="${mem_usage:-0}"

    local mem_size
    mem_size=$(json_val "mem_size" "$health_json")
    mem_size="${mem_size:-0}"

    local disk_usage
    disk_usage=$(json_val "disk_usage" "$health_json")
    disk_usage="${disk_usage:-0}"

    local disk_free
    disk_free=$(json_val "disk_free" "$health_json")
    disk_free="${disk_free:-0}"

    local chain_size
    chain_size=$(json_val "chain_size" "$health_json")
    chain_size="${chain_size:-0}"

    local db_size
    db_size=$(json_val "db_size" "$health_json")
    db_size="${db_size:-0}"

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP audius_resource_cpu_usage_percent CPU usage percentage reported by node
# TYPE audius_resource_cpu_usage_percent gauge
audius_resource_cpu_usage_percent ${cpu_usage}

# HELP audius_resource_mem_usage_bytes Memory usage in bytes
# TYPE audius_resource_mem_usage_bytes gauge
audius_resource_mem_usage_bytes ${mem_usage}

# HELP audius_resource_mem_total_bytes Total memory in bytes
# TYPE audius_resource_mem_total_bytes gauge
audius_resource_mem_total_bytes ${mem_size}

# HELP audius_resource_disk_usage_bytes Disk usage in bytes
# TYPE audius_resource_disk_usage_bytes gauge
audius_resource_disk_usage_bytes ${disk_usage}

# HELP audius_resource_disk_free_bytes Disk free space in bytes
# TYPE audius_resource_disk_free_bytes gauge
audius_resource_disk_free_bytes ${disk_free}

# HELP audius_resource_chain_size_bytes Chain data size in bytes
# TYPE audius_resource_chain_size_bytes gauge
audius_resource_chain_size_bytes ${chain_size}

# HELP audius_resource_db_size_bytes Database size in bytes
# TYPE audius_resource_db_size_bytes gauge
audius_resource_db_size_bytes ${db_size}

EOF

    # =========================================================================
    # Storage Info (mediorum / content storage)
    # =========================================================================
    local disk_has_space=0
    if echo "$health_json" | grep -q '"diskHasSpace"[[:space:]]*:[[:space:]]*true'; then
        disk_has_space=1
    elif echo "$health_json" | grep -q '"disk_has_space"[[:space:]]*:[[:space:]]*true'; then
        disk_has_space=1
    fi

    local storage_disk_total
    storage_disk_total=$(json_val "disk_total" "$health_json")
    storage_disk_total="${storage_disk_total:-0}"

    local storage_disk_used
    storage_disk_used=$(json_val "disk_used" "$health_json")
    storage_disk_used="${storage_disk_used:-0}"

    local mediorum_path_size
    mediorum_path_size=$(json_val "mediorumPathSize" "$health_json")
    mediorum_path_size="${mediorum_path_size:-0}"

    local mediorum_path_used
    mediorum_path_used=$(json_val "mediorumPathUsed" "$health_json")
    mediorum_path_used="${mediorum_path_used:-0}"

    local database_size
    database_size=$(json_val "databaseSize" "$health_json")
    database_size="${database_size:-0}"

    local storage_healthy=0
    if echo "$health_json" | grep -q '"healthy"[[:space:]]*:[[:space:]]*true'; then
        storage_healthy=1
    fi

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP audius_storage_disk_has_space Whether disk has space (1=yes, 0=no)
# TYPE audius_storage_disk_has_space gauge
audius_storage_disk_has_space ${disk_has_space}

# HELP audius_storage_disk_total_bytes Total disk capacity in bytes
# TYPE audius_storage_disk_total_bytes gauge
audius_storage_disk_total_bytes ${storage_disk_total}

# HELP audius_storage_disk_used_bytes Disk used in bytes
# TYPE audius_storage_disk_used_bytes gauge
audius_storage_disk_used_bytes ${storage_disk_used}

# HELP audius_storage_mediorum_total_bytes Mediorum storage total in bytes
# TYPE audius_storage_mediorum_total_bytes gauge
audius_storage_mediorum_total_bytes ${mediorum_path_size}

# HELP audius_storage_mediorum_used_bytes Mediorum storage used in bytes
# TYPE audius_storage_mediorum_used_bytes gauge
audius_storage_mediorum_used_bytes ${mediorum_path_used}

# HELP audius_storage_database_size_bytes Storage database size in bytes
# TYPE audius_storage_database_size_bytes gauge
audius_storage_database_size_bytes ${database_size}

# HELP audius_storage_healthy Whether storage subsystem is healthy (1=yes, 0=no)
# TYPE audius_storage_healthy gauge
audius_storage_healthy ${storage_healthy}

EOF

    # =========================================================================
    # Mempool
    # =========================================================================
    local mempool_tx_count
    mempool_tx_count=$(json_val "tx_count" "$health_json")
    mempool_tx_count="${mempool_tx_count:-0}"

    local mempool_tx_size
    mempool_tx_size=$(json_val "tx_size" "$health_json")
    mempool_tx_size="${mempool_tx_size:-0}"

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP audius_mempool_tx_count Number of transactions in mempool
# TYPE audius_mempool_tx_count gauge
audius_mempool_tx_count ${mempool_tx_count}

# HELP audius_mempool_tx_size_bytes Size of transactions in mempool (bytes)
# TYPE audius_mempool_tx_size_bytes gauge
audius_mempool_tx_size_bytes ${mempool_tx_size}

EOF

    # =========================================================================
    # Pruning Info
    # =========================================================================
    local current_retain_height
    current_retain_height=$(json_val "current_retain_height" "$health_json")
    current_retain_height="${current_retain_height:-0}"

    local earliest_height
    earliest_height=$(json_val "earliest_height" "$health_json")
    earliest_height="${earliest_height:-0}"

    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP audius_pruning_retain_height Current retain height for pruning
# TYPE audius_pruning_retain_height gauge
audius_pruning_retain_height ${current_retain_height}

# HELP audius_pruning_earliest_height Earliest block height available
# TYPE audius_pruning_earliest_height gauge
audius_pruning_earliest_height ${earliest_height}

EOF

    # =========================================================================
    # External Data (latest version from GitHub)
    # =========================================================================
    if [[ -n "$CACHED_LATEST_VERSION" ]] && [[ "$CACHED_LATEST_VERSION" != "unknown" ]]; then
        cat >> "$METRICS_FILE_TMP" <<EOF
# HELP audius_latest_version_info Latest Audius protocol version from GitHub
# TYPE audius_latest_version_info gauge
audius_latest_version_info{version="${CACHED_LATEST_VERSION}"} 1

EOF
    fi

    if [[ -n "$CACHED_NETWORK_HEIGHT" ]] && [[ "$CACHED_NETWORK_HEIGHT" -gt 0 ]]; then
        cat >> "$METRICS_FILE_TMP" <<EOF
# HELP audius_network_height Network chain height from public peers
# TYPE audius_network_height gauge
audius_network_height ${CACHED_NETWORK_HEIGHT}

EOF
    fi

    # =========================================================================
    # Collector metadata
    # =========================================================================
    cat >> "$METRICS_FILE_TMP" <<EOF
# HELP audius_collector_scrape_success Whether the last scrape was successful (1=yes, 0=no)
# TYPE audius_collector_scrape_success gauge
audius_collector_scrape_success ${scrape_success}
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
    echo "Starting Audius metrics collector (go-openaudio)..."
    echo "  Hostname:     ${AUDIUS_HOSTNAME}"
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

chmod +x /opt/audius-collector/collector.sh

# Create systemd service for collector
cat > /etc/systemd/system/audius-collector.service <<EOF
[Unit]
Description=Audius Metrics Collector
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment="AUDIUS_HOSTNAME=${AUDIUS_HOSTNAME}"
Environment="LISTEN_PORT=${COLLECTOR_PORT}"
Environment="SCRAPE_INTERVAL=15"
ExecStart=/opt/audius-collector/collector.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable audius-collector
systemctl restart audius-collector

sleep 3

if systemctl is-active --quiet audius-collector; then
    log_ok "Audius collector running on :${COLLECTOR_PORT}"
else
    log_warn "Audius collector may have issues, check: journalctl -u audius-collector -f"
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
# Grafana Agent configuration - Audius Node Monitoring
# Generated: $(date -Iseconds)
# Node: ${AUDIUS_HOSTNAME}
# Pushes metrics to Amazon Managed Prometheus

metrics:
  global:
    scrape_interval: 15s
    external_labels:
      instance: '${INSTANCE_NAME}'
      chain: '${CHAIN}'
      env: 'production'

  configs:
    - name: audius_metrics
      scrape_configs:
        # Custom collector metrics (health, sync, storage, version)
        - job_name: 'audius_collector'
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

    # Create credentials refresh script
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
echo "  │   Audius Node       │"
echo "  │   (go-openaudio)    │──┐"
echo "  └─────────────────────┘  │"
echo "                           │"
echo "  ┌─────────────────────┐  │     ┌─────────────────┐     ┌─────────┐"
echo "  │  audius-collector   │  ├────▶│  Grafana Agent  │────▶│   AMP   │"
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
echo "  Core:"
echo "    - audius_node_ready                    # Node readiness"
echo "    - audius_core_live                     # Core liveness"
echo "    - audius_node_synced                   # Sync status"
echo "    - audius_node_info                     # Version, type, endpoint metadata"
echo "    - audius_chain_height                  # Current chain block height"
echo "    - audius_chain_tx_count                # Total transaction count"
echo ""
echo "  Peers:"
echo "    - audius_peers_total                   # Known peers"
echo "    - audius_peers_healthy                 # Healthy peers (connectrpc)"
echo "    - audius_peers_p2p_connected           # P2P connected peers"
echo ""
echo "  Resources:"
echo "    - audius_resource_cpu_usage_percent    # CPU usage %"
echo "    - audius_resource_mem_usage_bytes      # Memory usage"
echo "    - audius_resource_disk_usage_bytes     # Disk usage"
echo "    - audius_resource_disk_free_bytes      # Disk free"
echo "    - audius_resource_db_size_bytes        # Database size"
echo "    - audius_resource_chain_size_bytes     # Chain data size"
echo ""
echo "  Storage:"
echo "    - audius_storage_disk_total_bytes      # Disk total"
echo "    - audius_storage_disk_used_bytes       # Disk used"
echo "    - audius_storage_mediorum_total_bytes  # Mediorum total"
echo "    - audius_storage_mediorum_used_bytes   # Mediorum used"
echo "    - audius_storage_database_size_bytes   # Storage DB size"
echo "    - audius_storage_disk_has_space        # Has space flag"
echo "    - audius_storage_healthy               # Storage health"
echo ""
echo "  Other:"
echo "    - audius_mempool_tx_count              # Mempool tx count"
echo "    - audius_pruning_retain_height         # Pruning retain height"
echo "    - audius_pruning_earliest_height       # Earliest available block"
echo "    - audius_latest_version_info           # Latest version from GitHub"
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
echo "  systemctl status audius-collector"
echo "  systemctl status node_exporter"
echo ""
echo "  # View logs"
echo "  journalctl -u grafana-agent -f"
echo "  journalctl -u audius-collector -f"
echo ""
echo "  # Test metrics endpoints"
echo "  curl -s localhost:${COLLECTOR_PORT}/metrics"
echo "  curl -s localhost:${NODE_EXPORTER_PORT}/metrics | head -20"
echo ""
echo "  # After 1-2 minutes, verify in AMP/AMG:"
echo "  #   audius_node_ready"
echo "  #   audius_chain_height"
echo "  #   audius_node_synced"
echo ""
