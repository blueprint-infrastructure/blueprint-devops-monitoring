#!/bin/bash
#
# Canton Node Monitoring Installation Script
#
# Installs monitoring tools for a Canton / Splice Validator node:
# 1. node_exporter  - system metrics (CPU, memory, disk, network)
#                     NOTE: already running on this node; install is skipped
# 2. canton-collector - custom metrics (container health, service liveness)
# 3. Grafana Agent  - push all metrics to Amazon Managed Prometheus (AMP)
#
# Target node: validator-cc-va-1 (i-00eb537b266dea011, us-east-1)
#
# What runs on the node:
#   - Canton Enterprise 3.4.12-SNAPSHOT (Java, ~2 GB)
#   - Splice Validator node (Java, ~1.9 GB)
#   - 10 Docker containers: canton-participant (:7575), validator-app (:5003),
#     wallet-web-ui, ans-web-ui, backend (:8081), nginx (:6781), mcp (:3001),
#     postgres x2
#   - Caddy on 80/443/8443
#
# Legacy monitoring context:
#   The legacy Prometheus (3.99.231.163) scrapes canton.theblueprint.xyz:9100
#   every 30 s for node_exporter metrics only. No custom canton exporter was
#   found on that server. This script supersedes that by pushing directly to AMP.
#
# Prerequisites:
#   - EC2 IAM role with AmazonPrometheusRemoteWriteAccess
#   - Docker installed and running (docker ps must work)
#

set -euo pipefail

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
echo -e "${BLUE}   Canton Node Monitoring Installation${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

# =============================================================================
# Configuration
# =============================================================================

# AMP config (required)
AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-ws-fdcbcf55-ed2c-4069-adad-c385e068d992}"
AMP_REGION="${AMP_REGION:-us-east-1}"

# Canton service endpoints
# NOTE: ports 7575 (participant) and 5003 (validator) are Docker-internal only;
# liveness is checked via docker inspect, not curl.
CANTON_BACKEND_PORT="${CANTON_BACKEND_PORT:-8081}"           # cantonblueprint-backend (mapped to 127.0.0.1:8081)

# Collector config
COLLECTOR_PORT="${COLLECTOR_PORT:-9101}"

# node_exporter
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.7.0}"

# Instance identity
INSTANCE_NAME="${INSTANCE_NAME:-$(hostname)}"
EC2_INSTANCE_ID=$(curl -sf --max-time 2 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null \
    || grep -o '"ManagedInstanceID":"[^"]*"' /var/lib/amazon/ssm/registration 2>/dev/null | cut -d'"' -f4 \
    || hostname)
CHAIN="canton"

# Validate AMP config
if [[ -z "$AMP_WORKSPACE_ID" ]]; then
    log_error "AMP_WORKSPACE_ID not set"
    echo ""
    echo "Usage:"
    echo "  export AMP_WORKSPACE_ID='ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
    echo "  export AMP_REGION='us-east-1'"
    echo "  export INSTANCE_NAME='validator-cc-va-1'  # optional"
    echo "  sudo -E $0"
    exit 1
fi

echo "Configuration:"
echo "  AMP Workspace:       ${AMP_WORKSPACE_ID}"
echo "  AMP Region:          ${AMP_REGION}"
echo "  Instance:            ${INSTANCE_NAME}"
echo "  Instance ID:         ${EC2_INSTANCE_ID}"
echo "  Chain:               ${CHAIN}"
echo "  Collector Port:      ${COLLECTOR_PORT}"
echo "  node_exporter Port:  ${NODE_EXPORTER_PORT}"
echo ""

# =============================================================================
# Step 1: Verify Canton is running
# =============================================================================

log_info "[Step 1/4] Verifying Canton node..."

# Check that Docker is available and containers are up
if command -v docker >/dev/null 2>&1; then
    TOTAL=$(docker ps -q 2>/dev/null | wc -l || echo 0)
    CANTON=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c canton || true)
    SPLICE=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c splice || true)
    log_ok "Docker running — ${TOTAL} containers total, ${CANTON} canton, ${SPLICE} splice"
else
    log_warn "Docker not found or not accessible — container metrics will not be available"
fi

# Check Caddy (primary proxy) as overall health signal
if systemctl is-active --quiet caddy 2>/dev/null; then
    log_ok "Caddy proxy is running"
else
    log_warn "Caddy is not running — canton services may be down"
