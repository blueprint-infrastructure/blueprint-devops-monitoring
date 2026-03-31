#!/bin/bash

# Deploy SNS topics and Lambda function for Grafana alert notifications
# Creates the infrastructure needed to route AMG alerts to Teams and Email
#
# Architecture:
#   AMG Alert -> SNS Topic -> Lambda -> Teams (Adaptive Card)
#                                    -> SES Email (critical alerts only)
#
# Usage:
#   ./scripts/deploy-sns-lambda.sh           # Deploy infrastructure
#   ./scripts/deploy-sns-lambda.sh --test    # Send a test alert after deploy

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
TEAMS_WEBHOOK_URL="${TEAMS_WEBHOOK_URL:-}"
ALERT_EMAIL_SENDER="${ALERT_EMAIL_SENDER:-}"
ALERT_EMAIL_RECIPIENTS="${ALERT_EMAIL_RECIPIENTS:-}"
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-staking-alert}"
SNS_CRITICAL_TOPIC_NAME="${SNS_CRITICAL_TOPIC_NAME:-staking-alert-critical}"
LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-staking-alert-teams-notifier}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-staking-alert-teams-notifier-role}"

SEND_TEST=false
if [ "${1:-}" = "--test" ]; then
    SEND_TEST=true
fi

# Check for required tools
for tool in aws jq; do
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${RED}✗ ${tool} not found. Please install ${tool}.${NC}"
        exit 1
    fi
done

# Check for required environment variables
if [ -z "$AMG_WORKSPACE_ID" ]; then
    echo -e "${RED}✗ AMG_WORKSPACE_ID environment variable is not set${NC}"
    exit 1
fi

if [ -z "$TEAMS_WEBHOOK_URL" ]; then
    echo -e "${RED}✗ TEAMS_WEBHOOK_URL environment variable is not set${NC}"
    exit 1
fi

echo ""
echo "Deploying Alert Notification Infrastructure"
echo "=================================================="
echo "Region:   ${AMG_REGION}"
echo "Workspace: ${AMG_WORKSPACE_ID}"
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

# =============================================================================
# Step 1: Create SNS Topics
# =============================================================================

echo "Creating SNS topics..."

# Main topic (all alerts -> Teams only via Lambda)
SNS_TOPIC_ARN=$(aws sns create-topic \
    --name "$SNS_TOPIC_NAME" \
    --region "$AMG_REGION" \
    --query 'TopicArn' \
    --output text 2>/dev/null || echo "")

if [ -n "$SNS_TOPIC_ARN" ] && [ "$SNS_TOPIC_ARN" != "None" ]; then
    echo -e "  ${GREEN}✓ Topic: ${SNS_TOPIC_NAME} (${SNS_TOPIC_ARN})${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
else
    echo -e "  ${RED}✗ Failed to create topic: ${SNS_TOPIC_NAME}${NC}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Critical topic (critical alerts -> Teams via Lambda + Email)
SNS_CRITICAL_TOPIC_ARN=$(aws sns create-topic \
    --name "$SNS_CRITICAL_TOPIC_NAME" \
    --region "$AMG_REGION" \
    --query 'TopicArn' \
    --output text 2>/dev/null || echo "")

if [ -n "$SNS_CRITICAL_TOPIC_ARN" ] && [ "$SNS_CRITICAL_TOPIC_ARN" != "None" ]; then
    echo -e "  ${GREEN}✓ Topic: ${SNS_CRITICAL_TOPIC_NAME} (${SNS_CRITICAL_TOPIC_ARN})${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
else
    echo -e "  ${RED}✗ Failed to create topic: ${SNS_CRITICAL_TOPIC_NAME}${NC}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# =============================================================================
# Step 2: Set SNS Topic Policy (allow AMG workspace role to publish)
# =============================================================================

echo ""
echo "Configuring SNS topic policies..."

AMG_ROLE_ARN=$(aws grafana describe-workspace \
    --workspace-id "$AMG_WORKSPACE_ID" \
    --region "$AMG_REGION" \
    --query 'workspace.workspaceRoleArn' \
    --output text 2>/dev/null || echo "")

