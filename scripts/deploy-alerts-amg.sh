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
    --key-name "deploy-alerts-$(date +%s)" \
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

# Process each rule file
SUCCESS_COUNT=0
FAIL_COUNT=0

for rule_file in "${RULE_FILES[@]}"; do
    echo "Processing: $(basename "$rule_file")..."
    
    # Parse YAML and convert to Grafana alert rules
    # Using yq if available, otherwise awk
    if command -v yq &> /dev/null; then
        # Get number of groups
        GROUP_COUNT=$(yq eval '.groups | length' "$rule_file" 2>/dev/null || echo "0")
        
        for ((g=0; g<GROUP_COUNT; g++)); do
            GROUP_NAME=$(yq eval ".groups[$g].name" "$rule_file")
            INTERVAL=$(yq eval ".groups[$g].interval // \"1m\"" "$rule_file")
            RULE_COUNT=$(yq eval ".groups[$g].rules | length" "$rule_file" 2>/dev/null || echo "0")
            
            echo "  Group: ${GROUP_NAME} (${RULE_COUNT} rules)"
            
            for ((r=0; r<RULE_COUNT; r++)); do
                ALERT_NAME=$(yq eval ".groups[$g].rules[$r].alert" "$rule_file")
                EXPR=$(yq eval ".groups[$g].rules[$r].expr" "$rule_file" | tr -d '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
                FOR_DURATION=$(yq eval ".groups[$g].rules[$r].for // \"5m\"" "$rule_file")
                SEVERITY=$(yq eval ".groups[$g].rules[$r].labels.severity // \"warning\"" "$rule_file")
                SUMMARY=$(yq eval ".groups[$g].rules[$r].annotations.summary // \"\"" "$rule_file")
                DESCRIPTION=$(yq eval ".groups[$g].rules[$r].annotations.description // \"\"" "$rule_file")
                RUNBOOK_URL=$(yq eval ".groups[$g].rules[$r].annotations.runbook_url // \"\"" "$rule_file")
                
                # Skip if no alert name
                if [ "$ALERT_NAME" = "null" ] || [ -z "$ALERT_NAME" ]; then
                    continue
                fi
                
                echo "    Creating alert: ${ALERT_NAME}..."
                
                # Create Grafana alert rule JSON
                ALERT_RULE=$(jq -n \
                    --arg title "$ALERT_NAME" \
                    --arg folderUID "$FOLDER_UID" \
                    --arg ruleGroup "$GROUP_NAME" \
                    --arg expr "$EXPR" \
                    --arg for "$FOR_DURATION" \
                    --arg severity "$SEVERITY" \
                    --arg summary "$SUMMARY" \
                    --arg description "$DESCRIPTION" \
                    --arg runbook "$RUNBOOK_URL" \
                    --arg datasourceUID "$DATASOURCE_UID" \
                    '{
                        "title": $title,
                        "ruleGroup": $ruleGroup,
                        "folderUID": $folderUID,
                        "noDataState": "NoData",
                        "execErrState": "Error",
                        "for": $for,
                        "annotations": {
                            "summary": $summary,
                            "description": $description,
                            "runbook_url": $runbook
                        },
                        "labels": {
                            "severity": $severity
                        },
                        "condition": "A",
                        "data": [
                            {
                                "refId": "A",
                                "relativeTimeRange": {
                                    "from": 600,
                                    "to": 0
                                },
                                "datasourceUid": $datasourceUID,
                                "model": {
                                    "expr": $expr,
                                    "refId": "A"
                                }
                            }
                        ]
                    }')
                
                # Create alert rule via API
                HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/grafana_alert_response.json \
                    -X POST \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer ${AMG_API_KEY}" \
                    -d "$ALERT_RULE" \
                    "${GRAFANA_URL}/api/v1/provisioning/alert-rules" 2>/dev/null || echo "000")
                
                # Check if it's a conflict error (can be 409 or 400 with conflict message)
                IS_CONFLICT="false"
                if [ "$HTTP_CODE" = "409" ]; then
                    IS_CONFLICT="true"
                elif [ "$HTTP_CODE" = "400" ] && [ -f /tmp/grafana_alert_response.json ]; then
                    if grep -q "conflict" /tmp/grafana_alert_response.json 2>/dev/null; then
                        IS_CONFLICT="true"
                    fi
                fi
                
                if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
                    echo -e "      ${GREEN}✓ Created${NC}"
                    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                elif [ "$IS_CONFLICT" = "true" ]; then
                    # Rule already exists, try to update
                    # First get the existing rule UID
                    EXISTING_RULES=$(curl -s \
                        -H "Authorization: Bearer ${AMG_API_KEY}" \
                        "${GRAFANA_URL}/api/v1/provisioning/alert-rules" 2>/dev/null || echo "[]")
                    
                    EXISTING_UID=$(echo "$EXISTING_RULES" | jq -r ".[] | select(.title == \"$ALERT_NAME\") | .uid" | head -1)
                    
                    if [ -n "$EXISTING_UID" ] && [ "$EXISTING_UID" != "null" ]; then
                        HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/grafana_alert_response.json \
                            -X PUT \
                            -H "Content-Type: application/json" \
                            -H "Authorization: Bearer ${AMG_API_KEY}" \
                            -d "$ALERT_RULE" \
                            "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${EXISTING_UID}" 2>/dev/null || echo "000")
                        
                        if [ "$HTTP_CODE" = "200" ]; then
                            echo -e "      ${GREEN}✓ Updated${NC}"
                            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                        else
                            echo -e "      ${RED}✗ Failed to update (HTTP ${HTTP_CODE})${NC}"
                            FAIL_COUNT=$((FAIL_COUNT + 1))
                        fi
                    else
                        echo -e "      ${YELLOW}⚠ Already exists${NC}"
                        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                    fi
                else
                    echo -e "      ${RED}✗ Failed (HTTP ${HTTP_CODE})${NC}"
                    if [ -f /tmp/grafana_alert_response.json ]; then
                        cat /tmp/grafana_alert_response.json | jq -r '.message // .' 2>/dev/null || cat /tmp/grafana_alert_response.json
                    fi
                    FAIL_COUNT=$((FAIL_COUNT + 1))
                fi
            done
        done
    else
        echo -e "${YELLOW}⚠ yq not found, skipping ${rule_file}${NC}"
        echo "  Install yq: https://github.com/mikefarah/yq"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
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
