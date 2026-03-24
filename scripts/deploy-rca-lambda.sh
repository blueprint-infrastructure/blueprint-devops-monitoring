#!/bin/bash

# Deploy the RCA (Root Cause Analysis) Lambda function
# Automated alert diagnosis via SSM + Claude API + AMP metrics
#
# Architecture:
#   teams-notifier Lambda -> RCA Lambda (async)
#       -> SSM send-command (diagnostics)
#       -> AMP query (metric trends)
#       -> Claude API (analysis)
#       -> Power Automate webhook (reply-in-thread)
#
# Prerequisites:
#   1. Anthropic API key in Secrets Manager
#   2. Power Automate reply webhook URL (for reply-in-thread)
#   3. teams-notifier Lambda already deployed
#
# Usage:
#   ./scripts/deploy-rca-lambda.sh           # Deploy RCA Lambda
#   ./scripts/deploy-rca-lambda.sh --test    # Deploy and send test invocation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env file if it exists
if [ -f "${REPO_ROOT}/.env" ]; then
    set -a
    source "${REPO_ROOT}/.env"
    set +a
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
AMG_REGION="${AMG_REGION:-${AWS_REGION:-us-east-1}}"
AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-ws-fdcbcf55-ed2c-4069-adad-c385e068d992}"
AMP_REGION="${AMP_REGION:-us-east-1}"
TEAMS_WEBHOOK_URL="${TEAMS_WEBHOOK_URL:-}"
TEAMS_REPLY_WEBHOOK_URL="${TEAMS_REPLY_WEBHOOK_URL:-}"
ANTHROPIC_SECRET_ARN="${ANTHROPIC_SECRET_ARN:-}"
RCA_FUNCTION_NAME="${RCA_LAMBDA_FUNCTION_NAME:-staking-alert-rca-analyzer}"
RCA_ROLE_NAME="${RCA_ROLE_NAME:-staking-alert-rca-role}"
NOTIFIER_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-staking-alert-teams-notifier}"
NOTIFIER_ROLE_NAME="${LAMBDA_ROLE_NAME:-staking-alert-teams-notifier-role}"

SEND_TEST=false
if [ "${1:-}" = "--test" ]; then
    SEND_TEST=true
fi

# Check for required tools
for tool in aws jq zip; do
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${RED}✗ ${tool} not found. Please install ${tool}.${NC}"
        exit 1
    fi
done

# Check for required secrets
if [ -z "$ANTHROPIC_SECRET_ARN" ]; then
    echo -e "${RED}✗ ANTHROPIC_SECRET_ARN not set${NC}"
    echo ""
    echo "Create the secret first:"
    echo "  aws secretsmanager create-secret --name anthropic-api-key \\"
    echo "    --secret-string '{\"api_key\":\"sk-ant-xxx\"}' --region ${AMG_REGION}"
    exit 1
fi

if [ -z "$TEAMS_REPLY_WEBHOOK_URL" ]; then
    echo -e "${YELLOW}⚠ TEAMS_REPLY_WEBHOOK_URL not set (reply-in-thread will be disabled)${NC}"
    echo ""
    echo "To enable, create a Power Automate reply flow and set the webhook URL in .env:"
    echo "  TEAMS_REPLY_WEBHOOK_URL='https://...your-reply-flow-webhook-url...'"
    echo ""
fi

echo ""
echo "Deploying RCA Lambda"
echo "=================================================="
echo "Region:    ${AMG_REGION}"
echo "Function:  ${RCA_FUNCTION_NAME}"
echo ""

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "")
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo -e "${RED}✗ Failed to get AWS account ID${NC}"
    exit 1
fi

# =============================================================================
# Step 1: Create IAM Role for RCA Lambda
# =============================================================================

echo "Setting up IAM role..."

RCA_ROLE_ARN=""
if aws iam get-role --role-name "$RCA_ROLE_NAME" &>/dev/null; then
    RCA_ROLE_ARN=$(aws iam get-role \
        --role-name "$RCA_ROLE_NAME" \
        --query 'Role.Arn' \
        --output text)
    echo -e "  ${GREEN}✓ Role already exists: ${RCA_ROLE_NAME}${NC}"