if [ -z "$AMG_ROLE_ARN" ] || [ "$AMG_ROLE_ARN" = "None" ]; then
    echo -e "  ${RED}✗ Failed to get AMG workspace role ARN${NC}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    echo -e "  ${GREEN}✓ AMG workspace role: ${AMG_ROLE_ARN}${NC}"

    # Get AWS account ID from the topic ARN
    AWS_ACCOUNT_ID=$(echo "$SNS_TOPIC_ARN" | cut -d: -f5)

    for TOPIC_ARN in "$SNS_TOPIC_ARN" "$SNS_CRITICAL_TOPIC_ARN"; do
        TOPIC_NAME=$(echo "$TOPIC_ARN" | rev | cut -d: -f1 | rev)
        POLICY=$(jq -n \
            --arg topic_arn "$TOPIC_ARN" \
            --arg amg_role "$AMG_ROLE_ARN" \
            --arg account_id "$AWS_ACCOUNT_ID" \
            '{
                Version: "2012-10-17",
                Statement: [
                    {
                        Sid: "AllowAccountAccess",
                        Effect: "Allow",
                        Principal: { AWS: ("arn:aws:iam::" + $account_id + ":root") },
                        Action: ["sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:Subscribe", "sns:ListSubscriptionsByTopic", "sns:Publish"],
                        Resource: $topic_arn
                    },
                    {
                        Sid: "AllowGrafanaPublish",
                        Effect: "Allow",
                        Principal: { AWS: $amg_role },
                        Action: "sns:Publish",
                        Resource: $topic_arn
                    }
                ]
            }')

        if aws sns set-topic-attributes \
            --topic-arn "$TOPIC_ARN" \
            --attribute-name Policy \
            --attribute-value "$POLICY" \
            --region "$AMG_REGION" 2>/dev/null; then
            echo -e "  ${GREEN}✓ Policy set for ${TOPIC_NAME}${NC}"
        else
            echo -e "  ${RED}✗ Failed to set policy for ${TOPIC_NAME}${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done
fi

# =============================================================================
# Step 3: Create IAM Role for Lambda
# =============================================================================

echo ""
echo "Setting up Lambda IAM role..."

LAMBDA_ROLE_ARN=""
if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" &>/dev/null; then
    LAMBDA_ROLE_ARN=$(aws iam get-role \
        --role-name "$LAMBDA_ROLE_NAME" \
        --query 'Role.Arn' \
        --output text)
    echo -e "  ${GREEN}✓ Role already exists: ${LAMBDA_ROLE_NAME}${NC}"
