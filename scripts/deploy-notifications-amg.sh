#!/bin/bash

# Deploy notification contact points and policies to Amazon Managed Grafana
# Uses the Grafana Provisioning API to configure alerting notifications
#
# Contact points use SNS topics as the notification channel:
#   - sns-teams: publishes to staking-alert topic (Lambda -> Teams)
#   - sns-email: publishes to staking-alert-critical topic (Lambda -> Teams + Email)
#
# Prerequisites: Run deploy-sns-lambda.sh first to create the SNS/Lambda infrastructure

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
STAKING_ALERT_TOPIC_ARN="${STAKING_ALERT_TOPIC_ARN:-}"
STAKING_ALERT_CRITICAL_TOPIC_ARN="${STAKING_ALERT_CRITICAL_TOPIC_ARN:-}"

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
    echo "Usage: AMG_WORKSPACE_ID=g-xxx ./scripts/deploy-notifications-amg.sh"
    exit 1
fi

if [ -z "$STAKING_ALERT_TOPIC_ARN" ]; then
    echo -e "${RED}✗ STAKING_ALERT_TOPIC_ARN is not set${NC}"
    echo "Run deploy-sns-lambda.sh first, then set STAKING_ALERT_TOPIC_ARN in .env"
    exit 1
fi

if [ -z "$STAKING_ALERT_CRITICAL_TOPIC_ARN" ]; then
    echo -e "${RED}✗ STAKING_ALERT_CRITICAL_TOPIC_ARN is not set${NC}"
    echo "Run deploy-sns-lambda.sh first, then set STAKING_ALERT_CRITICAL_TOPIC_ARN in .env"
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
# Helper: create or update a contact point
# =============================================================================
deploy_contact_point() {
    local CP_NAME="$1"
    local CP_PAYLOAD="$2"

    echo "  Creating contact point: ${CP_NAME}..."

    HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TMPFILE" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${AMG_API_KEY}" \
        -d "$CP_PAYLOAD" \
        "${GRAFANA_URL}/api/v1/provisioning/contact-points" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
        echo -e "    ${GREEN}✓ Created${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        return
    fi

    if [ "$HTTP_CODE" = "409" ]; then
        # Already exists - try to update
        EXISTING=$(curl -s \
            -H "Authorization: Bearer ${AMG_API_KEY}" \
            "${GRAFANA_URL}/api/v1/provisioning/contact-points" 2>/dev/null || echo "[]")
        EXISTING_UID=$(echo "$EXISTING" | jq -r ".[] | select(.name == \"${CP_NAME}\") | .uid" | head -1)

        if [ -n "$EXISTING_UID" ] && [ "$EXISTING_UID" != "null" ]; then
            HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TMPFILE" \
                -X PUT \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${AMG_API_KEY}" \
                -d "$CP_PAYLOAD" \
                "${GRAFANA_URL}/api/v1/provisioning/contact-points/${EXISTING_UID}" 2>/dev/null || echo "000")

            if [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "200" ]; then
                echo -e "    ${GREEN}✓ Updated${NC}"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                return
            fi
        fi

        echo -e "    ${YELLOW}⚠ Already exists${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        return
    fi

    echo -e "    ${RED}✗ Failed (HTTP ${HTTP_CODE})${NC}"
    jq -r '.message // .' "$TMPFILE" 2>/dev/null || cat "$TMPFILE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# =============================================================================
# Deploy Contact Points
# =============================================================================

echo "Deploying contact points..."

# --- SNS Teams Contact Point ---
TEAMS_PAYLOAD=$(jq -n \
    --arg topic "$STAKING_ALERT_TOPIC_ARN" \
    --arg region "$AMG_REGION" \
    '{
        name: "sns-teams",
        type: "sns",
        settings: {
            topic: $topic,
            authProvider: "default",
            sigV4Region: $region
        },
        disableResolveMessage: false
    }')

deploy_contact_point "sns-teams" "$TEAMS_PAYLOAD"

# --- SNS Email Contact Point (critical alerts -> Teams + Email) ---
EMAIL_PAYLOAD=$(jq -n \
    --arg topic "$STAKING_ALERT_CRITICAL_TOPIC_ARN" \
    --arg region "$AMG_REGION" \
    '{
        name: "sns-email",
        type: "sns",
        settings: {
            topic: $topic,
            authProvider: "default",
            sigV4Region: $region
        },
        disableResolveMessage: false
    }')

deploy_contact_point "sns-email" "$EMAIL_PAYLOAD"

# =============================================================================
# Deploy Notification Policies
# =============================================================================

echo ""
echo "Deploying notification policies..."

POLICIES=$(cat <<'POLICIES_EOF'
{
  "receiver": "sns-teams",
  "group_by": ["alertname", "instance"],
  "group_wait": "30s",
  "group_interval": "5m",
  "repeat_interval": "4h",
  "routes": [
    {
      "receiver": "sns-teams",
      "matchers": ["severity=critical"],
      "continue": true,
      "group_wait": "10s",
      "group_interval": "1m",
      "repeat_interval": "1h"
    },
    {
      "receiver": "sns-email",
      "matchers": ["severity=critical"],
      "group_wait": "10s",
      "group_interval": "5m",
      "repeat_interval": "4h"
    },
    {
      "receiver": "sns-teams",
      "matchers": ["severity=high"],
      "group_wait": "30s",
      "group_interval": "5m",
      "repeat_interval": "4h"
    },
    {
      "receiver": "sns-teams",
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
