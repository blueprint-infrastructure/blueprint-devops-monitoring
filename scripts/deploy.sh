#!/bin/bash

# Master deployment script for monitoring as code
# Deploys notifications, dashboards, and alerts to Amazon Managed Grafana (AMG)
#
# See: https://docs.aws.amazon.com/grafana/latest/userguide/v10-alerting-use-grafana-alerts.html

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
SKIP_VALIDATION=false
DEPLOY_INFRA=true
DEPLOY_NOTIFICATIONS=true
DEPLOY_DASHBOARDS=true
DEPLOY_ALERTS=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        --infra-only)
            DEPLOY_NOTIFICATIONS=false
            DEPLOY_DASHBOARDS=false
            DEPLOY_ALERTS=false
            shift
            ;;
        --notifications-only)
            DEPLOY_INFRA=false
            DEPLOY_DASHBOARDS=false
            DEPLOY_ALERTS=false
            shift
            ;;
        --dashboards-only)
            DEPLOY_INFRA=false
            DEPLOY_NOTIFICATIONS=false
            DEPLOY_ALERTS=false
            shift
            ;;
        --alerts-only)
            DEPLOY_INFRA=false
            DEPLOY_NOTIFICATIONS=false
            DEPLOY_DASHBOARDS=false
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-validation    Skip pre-deployment validation"
            echo "  --infra-only         Deploy only SNS + Lambda infrastructure"
            echo "  --notifications-only Deploy only notification contact points and policies"
            echo "  --dashboards-only    Deploy only dashboards"
            echo "  --alerts-only        Deploy only alert rules"
            echo "  --help               Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  AMG_WORKSPACE_ID       Amazon Managed Grafana workspace ID (required)"
            echo "  AMG_REGION             AWS region for AMG (default: us-east-1)"
            echo "  OVERWRITE              Overwrite existing dashboards (default: true)"
            echo "  DATASOURCE_UID         Prometheus datasource UID for alerts (default: prometheus)"
            echo "  TEAMS_WEBHOOK_URL      Microsoft Teams incoming webhook URL (for notifications)"
            echo "  ALERT_EMAIL_RECIPIENTS Comma-separated email recipients (for notifications)"
            echo ""
            echo "Example:"
            echo "  AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh"
            echo "  AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh --dashboards-only"
            echo "  AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh --notifications-only"
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
if [ "$SKIP_VALIDATION" = false ]; then
    echo "Running pre-deployment validation..."
    if ! "${SCRIPT_DIR}/validate.sh"; then
        echo -e "${YELLOW}⚠ Validation failed, but continuing with deployment...${NC}"
        echo ""
    fi
fi

# Check AMG_WORKSPACE_ID
if [ -z "${AMG_WORKSPACE_ID:-}" ]; then
    echo -e "${RED}✗ AMG_WORKSPACE_ID not set${NC}"
    echo "Usage: AMG_WORKSPACE_ID=g-xxx ./scripts/deploy.sh"
    exit 1
fi

# Deploy SNS + Lambda infrastructure (required for notifications)
if [ "$DEPLOY_INFRA" = true ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Deploying Alert Notification Infrastructure${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    if [ -z "${TEAMS_WEBHOOK_URL:-}" ]; then
        echo -e "${YELLOW}⚠ TEAMS_WEBHOOK_URL not set, skipping infrastructure deployment${NC}"
        echo "  Set TEAMS_WEBHOOK_URL in .env to deploy SNS topics and Lambda function"
    else
        if "${SCRIPT_DIR}/deploy-sns-lambda.sh"; then
            echo -e "${GREEN}✓ Infrastructure deployed successfully${NC}"
        else
            echo -e "${RED}✗ Infrastructure deployment failed${NC}"
            exit 1
        fi
    fi
    echo ""
fi

# Deploy notifications (contact points + policies)
if [ "$DEPLOY_NOTIFICATIONS" = true ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Deploying Notifications to AMG${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    if [ -z "${STAKING_ALERT_TOPIC_ARN:-}" ]; then
        echo -e "${YELLOW}⚠ STAKING_ALERT_TOPIC_ARN not set, skipping notification deployment${NC}"
        echo "  Run deploy-sns-lambda.sh first, then set STAKING_ALERT_TOPIC_ARN in .env"
    else
        if "${SCRIPT_DIR}/deploy-notifications-amg.sh"; then
            echo -e "${GREEN}✓ Notifications deployed successfully${NC}"
        else
            echo -e "${RED}✗ Notification deployment failed${NC}"
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

    if "${SCRIPT_DIR}/deploy-dashboards-amg.sh"; then
        echo -e "${GREEN}✓ Dashboards deployed successfully${NC}"
    else
        echo -e "${RED}✗ Dashboard deployment failed${NC}"
        exit 1
    fi
    echo ""
fi

# Deploy alerts to Grafana
if [ "$DEPLOY_ALERTS" = true ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Deploying Alert Rules to Grafana${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    if "${SCRIPT_DIR}/deploy-alerts-amg.sh"; then
        echo -e "${GREEN}✓ Alert rules deployed successfully${NC}"
    else
        echo -e "${RED}✗ Alert rules deployment failed${NC}"
        exit 1
    fi
    echo ""
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Verify alerts in Grafana: Alerting -> Alert rules"
echo "  2. Verify contact points: Alerting -> Contact points"
echo "  3. Verify notification policies: Alerting -> Notification policies"