else
    TRUST_POLICY=$(jq -n '{
        Version: "2012-10-17",
        Statement: [{
            Effect: "Allow",
            Principal: { Service: "lambda.amazonaws.com" },
            Action: "sts:AssumeRole"
        }]
    }')

    LAMBDA_ROLE_ARN=$(aws iam create-role \
        --role-name "$LAMBDA_ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --query 'Role.Arn' \
        --output text 2>/dev/null || echo "")

    if [ -n "$LAMBDA_ROLE_ARN" ] && [ "$LAMBDA_ROLE_ARN" != "None" ]; then
        aws iam attach-role-policy \
            --role-name "$LAMBDA_ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
        echo -e "  ${GREEN}✓ Created role: ${LAMBDA_ROLE_NAME}${NC}"
        echo -e "  ${YELLOW}⏳ Waiting for IAM role propagation (10s)...${NC}"
        sleep 10
    else
        echo -e "  ${RED}✗ Failed to create IAM role${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# Add SES send permission (idempotent - put-role-policy overwrites)
if [ -n "$ALERT_EMAIL_SENDER" ]; then
    echo -e "  Adding SES send permission..."
    SES_POLICY=$(jq -n '{
        Version: "2012-10-17",
        Statement: [{
            Effect: "Allow",
            Action: ["ses:SendEmail", "ses:SendRawEmail"],
            Resource: "*"
        }]
    }')

    if aws iam put-role-policy \
        --role-name "$LAMBDA_ROLE_NAME" \
        --policy-name "ses-send-email" \
        --policy-document "$SES_POLICY" 2>/dev/null; then
        echo -e "  ${GREEN}✓ SES send permission added${NC}"
    else
        echo -e "  ${YELLOW}⚠ Could not add SES permission (may need manual IAM access)${NC}"
    fi
fi

# =============================================================================
# Step 4: Create or Update Lambda Function
# =============================================================================

echo ""
echo "Deploying Lambda function..."

LAMBDA_SRC="${REPO_ROOT}/lambda/teams-notifier/handler.py"
if [ ! -f "$LAMBDA_SRC" ]; then
    echo -e "  ${RED}✗ Lambda source not found: ${LAMBDA_SRC}${NC}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    # Package Lambda function
    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT
    cp "$LAMBDA_SRC" "$TMPDIR/"
    (cd "$TMPDIR" && zip -qr function.zip handler.py)

    # Build environment JSON via jq to safely handle special chars in URLs
    LAMBDA_ENV=$(jq -n \
        --arg url "$TEAMS_WEBHOOK_URL" \
        --arg sender "${ALERT_EMAIL_SENDER:-}" \
        --arg recipients "${ALERT_EMAIL_RECIPIENTS:-}" \
        --arg critical_topic "$SNS_CRITICAL_TOPIC_ARN" \
        --arg bot_secret "${TEAMS_BOT_SECRET_ARN:-}" \
        --arg rca_function "${RCA_LAMBDA_FUNCTION_NAME:-staking-alert-rca-analyzer}" \
        --arg ssm_regions "${SSM_REGIONS:-us-east-1,us-west-2,us-west-1,us-east-2}" \
        '{
            Variables: {
                TEAMS_WEBHOOK_URL: $url,
                ALERT_EMAIL_SENDER: $sender,
                ALERT_EMAIL_RECIPIENTS: $recipients,
                STAKING_ALERT_CRITICAL_TOPIC_ARN: $critical_topic,
                TEAMS_BOT_SECRET_ARN: $bot_secret,
                RCA_LAMBDA_FUNCTION_NAME: $rca_function,
                SSM_REGIONS: $ssm_regions
            }
        }')

    if aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" --region "$AMG_REGION" &>/dev/null; then
        # Update existing function
        aws lambda update-function-code \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --zip-file "fileb://${TMPDIR}/function.zip" \
            --region "$AMG_REGION" \
            --output text --query 'FunctionArn' >/dev/null 2>&1

        # Wait for update to complete before changing configuration
        aws lambda wait function-updated \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --region "$AMG_REGION" 2>/dev/null || sleep 5

        aws lambda update-function-configuration \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --environment "$LAMBDA_ENV" \
            --region "$AMG_REGION" \
            --output text --query 'FunctionArn' >/dev/null 2>&1

        echo -e "  ${GREEN}✓ Updated: ${LAMBDA_FUNCTION_NAME}${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        # Create new function
        LAMBDA_ARN=$(aws lambda create-function \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --runtime python3.12 \
            --handler handler.lambda_handler \
            --role "$LAMBDA_ROLE_ARN" \
            --zip-file "fileb://${TMPDIR}/function.zip" \
            --timeout 30 \
            --memory-size 128 \
            --environment "$LAMBDA_ENV" \
            --region "$AMG_REGION" \
            --query 'FunctionArn' \
            --output text 2>/dev/null || echo "")

        if [ -n "$LAMBDA_ARN" ] && [ "$LAMBDA_ARN" != "None" ]; then
            echo -e "  ${GREEN}✓ Created: ${LAMBDA_FUNCTION_NAME}${NC}"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo -e "  ${RED}✗ Failed to create Lambda function${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
fi

# Get Lambda ARN
LAMBDA_ARN=$(aws lambda get-function \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --region "$AMG_REGION" \
    --query 'Configuration.FunctionArn' \
    --output text 2>/dev/null || echo "")

# =============================================================================
# Step 5: Subscribe Lambda to SNS Topics
# =============================================================================

echo ""
echo "Subscribing Lambda to SNS topics..."

for TOPIC_ARN in "$SNS_TOPIC_ARN" "$SNS_CRITICAL_TOPIC_ARN"; do
    TOPIC_NAME=$(echo "$TOPIC_ARN" | rev | cut -d: -f1 | rev)

    # Check if Lambda is already subscribed
    EXISTING_SUB=$(aws sns list-subscriptions-by-topic \
        --topic-arn "$TOPIC_ARN" \
        --region "$AMG_REGION" \
        --query "Subscriptions[?Protocol=='lambda' && Endpoint=='${LAMBDA_ARN}'].SubscriptionArn" \
        --output text 2>/dev/null || echo "")

    if [ -n "$EXISTING_SUB" ] && [ "$EXISTING_SUB" != "None" ] && [ "$EXISTING_SUB" != "" ]; then
        echo -e "  ${GREEN}✓ Lambda already subscribed to ${TOPIC_NAME}${NC}"
    else
        if aws sns subscribe \
            --topic-arn "$TOPIC_ARN" \
            --protocol lambda \
            --notification-endpoint "$LAMBDA_ARN" \
            --region "$AMG_REGION" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓ Subscribed Lambda to ${TOPIC_NAME}${NC}"
        else
            echo -e "  ${RED}✗ Failed to subscribe Lambda to ${TOPIC_NAME}${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi

    # Grant SNS permission to invoke Lambda (idempotent check)
    STATEMENT_ID="sns-invoke-${TOPIC_NAME}"
    EXISTING_POLICY=$(aws lambda get-policy \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --region "$AMG_REGION" 2>/dev/null || echo "")

    if echo "$EXISTING_POLICY" | grep -q "$STATEMENT_ID"; then
        echo -e "  ${GREEN}✓ Lambda invoke permission already exists for ${TOPIC_NAME}${NC}"
    else
        if aws lambda add-permission \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --statement-id "$STATEMENT_ID" \
            --action "lambda:InvokeFunction" \
            --principal "sns.amazonaws.com" \
            --source-arn "$TOPIC_ARN" \
            --region "$AMG_REGION" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓ Granted SNS invoke permission for ${TOPIC_NAME}${NC}"
        else
            echo -e "  ${YELLOW}⚠ Could not add invoke permission for ${TOPIC_NAME} (may already exist)${NC}"
        fi
    fi
done

# =============================================================================
# Step 6: SES Email Configuration Summary
# =============================================================================

echo ""
if [ -n "$ALERT_EMAIL_SENDER" ] && [ -n "$ALERT_EMAIL_RECIPIENTS" ]; then
    echo -e "  ${GREEN}✓ SES email: ${ALERT_EMAIL_SENDER} -> ${ALERT_EMAIL_RECIPIENTS}${NC}"
else
    echo -e "  ${YELLOW}⚠ SES email not configured (set ALERT_EMAIL_SENDER and ALERT_EMAIL_RECIPIENTS in .env)${NC}"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=================================================="
echo "Infrastructure Deployment Summary"
echo "=================================================="
echo -e "${GREEN}✓ SNS Topic:          ${SNS_TOPIC_ARN}${NC}"
echo -e "${GREEN}✓ SNS Critical Topic: ${SNS_CRITICAL_TOPIC_ARN}${NC}"
echo -e "${GREEN}✓ Lambda Function:    ${LAMBDA_FUNCTION_NAME}${NC}"
echo ""
echo "Add to your .env file:"
echo "  STAKING_ALERT_TOPIC_ARN=${SNS_TOPIC_ARN}"
echo "  STAKING_ALERT_CRITICAL_TOPIC_ARN=${SNS_CRITICAL_TOPIC_ARN}"

if [ $FAIL_COUNT -gt 0 ]; then
    echo ""
    echo -e "${RED}✗ Failed steps: ${FAIL_COUNT}${NC}"
fi

# =============================================================================
# Optional: Send Test Alert
# =============================================================================

if [ "$SEND_TEST" = true ]; then
    echo ""
    echo "Sending test alert to ${SNS_TOPIC_NAME}..."

    TEST_MESSAGE=$(jq -n '{
        status: "firing",
        title: "Test Alert",
        commonLabels: {
            alertname: "TestAlert",
            severity: "warning"
        },
        alerts: [{
            status: "firing",
            labels: {
                alertname: "TestAlert",
                severity: "warning",
                instance: "test-instance"
            },
            annotations: {
                summary: "Test alert from deploy-sns-lambda.sh",
                description: "This is a test alert to verify the Teams notification pipeline."
            }
        }]
    }')

    if aws sns publish \
        --topic-arn "$SNS_TOPIC_ARN" \
        --message "$TEST_MESSAGE" \
        --subject "Grafana Alert Test" \
        --region "$AMG_REGION" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Test message published. Check your Teams channel.${NC}"
    else
        echo -e "  ${RED}✗ Failed to publish test message${NC}"
    fi
fi
