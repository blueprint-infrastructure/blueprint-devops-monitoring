#!/bin/bash

# Deploy Prometheus alert rules to Amazon Managed Prometheus (AMP)
# This script combines all YAML rule files and deploys them to AMP

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration (can be overridden by environment variables)
AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-}"
AMP_REGION="${AMP_REGION:-${AWS_REGION:-us-east-1}}"
AMP_RULE_NAMESPACE="${AMP_RULE_NAMESPACE:-default}"
ALERTING_DIR="${REPO_ROOT}/alerting"

# Check for required tools
if ! command -v aws &> /dev/null; then
    echo -e "${RED}✗ AWS CLI not found. Please install AWS CLI.${NC}"
    exit 1
fi

# Check for required environment variables
if [ -z "$AMP_WORKSPACE_ID" ]; then
    echo -e "${RED}✗ AMP_WORKSPACE_ID environment variable is not set${NC}"
    echo "Usage: AMP_WORKSPACE_ID=ws-xxx ./scripts/deploy-alerts-amp.sh"
    exit 1
fi

echo "Deploying Prometheus alert rules to Amazon Managed Prometheus"
echo "=============================================================="
echo "Workspace ID: ${AMP_WORKSPACE_ID}"
echo "Region: ${AMP_REGION}"
echo "Namespace: ${AMP_RULE_NAMESPACE}"
echo ""

# Create temporary file for combined rules
TEMP_RULES_FILE=$(mktemp)
trap "rm -f ${TEMP_RULES_FILE}" EXIT

# Combine all YAML rule files
echo "Combining alert rule files..."

# Find all YAML files in alerting directory (excluding README files)
RULE_FILES=()
while IFS= read -r -d '' file; do
    RULE_FILES+=("$file")
done < <(find "$ALERTING_DIR" -maxdepth 1 -name "*.yaml" -type f -print0)

# Also include chain-specific rules if they exist
if [ -d "${ALERTING_DIR}/chain" ]; then
    while IFS= read -r -d '' file; do
        RULE_FILES+=("$file")
    done < <(find "${ALERTING_DIR}/chain" -name "*.yaml" -type f -print0)
fi

if [ ${#RULE_FILES[@]} -eq 0 ]; then
    echo -e "${YELLOW}⚠ No YAML rule files found in ${ALERTING_DIR}${NC}"
    exit 1
fi

echo "Found ${#RULE_FILES[@]} rule file(s):"
for file in "${RULE_FILES[@]}"; do
    echo "  - $(basename "$file")"
done

# Combine all rule groups into a single YAML file
# We need to merge all groups into one document
{
    echo "groups:"
    for file in "${RULE_FILES[@]}"; do
        # Extract groups from each file and merge them
        if command -v yq &> /dev/null; then
            # Use yq to properly extract and format groups
            yq eval '.groups[]' "$file" | sed 's/^/  - /'
        else
            # Fallback: extract groups section using awk
            # This assumes standard YAML formatting with groups at top level
            awk '
            BEGIN { in_groups = 0; group_started = 0 }
            /^groups:/ { 
                in_groups = 1
                next
            }
            in_groups {
                # Stop if we hit a top-level key (not indented or only 2 spaces for group item)
                if (/^[a-zA-Z]/ && !/^  -/ && !/^    /) {
                    in_groups = 0
                    next
                }
                # Print group items with proper indentation
                if (/^  -/) {
                    print
                    group_started = 1
                } else if (group_started && (/^    / || /^      / || /^        / || /^          /)) {
                    print
                } else if (group_started && /^$/) {
                    print
                }
            }
            ' "$file"
        fi
    done
} > "${TEMP_RULES_FILE}"

# Validate the combined rules file
if command -v promtool &> /dev/null; then
    echo ""
    echo "Validating combined rules file..."
    if promtool check rules "${TEMP_RULES_FILE}" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Rules validation passed${NC}"
    else
        echo -e "${YELLOW}⚠ Rules validation failed, but continuing deployment...${NC}"
        promtool check rules "${TEMP_RULES_FILE}" || true
    fi
else
    echo -e "${YELLOW}⚠ promtool not found, skipping validation${NC}"
fi

# Deploy to AMP
echo ""
echo "Deploying rules to AMP workspace..."
if aws amp put-rule-groups-namespace \
    --workspace-id "${AMP_WORKSPACE_ID}" \
    --name "${AMP_RULE_NAMESPACE}" \
    --data "file://${TEMP_RULES_FILE}" \
    --region "${AMP_REGION}" \
    > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Successfully deployed alert rules to AMP${NC}"
    echo "  Workspace: ${AMP_WORKSPACE_ID}"
    echo "  Namespace: ${AMP_RULE_NAMESPACE}"
else
    echo -e "${RED}✗ Failed to deploy alert rules to AMP${NC}"
    echo "Run with AWS CLI debug output for more details:"
    echo "  AWS_CLI_LOG_LEVEL=debug aws amp put-rule-groups-namespace ..."
    exit 1
fi

echo ""
echo "Deployment complete!"
