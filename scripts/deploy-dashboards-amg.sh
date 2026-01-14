#!/bin/bash

# Deploy Grafana dashboards to Amazon Managed Grafana (AMG)
# This script imports all JSON dashboard files to AMG

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration (can be overridden by environment variables)
AMG_WORKSPACE_ID="${AMG_WORKSPACE_ID:-}"
AMG_REGION="${AMG_REGION:-${AWS_REGION:-us-east-1}}"
AMG_API_KEY="${AMG_API_KEY:-}"
AMG_ENDPOINT="${AMG_ENDPOINT:-${AMG_WORKSPACE_ID}.grafana-workspace.${AMG_REGION}.amazonaws.com}"
OVERWRITE="${OVERWRITE:-true}"
DASHBOARDS_DIR="${REPO_ROOT}/dashboards"

# Check for required tools
if ! command -v aws &> /dev/null; then
    echo -e "${RED}✗ AWS CLI not found. Please install AWS CLI.${NC}"
    exit 1
fi

if ! command -v curl &> /dev/null && ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}⚠ curl or jq recommended for dashboard deployment${NC}"
fi

# Check for required environment variables
if [ -z "$AMG_WORKSPACE_ID" ]; then
    echo -e "${RED}✗ AMG_WORKSPACE_ID environment variable is not set${NC}"
    echo "Usage: AMG_WORKSPACE_ID=g-xxx ./scripts/deploy-dashboards-amg.sh"
    exit 1
fi

# Forbid manual AMG_API_KEY (script must create it automatically)
if [ -n "$AMG_API_KEY" ]; then
    echo -e "${RED}✗ ERROR: AMG_API_KEY is manually set${NC}"
    echo -e "${RED}   Manual API keys are forbidden. The script will create temporary API keys automatically.${NC}"
    echo -e "${RED}   Please remove AMG_API_KEY from your environment (.env file or environment variables).${NC}"
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
        echo "Please set AMG_ENDPOINT environment variable manually"
        exit 1
    fi
fi

# Get API key if not provided (using IAM role or API key)
if [ -z "$AMG_API_KEY" ]; then
    echo "Creating temporary API key for AMG..."
    # Try to create API key using IAM role
    AMG_API_KEY=$(aws grafana create-workspace-api-key \
        --workspace-id "${AMG_WORKSPACE_ID}" \
        --key-name "deploy-script-$(date +%s)" \
        --key-role "ADMIN" \
        --seconds-to-live 3600 \
        --region "${AMG_REGION}" \
        --query 'key' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$AMG_API_KEY" ]; then
        echo -e "${YELLOW}⚠ Could not create API key automatically${NC}"
        echo "Please set AMG_API_KEY environment variable or configure IAM permissions"
        echo "You can create an API key in the Grafana UI: Settings -> API Keys"
        exit 1
    fi
    echo -e "${GREEN}✓ Created temporary API key${NC}"
fi

GRAFANA_URL="https://${AMG_ENDPOINT}"

echo "Deploying Grafana dashboards to Amazon Managed Grafana"
echo "========================================================"
echo "Workspace ID: ${AMG_WORKSPACE_ID}"
echo "Endpoint: ${GRAFANA_URL}"
echo "Region: ${AMG_REGION}"
echo "Overwrite: ${OVERWRITE}"
echo ""

# Find all JSON dashboard files
DASHBOARD_FILES=()
while IFS= read -r -d '' file; do
    DASHBOARD_FILES+=("$file")
done < <(find "$DASHBOARDS_DIR" -name "*.json" -type f -print0)

if [ ${#DASHBOARD_FILES[@]} -eq 0 ]; then
    echo -e "${YELLOW}⚠ No JSON dashboard files found in ${DASHBOARDS_DIR}${NC}"
    exit 1
fi

echo "Found ${#DASHBOARD_FILES[@]} dashboard file(s):"
for file in "${DASHBOARD_FILES[@]}"; do
    echo "  - $(basename "$file")"
done

# Deploy each dashboard
SUCCESS_COUNT=0
FAIL_COUNT=0

for dashboard_file in "${DASHBOARD_FILES[@]}"; do
    dashboard_name=$(basename "$dashboard_file" .json)
    echo ""
    echo "Deploying: ${dashboard_name}..."
    
    # Read and prepare dashboard JSON
    # Grafana API expects: {"dashboard": {...}, "overwrite": true}
    TEMP_DASHBOARD=$(mktemp)
    trap "rm -f ${TEMP_DASHBOARD}" EXIT
    
    # Wrap dashboard in API format
    if command -v jq &> /dev/null; then
        # Use --slurpfile for wider jq compatibility (avoids --argfile)
        jq -n \
            --slurpfile dashboard "$dashboard_file" \
            --arg overwrite "$OVERWRITE" \
            '{dashboard: $dashboard[0], overwrite: ($overwrite == "true")}' \
            > "${TEMP_DASHBOARD}"
    else
        # Fallback: manual JSON construction
        {
            echo '{'
            echo '  "dashboard": '
            cat "$dashboard_file"
            echo ','
            echo "  \"overwrite\": ${OVERWRITE}"
            echo '}'
        } > "${TEMP_DASHBOARD}"
    fi
    
    # Validate JSON
    if ! python3 -m json.tool "${TEMP_DASHBOARD}" > /dev/null 2>&1; then
        echo -e "${RED}✗ Invalid JSON in ${dashboard_name}${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    
    # Deploy to Grafana
    HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/grafana_response.json \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${AMG_API_KEY}" \
        -d @"${TEMP_DASHBOARD}" \
        "${GRAFANA_URL}/api/dashboards/db" || echo "000")
    
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
        echo -e "${GREEN}✓ Successfully deployed ${dashboard_name}${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo -e "${RED}✗ Failed to deploy ${dashboard_name} (HTTP ${HTTP_CODE})${NC}"
        if [ -f /tmp/grafana_response.json ]; then
            echo "Response: $(cat /tmp/grafana_response.json)"
        fi
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    
    rm -f "${TEMP_DASHBOARD}"
done

# Summary
echo ""
echo "========================================================"
echo "Deployment Summary"
echo "========================================================"
echo -e "${GREEN}✓ Successfully deployed: ${SUCCESS_COUNT}${NC}"
if [ $FAIL_COUNT -gt 0 ]; then
    echo -e "${RED}✗ Failed: ${FAIL_COUNT}${NC}"
    exit 1
fi

echo ""
echo "All dashboards deployed successfully!"