else
    TRUST_POLICY=$(jq -n '{
        Version: "2012-10-17",
        Statement: [{
            Effect: "Allow",
            Principal: { Service: "lambda.amazonaws.com" },
            Action: "sts:AssumeRole"
        }]
    }')

    RCA_ROLE_ARN=$(aws iam create-role \
        --role-name "$RCA_ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --query 'Role.Arn' \
        --output text 2>/dev/null || echo "")

    if [ -n "$RCA_ROLE_ARN" ] && [ "$RCA_ROLE_ARN" != "None" ]; then
        aws iam attach-role-policy \
            --role-name "$RCA_ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
        echo -e "  ${GREEN}✓ Created role: ${RCA_ROLE_NAME}${NC}"
        echo -e "  ${YELLOW}⏳ Waiting for IAM role propagation (10s)...${NC}"
        sleep 10
    else
        echo -e "  ${RED}✗ Failed to create IAM role${NC}"
        exit 1
    fi
fi

# Add inline policy for SSM, AMP, and Secrets Manager
echo -e "  Adding SSM/AMP/Secrets permissions..."
RCA_POLICY=$(jq -n \
    --arg amp_arn "arn:aws:aps:${AMP_REGION}:${AWS_ACCOUNT_ID}:workspace/${AMP_WORKSPACE_ID}" \
    '{
    Version: "2012-10-17",
    Statement: [
        {
            Sid: "SSMCommands",
            Effect: "Allow",
            Action: ["ssm:SendCommand", "ssm:GetCommandInvocation"],
            Resource: [
                "arn:aws:ssm:*:*:document/AWS-RunShellScript",
                "arn:aws:ec2:*:*:instance/*",
                "arn:aws:ssm:*:*:managed-instance/*"
            ]
        },
        {
            Sid: "AMPQuery",
            Effect: "Allow",
            Action: ["aps:QueryMetrics"],
            Resource: $amp_arn
        },
        {
            Sid: "SecretsManagerRead",
            Effect: "Allow",
            Action: "secretsmanager:GetSecretValue",
            Resource: "*"
        }
    ]
}')

if aws iam put-role-policy \
    --role-name "$RCA_ROLE_NAME" \
    --policy-name "rca-permissions" \
    --policy-document "$RCA_POLICY" 2>/dev/null; then
    echo -e "  ${GREEN}✓ Permissions added (SSM, AMP, SecretsManager)${NC}"
else
    echo -e "  ${RED}✗ Failed to add permissions${NC}"
fi

# =============================================================================
# Step 2: Package and Deploy RCA Lambda
# =============================================================================

echo ""
echo "Deploying Lambda function..."

RCA_SRC="${REPO_ROOT}/lambda/rca-analyzer/handler.py"
RUNBOOKS_DIR="${REPO_ROOT}/runbooks"

if [ ! -f "$RCA_SRC" ]; then
    echo -e "  ${RED}✗ Lambda source not found: ${RCA_SRC}${NC}"
    exit 1
fi

# Package Lambda function with runbooks
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cp "$RCA_SRC" "$TMPDIR/"

# Bundle runbook files
if [ -d "$RUNBOOKS_DIR" ]; then
    mkdir -p "$TMPDIR/runbooks"
    cp "$RUNBOOKS_DIR"/*.md "$TMPDIR/runbooks/" 2>/dev/null || true
    RUNBOOK_COUNT=$(ls "$TMPDIR/runbooks/"*.md 2>/dev/null | wc -l)
    echo -e "  ${GREEN}✓ Bundled ${RUNBOOK_COUNT} runbooks${NC}"
fi

(cd "$TMPDIR" && zip -qr function.zip handler.py runbooks/)

# Build environment JSON
LAMBDA_ENV=$(jq -n \
    --arg webhook "${TEAMS_WEBHOOK_URL:-}" \
    --arg reply_webhook "${TEAMS_REPLY_WEBHOOK_URL:-}" \
    --arg anthropic_secret "${ANTHROPIC_SECRET_ARN}" \
    --arg amp_workspace "${AMP_WORKSPACE_ID}" \
    --arg amp_region "${AMP_REGION}" \
    --arg ssm_region "${AMG_REGION}" \
    '{
        Variables: {
            TEAMS_WEBHOOK_URL: $webhook,
            TEAMS_REPLY_WEBHOOK_URL: $reply_webhook,
            ANTHROPIC_SECRET_ARN: $anthropic_secret,
            AMP_WORKSPACE_ID: $amp_workspace,
            AMP_REGION: $amp_region,
            SSM_REGION: $ssm_region
        }
    }')

if aws lambda get-function --function-name "$RCA_FUNCTION_NAME" --region "$AMG_REGION" &>/dev/null; then
    # Update existing function
    aws lambda update-function-code \
        --function-name "$RCA_FUNCTION_NAME" \
        --zip-file "fileb://${TMPDIR}/function.zip" \
        --region "$AMG_REGION" \
        --output text --query 'FunctionArn' >/dev/null 2>&1

    aws lambda wait function-updated \
        --function-name "$RCA_FUNCTION_NAME" \
        --region "$AMG_REGION" 2>/dev/null || sleep 5

    aws lambda update-function-configuration \
        --function-name "$RCA_FUNCTION_NAME" \
        --environment "$LAMBDA_ENV" \
        --timeout 180 \
        --memory-size 256 \
        --region "$AMG_REGION" \
        --output text --query 'FunctionArn' >/dev/null 2>&1

    echo -e "  ${GREEN}✓ Updated: ${RCA_FUNCTION_NAME}${NC}"
else
    # Create new function
    RCA_ARN=$(aws lambda create-function \
        --function-name "$RCA_FUNCTION_NAME" \
        --runtime python3.12 \
        --handler handler.lambda_handler \
        --role "$RCA_ROLE_ARN" \
        --zip-file "fileb://${TMPDIR}/function.zip" \
        --timeout 180 \
        --memory-size 256 \
        --environment "$LAMBDA_ENV" \
        --region "$AMG_REGION" \
        --query 'FunctionArn' \
        --output text 2>/dev/null || echo "")

    if [ -n "$RCA_ARN" ] && [ "$RCA_ARN" != "None" ]; then
        echo -e "  ${GREEN}✓ Created: ${RCA_FUNCTION_NAME}${NC}"
    else
        echo -e "  ${RED}✗ Failed to create Lambda function${NC}"
        exit 1
    fi
fi

# Get RCA Lambda ARN
RCA_ARN=$(aws lambda get-function \
    --function-name "$RCA_FUNCTION_NAME" \
    --region "$AMG_REGION" \
    --query 'Configuration.FunctionArn' \
    --output text 2>/dev/null || echo "")

# =============================================================================
# Step 3: Update teams-notifier to invoke RCA Lambda
# =============================================================================

echo ""
echo "Updating teams-notifier..."

# Add lambda:InvokeFunction permission to notifier role
if [ -n "$RCA_ARN" ]; then
    INVOKE_POLICY=$(jq -n --arg rca_arn "$RCA_ARN" '{
        Version: "2012-10-17",
        Statement: [{
            Effect: "Allow",
            Action: "lambda:InvokeFunction",
            Resource: $rca_arn
        }]
    }')

    if aws iam put-role-policy \
        --role-name "$NOTIFIER_ROLE_NAME" \
        --policy-name "invoke-rca-lambda" \
        --policy-document "$INVOKE_POLICY" 2>/dev/null; then
        echo -e "  ${GREEN}✓ Added invoke permission to ${NOTIFIER_ROLE_NAME}${NC}"
    else
        echo -e "  ${YELLOW}⚠ Could not add invoke permission (may need manual IAM access)${NC}"
    fi
fi

# Add Secrets Manager permission to notifier role (for Anthropic API key)
if [ -n "$TEAMS_REPLY_WEBHOOK_URL" ]; then
    SECRETS_POLICY=$(jq -n '{
        Version: "2012-10-17",
        Statement: [{
            Effect: "Allow",
            Action: "secretsmanager:GetSecretValue",
            Resource: "*"
        }]
    }')

    if aws iam put-role-policy \
        --role-name "$NOTIFIER_ROLE_NAME" \
        --policy-name "secrets-manager-read" \
        --policy-document "$SECRETS_POLICY" 2>/dev/null; then
        echo -e "  ${GREEN}✓ Added SecretsManager permission to ${NOTIFIER_ROLE_NAME}${NC}"
    else
        echo -e "  ${YELLOW}⚠ Could not add SecretsManager permission${NC}"
    fi
fi

# Update teams-notifier environment variables
echo -e "  Updating notifier environment variables..."

# Get current env vars and merge new ones
CURRENT_ENV=$(aws lambda get-function-configuration \
    --function-name "$NOTIFIER_FUNCTION_NAME" \
    --region "$AMG_REGION" \
    --query 'Environment.Variables' \
    --output json 2>/dev/null || echo "{}")

UPDATED_ENV=$(echo "$CURRENT_ENV" | jq \
    --arg rca_fn "$RCA_FUNCTION_NAME" \
    '. + {
        RCA_LAMBDA_FUNCTION_NAME: $rca_fn
    }')

# Wait for any in-progress updates
aws lambda wait function-updated \
    --function-name "$NOTIFIER_FUNCTION_NAME" \
    --region "$AMG_REGION" 2>/dev/null || sleep 3

if aws lambda update-function-configuration \
    --function-name "$NOTIFIER_FUNCTION_NAME" \
    --environment "{\"Variables\": $UPDATED_ENV}" \
    --timeout 60 \
    --region "$AMG_REGION" \
    --output text --query 'FunctionArn' >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓ Updated notifier: RCA_LAMBDA_FUNCTION_NAME=${RCA_FUNCTION_NAME}${NC}"
    echo -e "  ${GREEN}✓ Updated notifier: timeout=60s${NC}"
else
    echo -e "  ${YELLOW}⚠ Could not update notifier config (may need to update manually)${NC}"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=================================================="
echo "RCA Lambda Deployment Summary"
echo "=================================================="
echo -e "${GREEN}✓ RCA Lambda:     ${RCA_FUNCTION_NAME} (256MB, 180s timeout)${NC}"
echo -e "${GREEN}✓ IAM Role:       ${RCA_ROLE_NAME}${NC}"
echo -e "${GREEN}✓ Notifier:       ${NOTIFIER_FUNCTION_NAME} (updated with RCA trigger)${NC}"
echo ""
echo "Secrets:"
echo -e "  Anthropic API:  ${ANTHROPIC_SECRET_ARN}"
if [ -n "$TEAMS_REPLY_WEBHOOK_URL" ]; then
    echo -e "  Reply webhook:  ${TEAMS_REPLY_WEBHOOK_URL}"
else
    echo -e "  ${YELLOW}Reply webhook:  Not configured (reply-in-thread disabled)${NC}"
fi

# =============================================================================
# Optional: Test RCA Lambda
# =============================================================================

if [ "$SEND_TEST" = true ]; then
    echo ""
    echo "Sending test invocation to ${RCA_FUNCTION_NAME}..."

    TEST_PAYLOAD=$(jq -n '{
        alertname: "TestAlert",
        instance: "test-instance",
        instance_id: "i-test123",
        chain: "test",
        severity: "warning",
        status: "firing",
        description: "This is a test alert to verify the RCA pipeline.",
        summary: "Test alert from deploy-rca-lambda.sh",
        runbook_url: "",
        labels: {
            alertname: "TestAlert",
            instance: "test-instance",
            instance_id: "i-test123",
            chain: "test",
            severity: "warning"
        },
        parent_message_id: null
    }')

    if aws lambda invoke \
        --function-name "$RCA_FUNCTION_NAME" \
        --payload "$TEST_PAYLOAD" \
        --invocation-type RequestResponse \
        --region "$AMG_REGION" \
        /tmp/rca-test-output.json >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Test invocation completed${NC}"
        echo "  Output: $(cat /tmp/rca-test-output.json)"
    else
        echo -e "  ${RED}✗ Test invocation failed${NC}"
    fi
fi