fi

# =============================================================================
# Step 2: Install node_exporter (skip if already running)
# =============================================================================

log_info "[Step 2/4] Checking node_exporter..."

if command -v node_exporter >/dev/null 2>&1 || systemctl is-active --quiet node_exporter 2>/dev/null; then
    log_ok "node_exporter already installed and running on :${NODE_EXPORTER_PORT} — skipping"
else
    log_info "Installing node_exporter v${NODE_EXPORTER_VERSION}..."

    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) log_error "Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    cd /tmp
    curl -sSLO "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    tar xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    mv "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/
    rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}"*

    useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true

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

# Verify
sleep 2
if curl -sf "http://localhost:${NODE_EXPORTER_PORT}/metrics" >/dev/null 2>&1; then
    log_ok "node_exporter responding on :${NODE_EXPORTER_PORT}"
else
    log_error "node_exporter not responding on :${NODE_EXPORTER_PORT}"
    exit 1
fi

# =============================================================================
# Step 3: Install Canton Collector (custom metrics)
# =============================================================================

log_info "[Step 3/4] Installing Canton metrics collector..."

mkdir -p /opt/canton-collector

cat > /opt/canton-collector/collector.sh <<'COLLECTOR_SCRIPT'
#!/bin/bash
#
# Canton Metrics Collector
# Collects health and liveness metrics for Canton / Splice Validator services.
# Exposes metrics in Prometheus format on LISTEN_PORT via a Python HTTP server.
#
# Metrics emitted:
#   canton_containers_total          - total running Docker containers
#   canton_containers_healthy        - containers with health status = healthy
#   canton_containers_unhealthy      - containers with health status = unhealthy
#   canton_participant_up            - splice-validator-participant-1 running & not unhealthy (0/1)
#   canton_validator_up              - splice-validator-validator-1 running & not unhealthy (0/1)
#   canton_backend_up                - cantonblueprint-backend actuator health (0/1)
#   canton_collector_scrape_success  - did the last scrape succeed (0/1)
#   canton_collector_scrape_timestamp_seconds - unix timestamp of last scrape
#
# NOTE: ports 7575 (participant) and 5003 (validator) are Docker-internal only
# (no host port mapping). Liveness is checked via `docker inspect` container state,
# not HTTP curl. cantonblueprint-backend IS mapped to 127.0.0.1:8081.
#

LISTEN_PORT="${LISTEN_PORT:-9101}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-15}"
CANTON_BACKEND_PORT="${CANTON_BACKEND_PORT:-8081}"

METRICS_FILE="/tmp/canton_collector_metrics.prom"
METRICS_FILE_TMP="/tmp/canton_collector_metrics.prom.tmp"

