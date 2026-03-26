#!/bin/bash

# Deploy alert rules to Amazon Managed Grafana using Grafana Provisioning API
# This script converts Prometheus-style alert rules to Grafana alert rules

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
ALERTING_DIR="${REPO_ROOT}/alerting"
DATASOURCE_UID="${DATASOURCE_UID:-prometheus}"
FOLDER_UID="${ALERT_FOLDER_UID:-alerting}"
FOLDER_TITLE="${ALERT_FOLDER_TITLE:-Alerting}"

# Check for required tools
if ! command -v aws &> /dev/null; then
    echo -e "${RED}✗ AWS CLI not found. Please install AWS CLI.${NC}"
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo -e "${RED}✗ curl not found. Please install curl.${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}✗ jq not found. Please install jq.${NC}"
    exit 1
fi

# Check for required environment variables
if [ -z "$AMG_WORKSPACE_ID" ]; then
    echo -e "${RED}✗ AMG_WORKSPACE_ID environment variable is not set${NC}"
    echo "Usage: AMG_WORKSPACE_ID=g-xxx ./scripts/deploy-alerts-grafana.sh"
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

# Authenticate via service account token (preferred) or fall back to API key
AMG_SERVICE_ACCOUNT_ID="${AMG_SERVICE_ACCOUNT_ID:-}"
AMG_API_KEY="${AMG_API_KEY:-}"

if [ -n "$AMG_API_KEY" ]; then
    # Use pre-configured API key or service account token directly
    echo -e "${GREEN}✓ Using provided API key/token${NC}"
elif [ -n "$AMG_SERVICE_ACCOUNT_ID" ]; then
    # Create a short-lived token from the service account
    echo "Creating service account token..."
    AMG_API_KEY=$(aws grafana create-workspace-service-account-token \
        --workspace-id "${AMG_WORKSPACE_ID}" \
        --service-account-id "${AMG_SERVICE_ACCOUNT_ID}" \
        --name "deploy-alerts-$(date +%s)" \
        --seconds-to-live 3600 \
        --region "${AMG_REGION}" \
        --query 'serviceAccountToken.key' \
        --output text 2>/dev/null || echo "")

    if [ -z "$AMG_API_KEY" ]; then
        echo -e "${RED}✗ Could not create service account token${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Created service account token${NC}"
else
    # Fall back to workspace API key (legacy, has quota limits)
    echo "Creating temporary API key for AMG..."
    AMG_API_KEY=$(aws grafana create-workspace-api-key \
        --workspace-id "${AMG_WORKSPACE_ID}" \
        --key-name "deploy-alerts-$(date +%s)" \
        --key-role "ADMIN" \
        --seconds-to-live 3600 \
        --region "${AMG_REGION}" \
        --query 'key' \
        --output text 2>/dev/null || echo "")

    if [ -z "$AMG_API_KEY" ]; then
        echo -e "${RED}✗ Could not create API key. Consider using a service account instead.${NC}"
        echo -e "${RED}  Set AMG_SERVICE_ACCOUNT_ID in .env${NC}"
        exit 1
    fi
    echo -e "${YELLOW}⚠ Using legacy API key (limited quota). Consider switching to service accounts.${NC}"
fi

GRAFANA_URL="https://${AMG_ENDPOINT}"

echo ""
echo "Deploying alert rules to Amazon Managed Grafana"
echo "================================================"
echo "Workspace ID: ${AMG_WORKSPACE_ID}"
echo "Endpoint: ${GRAFANA_URL}"
echo "Datasource UID: ${DATASOURCE_UID}"
echo ""

# Create or get folder for alerts
echo "Creating alert folder..."
FOLDER_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AMG_API_KEY}" \
    -d "{\"uid\": \"${FOLDER_UID}\", \"title\": \"${FOLDER_TITLE}\"}" \
    "${GRAFANA_URL}/api/folders" 2>/dev/null || echo "{}")

FOLDER_ID=$(echo "$FOLDER_RESPONSE" | jq -r '.id // empty')
if [ -z "$FOLDER_ID" ]; then
    # Folder might already exist, try to get it
    FOLDER_RESPONSE=$(curl -s \
        -H "Authorization: Bearer ${AMG_API_KEY}" \
        "${GRAFANA_URL}/api/folders/${FOLDER_UID}" 2>/dev/null || echo "{}")
    FOLDER_ID=$(echo "$FOLDER_RESPONSE" | jq -r '.id // empty')
fi

if [ -z "$FOLDER_ID" ]; then
    echo -e "${YELLOW}⚠ Could not create/get folder, using General folder${NC}"
    FOLDER_UID="general"
fi

# Find all YAML alert files
RULE_FILES=()
while IFS= read -r -d '' file; do
    RULE_FILES+=("$file")
done < <(find "$ALERTING_DIR" -name "*.yaml" -type f -print0 2>/dev/null)

