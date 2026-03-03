#!/bin/bash

# Deploy notification contact points and policies to Amazon Managed Grafana
# Uses the Grafana Provisioning API to configure alerting notifications
#
# Note: AMG supports limited contact point types: sns, slack, pagerduty,
# victorops, opsgenie, prometheus-alertmanager.
# For Teams notifications, we use the 'slack' type with the Teams Workflow
# webhook URL, which accepts incoming HTTP POST requests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env file if it exists
if [ -f "${REPO_ROOT}/.env" ]; then
    set -a
    source "${REPO_ROOT}/.env"
    set +a
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
AMG_WORKSPACE_ID="${AMG_WORKSPACE_ID:-}"
AMG_REGION="${AMG_REGION:-${AWS_REGION:-us-east-1}}"
AMG_API_KEY="${AMG_API_KEY:-}"
AMG_ENDPOINT="${AMG_ENDPOINT:-}"
TEAMS_WEBHOOK_URL="${TEAMS_WEBHOOK_URL:-}"
ALERT_EMAIL_RECIPIENTS="${ALERT_EMAIL_RECIPIENTS:-}"

# Check for required tools
for tool in aws curl jq; do
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${RED}✗ ${tool} not found. Please install ${tool}.${NC}"
        exit 1
    fi
done

# Check for required environment variables
if [ -z "$AMG_WORKSPACE_ID" ]; then
    echo -e "${RED}✗ AMG_WORKSPACE_ID environment variable is not set${NC}"
    echo "Usage: AMG_WORKSPACE_ID=g-xxx TEAMS_WEBHOOK_URL=https://... ./scripts/deploy-notifications-amg.sh"
    exit 1
fi

if [ -z "$TEAMS_WEBHOOK_URL" ]; then
    echo -e "${RED}✗ TEAMS_WEBHOOK_URL environment variable is not set${NC}"
    echo "Set your Microsoft Teams incoming webhook URL in .env or environment"
    exit 1
fi

# Forbid manual AMG_API_KEY
if [ -n "$AMG_API_KEY" ]; then
    echo -e "${RED}✗ ERROR: AMG_API_KEY is manually set${NC}"
    echo -e "${RED}   Please remove AMG_API_KEY from your environment.${NC}"
    exit 1
fi

# Get AMG endpoint if not provided
if [ -z "$AMG_ENDPOINT" ]; then
    echo "Fetching AMG workspace endpoint..."
    AMG_ENDPOINT=$(aws grafana describe-workspace \
        --workspace-id "${AMG_WORKSPACE_ID}" \
        --region "${AMG_REGION}" \
        --query 'workspace.endpoint' \
        --output text 2>/dev/null || echo "")

    if [ -z "$AMG_ENDPOINT" ]; then
        echo -e "${RED}✗ Failed to get AMG workspace endpoint${NC}"
        exit 1
    fi
fi

# Create temporary API key
echo "Creating temporary API key for AMG..."
AMG_API_KEY=$(aws grafana create-workspace-api-key \
    --workspace-id "${AMG_WORKSPACE_ID}" \
    --key-name "deploy-notifications-$(date +%s)" \
    --key-role "ADMIN" \
    --seconds-to-live 3600 \
    --region "${AMG_REGION}" \
    --query 'key' \
    --output text 2>/dev/null || echo "")

if [ -z "$AMG_API_KEY" ]; then
    echo -e "${RED}✗ Could not create API key${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Created temporary API key${NC}"

GRAFANA_URL="https://${AMG_ENDPOINT}"

echo ""
echo "Deploying notifications to Amazon Managed Grafana"
echo "=================================================="
echo "Workspace ID: ${AMG_WORKSPACE_ID}"
echo "Endpoint: ${GRAFANA_URL}"
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0
TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT

# =============================================================================
# Deploy Contact Points
# =============================================================================

echo "Deploying contact points..."

# --- Teams Webhook (via Slack type) ---
# AMG does not support 'webhook' or 'teams' types.
# Using 'slack' type which sends HTTP POST to the Teams Workflow URL.
echo "  Creating contact point: teams-webhook (via slack type)..."

TEAMS_PAYLOAD=$(jq -n \
    --arg url "$TEAMS_WEBHOOK_URL" \
    '{
        name: "teams-webhook",
        type: "slack",
        settings: {
            url: $url,
            title: "{{ .CommonLabels.alertname }}",
            text: "**Status:** {{ .Status | toUpper }}\n**Severity:** {{ .CommonLabels.severity }}\n**Instance:** {{ .CommonLabels.instance }}\n\n{{ .CommonAnnotations.summary }}\n\n{{ .CommonAnnotations.description }}"
        },
        disableResolveMessage: false
    }')

HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TMPFILE" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AMG_API_KEY}" \
    -d "$TEAMS_PAYLOAD" \
    "${GRAFANA_URL}/api/v1/provisioning/contact-points" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
    echo -e "    ${GREEN}✓ Created${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
elif [ "$HTTP_CODE" = "409" ]; then
    # Already exists - try to update
    EXISTING=$(curl -s \
        -H "Authorization: Bearer ${AMG_API_KEY}" \
        "${GRAFANA_URL}/api/v1/provisioning/contact-points" 2>/dev/null || echo "[]")
    EXISTING_UID=$(echo "$EXISTING" | jq -r '.[] | select(.name == "teams-webhook") | .uid' | head -1)

    if [ -n "$EXISTING_UID" ] && [ "$EXISTING_UID" != "null" ]; then
        HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TMPFILE" \
            -X PUT \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${AMG_API_KEY}" \
            -d "$TEAMS_PAYLOAD" \
            "${GRAFANA_URL}/api/v1/provisioning/contact-points/${EXISTING_UID}" 2>/dev/null || echo "000")

        if [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "200" ]; then
            echo -e "    ${GREEN}✓ Updated${NC}"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo -e "    ${RED}✗ Failed to update (HTTP ${HTTP_CODE})${NC}"
            jq -r '.message // .' "$TMPFILE" 2>/dev/null || cat "$TMPFILE"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo -e "    ${YELLOW}⚠ Already exists${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    fi
else
    echo -e "    ${RED}✗ Failed (HTTP ${HTTP_CODE})${NC}"
    jq -r '.message // .' "$TMPFILE" 2>/dev/null || cat "$TMPFILE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# --- SNS Email Contact Point (optional) ---
# Uses the existing SNS topic for email delivery
if [ -n "$ALERT_EMAIL_RECIPIENTS" ]; then
    echo "  ${YELLOW}⚠ Email notifications require SNS topic configuration in AMG${NC}"
    echo "    Set up an SNS topic with email subscriptions and configure as a contact point in the Grafana UI"
fi

# =============================================================================
# Deploy Notification Policies
# =============================================================================

echo ""
echo "Deploying notification policies..."

# Route all alerts through teams-webhook
# Critical alerts also go to grafana-default-sns (if configured)
POLICIES=$(cat <<'POLICIES_EOF'
{
  "receiver": "teams-webhook",
  "group_by": ["alertname", "instance"],
  "group_wait": "30s",
  "group_interval": "5m",
  "repeat_interval": "4h",
  "routes": [
    {
      "receiver": "teams-webhook",
      "matchers": ["severity=critical"],
      "continue": true,
      "group_wait": "10s",
      "group_interval": "1m",
      "repeat_interval": "1h"
    },
    {
      "receiver": "grafana-default-sns",
      "matchers": ["severity=critical"],
      "group_wait": "10s",
      "group_interval": "5m",
      "repeat_interval": "4h"
    },
    {
      "receiver": "teams-webhook",
      "matchers": ["severity=high"],
      "group_wait": "30s",
      "group_interval": "5m",
      "repeat_interval": "4h"
    },
    {
      "receiver": "teams-webhook",
      "matchers": ["severity=warning"],
      "group_wait": "60s",
      "group_interval": "5m",
      "repeat_interval": "12h"
    }
  ]
}
POLICIES_EOF
)

HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TMPFILE" \
    -X PUT \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AMG_API_KEY}" \
    -d "$POLICIES" \
    "${GRAFANA_URL}/api/v1/provisioning/policies" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "200" ]; then
    echo -e "  ${GREEN}✓ Notification policies deployed${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
else
    echo -e "  ${RED}✗ Failed to deploy notification policies (HTTP ${HTTP_CODE})${NC}"
    jq -r '.message // .' "$TMPFILE" 2>/dev/null || cat "$TMPFILE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Summary
echo ""
echo "=================================================="
echo "Notification Deployment Summary"
echo "=================================================="
echo -e "${GREEN}✓ Successfully deployed: ${SUCCESS_COUNT}${NC}"
if [ $FAIL_COUNT -gt 0 ]; then
    echo -e "${RED}✗ Failed: ${FAIL_COUNT}${NC}"
fi

echo ""
echo "View contact points: ${GRAFANA_URL}/alerting/notifications"
echo "View notification policies: ${GRAFANA_URL}/alerting/routes"