collect_metrics() {
    local timestamp scrape_ok=1
    timestamp=$(date +%s)

    {
        echo "# HELP canton_collector_scrape_timestamp_seconds Unix timestamp of last scrape"
        echo "# TYPE canton_collector_scrape_timestamp_seconds gauge"
        echo "canton_collector_scrape_timestamp_seconds ${timestamp}"
        echo ""

        # =====================================================================
        # Docker container counts
        # =====================================================================
        local total=0 healthy=0 unhealthy=0
        if command -v docker >/dev/null 2>&1; then
            total=$(docker ps -q 2>/dev/null | wc -l || echo 0)
            healthy=$(docker ps -q 2>/dev/null \
                | xargs -r docker inspect --format '{{.State.Health.Status}}' 2>/dev/null \
                | grep -c '^healthy$' || true)
            unhealthy=$(docker ps -q 2>/dev/null \
                | xargs -r docker inspect --format '{{.State.Health.Status}}' 2>/dev/null \
                | grep -c '^unhealthy$' || true)
        fi

        echo "# HELP canton_containers_total Total running Docker containers"
        echo "# TYPE canton_containers_total gauge"
        echo "canton_containers_total ${total}"
        echo ""
        echo "# HELP canton_containers_healthy Containers with health status = healthy"
        echo "# TYPE canton_containers_healthy gauge"
        echo "canton_containers_healthy ${healthy}"
        echo ""
        echo "# HELP canton_containers_unhealthy Containers with health status = unhealthy"
        echo "# TYPE canton_containers_unhealthy gauge"
        echo "canton_containers_unhealthy ${unhealthy}"
        echo ""

        # =====================================================================
        # Per-container liveness via docker inspect
        # Ports 7575/5003 are Docker-internal only (no host mapping).
        # cantonblueprint-backend is mapped to 127.0.0.1:8081.
        # =====================================================================

        # splice-validator-participant-1: running + not unhealthy
        local participant_up=0 p_state p_health
        p_state=$(docker inspect --format '{{.State.Running}}' splice-validator-participant-1 2>/dev/null || echo "false")
        p_health=$(docker inspect --format '{{.State.Health.Status}}' splice-validator-participant-1 2>/dev/null || echo "none")
        if [[ "$p_state" == "true" && "$p_health" != "unhealthy" ]]; then participant_up=1; fi
        echo "# HELP canton_participant_up splice-validator-participant-1 running and not unhealthy (1=up)"
        echo "# TYPE canton_participant_up gauge"
        echo "canton_participant_up ${participant_up}"
        echo ""

        # splice-validator-validator-1: running + not unhealthy
        local validator_up=0 v_state v_health
        v_state=$(docker inspect --format '{{.State.Running}}' splice-validator-validator-1 2>/dev/null || echo "false")
        v_health=$(docker inspect --format '{{.State.Health.Status}}' splice-validator-validator-1 2>/dev/null || echo "none")
        if [[ "$v_state" == "true" && "$v_health" != "unhealthy" ]]; then validator_up=1; fi
        echo "# HELP canton_validator_up splice-validator-validator-1 running and not unhealthy (1=up)"
        echo "# TYPE canton_validator_up gauge"
        echo "canton_validator_up ${validator_up}"
        echo ""

        # cantonblueprint-backend Spring Boot actuator (mapped to 127.0.0.1:8081)
        local backend_up=0
        if curl -sf --max-time 5 "http://127.0.0.1:${CANTON_BACKEND_PORT}/actuator/health" >/dev/null 2>&1; then
            backend_up=1
        fi
        echo "# HELP canton_backend_up cantonblueprint-backend Spring Boot actuator health (1=up)"
        echo "# TYPE canton_backend_up gauge"
        echo "canton_backend_up ${backend_up}"
        echo ""

        echo "# HELP canton_collector_scrape_success Whether last scrape succeeded (1=yes)"
        echo "# TYPE canton_collector_scrape_success gauge"
        echo "canton_collector_scrape_success ${scrape_ok}"

    } > "$METRICS_FILE_TMP" 2>/dev/null || {
        echo "canton_collector_scrape_success 0" > "$METRICS_FILE_TMP"
    }

    mv "$METRICS_FILE_TMP" "$METRICS_FILE"
}

# Python HTTP server — handles HTTP/1.1 keep-alive properly.
# nc-based servers cause "Unsolicited response on idle HTTP channel" in Grafana Agent logs.
start_http_server() {
    LISTEN_PORT="$LISTEN_PORT" python3 -c "
import http.server, os
PORT = int(os.environ.get('LISTEN_PORT', 9101))
METRICS_FILE = '/tmp/canton_collector_metrics.prom'
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            body = open(METRICS_FILE,'rb').read()
        except FileNotFoundError:
            body = b'# No metrics yet\n'
        self.send_response(200)
        self.send_header('Content-Type','text/plain; version=0.0.4; charset=utf-8')
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self,*a): pass
http.server.HTTPServer(('',PORT),Handler).serve_forever()
" &
}

main() {
    echo "Starting Canton metrics collector..."
    echo "  Listen port:     ${LISTEN_PORT}"
    echo "  Scrape interval: ${SCRAPE_INTERVAL}s"

    collect_metrics || true
    start_http_server

    while true; do
        sleep "$SCRAPE_INTERVAL"
        collect_metrics || true
    done
}

main "$@"
COLLECTOR_SCRIPT

chmod +x /opt/canton-collector/collector.sh

# Create systemd service
cat > /etc/systemd/system/canton-collector.service <<EOF
[Unit]
Description=Canton Metrics Collector
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=simple
Environment="LISTEN_PORT=${COLLECTOR_PORT}"
Environment="SCRAPE_INTERVAL=15"
Environment="CANTON_BACKEND_PORT=${CANTON_BACKEND_PORT}"
ExecStart=/opt/canton-collector/collector.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable canton-collector
systemctl restart canton-collector

sleep 3

if systemctl is-active --quiet canton-collector; then
    log_ok "Canton collector running on :${COLLECTOR_PORT}"
