#!/bin/bash

# Master deployment script for monitoring as code
# Deploys alert rules to AMP and dashboards to AMG

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Monitoring as Code Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if .env file exists
ENV_FILE="${REPO_ROOT}/.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading configuration from .env file..."
    set -a
    source "$ENV_FILE"
    set +a
    echo -e "${GREEN}✓ Configuration loaded${NC}"
    echo ""
fi

# Parse command line arguments
DEPLOY_ALERTS=true
DEPLOY_DASHBOARDS=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --alerts-only)
            DEPLOY_DASHBOARDS=false
            shift
            ;;
        --dashboards-only)
            DEPLOY_ALERTS=false
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --alerts-only      Deploy only alert rules to AMP"
            echo "  --dashboards-only   Deploy only dashboards to AMG"
            echo "  --help             Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  AMP_WORKSPACE_ID    Amazon Managed Prometheus workspace ID"
            echo "  AMP_REGION          AWS region for AMP (default: us-east-1)"
            echo "  AMP_RULE_NAMESPACE  Rule namespace in AMP (default: default)"
            echo "  AMG_WORKSPACE_ID    Amazon Managed Grafana workspace ID"
            echo "  AMG_REGION          AWS region for AMG (default: us-east-1)"
            echo "  AMG_API_KEY         Grafana API key (optional, will try to create)"
            echo "  AMG_ENDPOINT        Grafana endpoint (optional, will auto-detect)"
            echo "  OVERWRITE           Overwrite existing dashboards (default: true)"
            echo ""
            echo "Example:"
            echo "  AMP_WORKSPACE_ID=ws-xxx AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate before deployment
echo "Running pre-deployment validation..."
if ! "${SCRIPT_DIR}/validate.sh"; then
    echo -e "${YELLOW}⚠ Validation failed, but continuing with deployment...${NC}"
    echo ""
fi

# Deploy alerts to AMP
if [ "$DEPLOY_ALERTS" = true ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Deploying Alert Rules to AMP${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    if [ -z "${AMP_WORKSPACE_ID:-}" ]; then
        echo -e "${YELLOW}⚠ AMP_WORKSPACE_ID not set, skipping alert deployment${NC}"
    else
        if "${SCRIPT_DIR}/deploy-alerts-amp.sh"; then
            echo -e "${GREEN}✓ Alert rules deployed successfully${NC}"
        else
            echo -e "${RED}✗ Alert rules deployment failed${NC}"
            exit 1
        fi
    fi
    echo ""
fi

# Deploy dashboards to AMG
if [ "$DEPLOY_DASHBOARDS" = true ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Deploying Dashboards to AMG${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    if [ -z "${AMG_WORKSPACE_ID:-}" ]; then
        echo -e "${YELLOW}⚠ AMG_WORKSPACE_ID not set, skipping dashboard deployment${NC}"
    else
        if "${SCRIPT_DIR}/deploy-dashboards-amg.sh"; then
            echo -e "${GREEN}✓ Dashboards deployed successfully${NC}"
        else
            echo -e "${RED}✗ Dashboard deployment failed${NC}"
            exit 1
        fi
    fi
    echo ""
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
