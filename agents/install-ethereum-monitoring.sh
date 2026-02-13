#!/bin/bash
#
# Simplified install script - for environments with existing node_exporter
#
# Installs only:
# 1. Grafana Agent (push to AMP)
# 2. Chain collector (custom metrics)
#
# Prerequisites:
# - node_exporter running on :9100
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
echo -e "${BLUE}   Validator Monitoring - Simplified Install (existing stack)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

# =============================================================================
# Configuration
# =============================================================================

# AMP config (required)
AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-}"
AMP_REGION="${AMP_REGION:-us-east-1}"

# Optional config
INSTANCE_NAME="${INSTANCE_NAME:-$(hostname)}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
CHAIN="${1:-ethereum}"

# Validate AMP config
if [[ -z "$AMP_WORKSPACE_ID" ]]; then
    log_error "AMP_WORKSPACE_ID not set"
    echo ""
    echo "Usage:"
    echo "  export AMP_WORKSPACE_ID='ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
    echo "  export AMP_REGION='us-east-1'"
    echo "  sudo -E $0 [ethereum|solana|avalanche]"
    exit 1
fi

echo "Configuration:"
echo "  AMP Workspace: ${AMP_WORKSPACE_ID}"
echo "  AMP Region:    ${AMP_REGION}"
echo "  Instance:      ${INSTANCE_NAME}"
echo "  Chain:         ${CHAIN}"
echo ""

# =============================================================================
# Step 1: Verify Prometheus
# =============================================================================

log_info "[Step 1/3] Verifying Prometheus..."

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
# Step 2: Install Grafana Agent
# =============================================================================

log_info "[Step 2/3] Installing Grafana Agent..."

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

# Check if local Prometheus has all targets
log_info "Checking existing Prometheus configuration..."

PROM_TARGETS=""

if curl -sf "http://localhost:${PROMETHEUS_PORT}/api/v1/targets" >/dev/null 2>&1; then
    PROM_TARGETS=$(curl -s "http://localhost:${PROMETHEUS_PORT}/api/v1/targets" | grep -o '"job":"[^"]*"' | cut -d'"' -f4 | sort -u | tr '\n' ', ')
    log_ok "Found Prometheus on :${PROMETHEUS_PORT}"
    log_info "Prometheus targets: ${PROM_TARGETS}"
else
    log_warn "Prometheus not found on :${PROMETHEUS_PORT}"
fi

# Generate configuration
log_info "Configuring Grafana Agent..."

cat > /etc/grafana-agent.yaml <<EOF
# Grafana Agent configuration - push to Amazon Managed Prometheus
# Generated: $(date -Iseconds)
# Mode: Federation from existing Prometheus
# Prometheus targets: ${PROM_TARGETS}

metrics:
  global:
    scrape_interval: 15s
    external_labels:
      instance: '${INSTANCE_NAME}'
      chain: '${CHAIN}'
      env: 'production'
  
  configs:
    - name: validator_metrics
      scrape_configs:
        # Federate all metrics from existing Prometheus
        - job_name: 'prometheus_federation'
          honor_labels: true
          metrics_path: '/federate'
          params:
            'match[]':
              - '{job=~".+"}'  # All jobs
          static_configs:
            - targets: ['localhost:${PROMETHEUS_PORT}']
          relabel_configs:
            - source_labels: [__address__]
              target_label: prometheus_server
              replacement: '${INSTANCE_NAME}'
          metric_relabel_configs:
            # Add instance label if missing
            - source_labels: [instance]
              target_label: instance
              regex: '(.+)'
              replacement: '${INSTANCE_NAME}'

      remote_write:
        - url: 'https://aps-workspaces.${AMP_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/api/v1/remote_write'
          sigv4:
            region: '${AMP_REGION}'

integrations:
  agent:
    enabled: true
EOF

# Set permissions - grafana-agent user needs to read this
chmod 644 /etc/grafana-agent.yaml
chown root:grafana-agent /etc/grafana-agent.yaml 2>/dev/null || true

# Fix port conflict in /etc/default/grafana-agent (change 9090 to 12345)
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
# Step 3: Summary
# =============================================================================

log_info "[Step 3/3] Configuration summary:"
echo ""
echo "  Mode: Prometheus Federation"
echo "  Source: localhost:${PROMETHEUS_PORT}/federate"
echo "  Destination: AMP (${AMP_WORKSPACE_ID})"
echo ""
echo "  Metrics from Prometheus targets:"
echo "    - besu (execution client)"
echo "    - teku_beacon (consensus client)"
echo "    - teku_validator (validator client)"
echo "    - prometheus_node_exporter (system metrics)"
echo ""
log_info "Key metrics available:"
echo ""
echo "  System (node_exporter):"
echo "    - node_cpu_seconds_total"
echo "    - node_memory_MemAvailable_bytes"
echo "    - node_filesystem_avail_bytes"
echo ""
echo "  Besu (execution):"
echo "    - ethereum_blockchain_height"
echo "    - ethereum_best_known_block_number"
echo "    - besu_synchronizer_in_sync"
echo "    - ethereum_peer_count"
echo ""
echo "  Teku (consensus):"
echo "    - beacon_head_slot"
echo "    - beacon_finalized_epoch"
echo "    - beacon_peer_count"
echo "    - validator_*"
echo ""

# =============================================================================
# Done
# =============================================================================

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   Installation Complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Architecture:"
echo "  Prometheus (:${PROMETHEUS_PORT}) --> Grafana Agent --> AMP --> AMG"
echo ""
echo "  Prometheus already scrapes: besu, teku_beacon, teku_validator, node_exporter"
echo "  Grafana Agent federates all metrics and pushes to AMP"
echo ""
echo "Verify:"
echo ""
echo "  # Check Grafana Agent status"
echo "  systemctl status grafana-agent"
echo ""
echo "  # View Agent logs"
echo "  journalctl -u grafana-agent -f"
echo ""
echo "  # Test federation (should return metrics)"
echo "  curl -s -G localhost:${PROMETHEUS_PORT}/federate --data-urlencode 'match[]={job=~\".+\"}' | head -20"
echo ""
echo "  # After 1-2 minutes, check data in AMG:"
echo "  #   up"
echo "  #   node_cpu_seconds_total"
echo "  #   ethereum_blockchain_height"
echo "  #   beacon_head_slot"
echo ""