else
    log_warn "Canton collector may have issues — check: journalctl -u canton-collector -f"
fi

# =============================================================================
# Step 4: Install and Configure Grafana Agent
# =============================================================================

log_info "[Step 4/4] Installing Grafana Agent..."

if command -v grafana-agent >/dev/null 2>&1 || systemctl is-active --quiet grafana-agent 2>/dev/null; then
    log_info "Grafana Agent already installed, updating configuration..."
else
    log_info "Adding Grafana APT repository..."

    mkdir -p /etc/apt/keyrings/
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg 2>/dev/null || true

    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | \
        tee /etc/apt/sources.list.d/grafana.list >/dev/null

    apt-get update -qq
    apt-get install -y grafana-agent

    log_ok "Grafana Agent installed"
fi

log_info "Configuring Grafana Agent..."

cat > /etc/grafana-agent.yaml <<EOF
# Grafana Agent configuration - Canton Node Monitoring
# Generated: $(date -Iseconds)
# Pushes metrics to Amazon Managed Prometheus

metrics:
  global:
    scrape_interval: 15s
    external_labels:
      instance: '${INSTANCE_NAME}'
      instance_id: '${EC2_INSTANCE_ID}'
      chain: '${CHAIN}'
      env: 'production'

  configs:
    - name: canton_metrics
      scrape_configs:
        # Canton custom collector (container health, service liveness)
        - job_name: 'canton_collector'
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

chmod 644 /etc/grafana-agent.yaml
chown root:grafana-agent /etc/grafana-agent.yaml 2>/dev/null || true

# Allow grafana-agent to run docker commands for container metrics
if getent group docker >/dev/null 2>&1; then
    usermod -aG docker grafana-agent 2>/dev/null || true
    log_info "Added grafana-agent to docker group"
fi

# Fix port conflict (grafana-agent default 9090 conflicts with Prometheus)
if [[ -f /etc/default/grafana-agent ]]; then
    sed -i 's/127.0.0.1:9090/127.0.0.1:12345/g' /etc/default/grafana-agent
    sed -i 's/127.0.0.1:9091/127.0.0.1:12346/g' /etc/default/grafana-agent
    log_info "Updated /etc/default/grafana-agent ports to avoid conflicts"
fi

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
echo "  │  canton-collector   │──┐"
echo "  │  :${COLLECTOR_PORT}              │  │     ┌─────────────────┐     ┌─────────┐"
echo "  └─────────────────────┘  ├────▶│  Grafana Agent  │────▶│   AMP   │"
echo "                           │     └─────────────────┘     └─────────┘"
echo "  ┌─────────────────────┐  │"
echo "  │   node_exporter     │──┘"
echo "  │   :${NODE_EXPORTER_PORT}              │"
echo "  └─────────────────────┘"
echo ""
echo "Metrics collected:"
echo ""
echo "  Container Health:"
echo "    - canton_containers_total        # running Docker containers"
echo "    - canton_containers_healthy      # containers with health=healthy"
echo "    - canton_containers_unhealthy    # containers with health=unhealthy"
echo ""
echo "  Service Liveness:"
echo "    - canton_participant_up          # splice-validator-participant-1 (docker inspect)"
echo "    - canton_validator_up            # splice-validator-validator-1 (docker inspect)"
echo "    - canton_backend_up              # Blueprint backend :${CANTON_BACKEND_PORT}/actuator/health"
echo ""
echo "  System Resources (node_exporter):"
echo "    - node_cpu_seconds_total"
echo "    - node_memory_MemAvailable_bytes"
echo "    - node_filesystem_avail_bytes"
echo "    - node_network_receive_bytes_total"
echo ""
echo "Verify installation:"
echo ""
echo "  systemctl status grafana-agent canton-collector node_exporter"
echo "  journalctl -u canton-collector -f"
echo "  curl -s localhost:${COLLECTOR_PORT}/metrics"
echo "  curl -s localhost:${NODE_EXPORTER_PORT}/metrics | head -5"
echo ""
echo "After 1-2 minutes, verify in AMP/AMG:"
echo "  canton_containers_healthy{instance=\"${INSTANCE_NAME}\"}"
echo "  canton_participant_up{instance=\"${INSTANCE_NAME}\"}"
echo "  up{job=\"node_exporter\",chain=\"canton\"}"
echo ""