if [ ${#RULE_FILES[@]} -eq 0 ]; then
    echo -e "${YELLOW}⚠ No YAML rule files found in ${ALERTING_DIR}${NC}"
    exit 0
fi

echo "Found ${#RULE_FILES[@]} rule file(s):"
for file in "${RULE_FILES[@]}"; do
    echo "  - $(basename "$file")"
done
echo ""

# Process each rule file using the Ruler API (per-group)
# The Ruler API is used by Grafana's alerting scheduler, unlike the provisioning API
SUCCESS_COUNT=0
FAIL_COUNT=0

for rule_file in "${RULE_FILES[@]}"; do
    echo "Processing: $(basename "$rule_file")..."

    if ! command -v yq &> /dev/null; then
        echo -e "${YELLOW}⚠ yq not found, skipping ${rule_file}${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    GROUP_COUNT=$(yq eval '.groups | length' "$rule_file" 2>/dev/null || echo "0")

    for ((g=0; g<GROUP_COUNT; g++)); do
        GROUP_NAME=$(yq eval ".groups[$g].name" "$rule_file")
        INTERVAL=$(yq eval ".groups[$g].interval // \"1m\"" "$rule_file")
        RULE_COUNT=$(yq eval ".groups[$g].rules | length" "$rule_file" 2>/dev/null || echo "0")

        echo "  Group: ${GROUP_NAME} (${RULE_COUNT} rules)"

        # Build all rules for this group as a JSON array
        RULES_JSON="[]"

        for ((r=0; r<RULE_COUNT; r++)); do
            ALERT_NAME=$(yq eval ".groups[$g].rules[$r].alert" "$rule_file")
            EXPR_RAW=$(yq eval ".groups[$g].rules[$r].expr" "$rule_file" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

            # Extract comparison operator and threshold from PromQL expression
            if [[ "$EXPR_RAW" =~ ^(.+)[[:space:]]+([\<\>!=]+)[[:space:]]+([0-9]+\.?[0-9]*)$ ]]; then
                EXPR_BASE="${BASH_REMATCH[1]}"
                EXPR_OP="${BASH_REMATCH[2]}"
                EXPR_THRESHOLD="${BASH_REMATCH[3]}"
            else
                EXPR_BASE="$EXPR_RAW"
                EXPR_OP=">"
                EXPR_THRESHOLD="0"
            fi

            EXPR="$EXPR_BASE"
            FOR_DURATION=$(yq eval ".groups[$g].rules[$r].for // \"5m\"" "$rule_file")
            SEVERITY=$(yq eval ".groups[$g].rules[$r].labels.severity // \"warning\"" "$rule_file")
            SUMMARY=$(yq eval ".groups[$g].rules[$r].annotations.summary // \"\"" "$rule_file")
            DESCRIPTION=$(yq eval ".groups[$g].rules[$r].annotations.description // \"\"" "$rule_file")
            RUNBOOK_URL=$(yq eval ".groups[$g].rules[$r].annotations.runbook_url // \"\"" "$rule_file")

            if [ "$ALERT_NAME" = "null" ] || [ -z "$ALERT_NAME" ]; then
                continue
            fi

            echo "    ${ALERT_NAME}..."

            # Build a single rule in ruler API format
            RULE_JSON=$(jq -n \
                --arg title "$ALERT_NAME" \
                --arg expr "$EXPR" \
                --arg for "$FOR_DURATION" \
                --arg severity "$SEVERITY" \
                --arg summary "$SUMMARY" \
                --arg description "$DESCRIPTION" \
                --arg runbook "$RUNBOOK_URL" \
                --arg datasourceUID "$DATASOURCE_UID" \
                --arg mathExpr "\$A ${EXPR_OP} ${EXPR_THRESHOLD}" \
                '{
                    "grafana_alert": {
                        "title": $title,
                        "condition": "B",
                        "no_data_state": "OK",
                        "exec_err_state": "OK",
                        "data": [
                            {
                                "refId": "A",
                                "relativeTimeRange": {"from": 600, "to": 0},
                                "datasourceUid": $datasourceUID,
                                "model": {
                                    "datasource": {"type": "prometheus", "uid": $datasourceUID},
                                    "expr": $expr,
                                    "instant": true,
                                    "intervalMs": 1000,
                                    "maxDataPoints": 43200,
                                    "refId": "A"
                                }
                            },
                            {
                                "refId": "B",
                                "relativeTimeRange": {"from": 0, "to": 0},
                                "datasourceUid": "__expr__",
                                "model": {
                                    "type": "math",
                                    "expression": $mathExpr,
                                    "refId": "B"
                                }
                            }
                        ]
                    },
                    "for": $for,
                    "labels": {"severity": $severity},
                    "annotations": {
                        "summary": $summary,
                        "description": $description,
                        "runbook_url": $runbook
                    }
                }')

            RULES_JSON=$(echo "$RULES_JSON" | jq --argjson rule "$RULE_JSON" '. + [$rule]')
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        done

        # Build the rule group payload for the ruler API
        GROUP_PAYLOAD=$(jq -n \
            --arg name "$GROUP_NAME" \
            --arg interval "$INTERVAL" \
            --argjson rules "$RULES_JSON" \
            '{name: $name, interval: $interval, rules: $rules}')

        # Deploy the entire group via ruler API
        HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/grafana_alert_response.json \
            -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${AMG_API_KEY}" \
            -d "$GROUP_PAYLOAD" \
            "${GRAFANA_URL}/api/ruler/grafana/api/v1/rules/${FOLDER_UID}" 2>/dev/null || echo "000")

        if [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
            echo -e "    ${GREEN}✓ Group deployed${NC}"
        else
            echo -e "    ${RED}✗ Group failed (HTTP ${HTTP_CODE})${NC}"
            if [ -f /tmp/grafana_alert_response.json ]; then
                cat /tmp/grafana_alert_response.json | jq -r '.message // .' 2>/dev/null || cat /tmp/grafana_alert_response.json
            fi
            FAIL_COUNT=$((FAIL_COUNT + RULE_COUNT))
            SUCCESS_COUNT=$((SUCCESS_COUNT - RULE_COUNT))
        fi
    done
done

# Summary
echo ""
echo "================================================"
echo "Deployment Summary"
echo "================================================"
echo -e "${GREEN}✓ Successfully deployed: ${SUCCESS_COUNT}${NC}"
if [ $FAIL_COUNT -gt 0 ]; then
    echo -e "${RED}✗ Failed: ${FAIL_COUNT}${NC}"
fi

echo ""
echo "View alerts in Grafana: ${GRAFANA_URL}/alerting/list"
