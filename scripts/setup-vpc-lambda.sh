#!/usr/bin/env bash
# =============================================================================
# setup-vpc-lambda.sh
# Migrate staking-alert Lambda functions into bpt-shared-vpc with NAT Gateway
# so outbound traffic uses a fixed Elastic IP (bypasses Cloudflare Lambda block).
#
# Usage: bash scripts/setup-vpc-lambda.sh
# Requires: aws CLI with permissions for ec2, lambda, iam
# =============================================================================
set -euo pipefail

VPC_ID="vpc-017f09d9fbe1bb51d"
REGION="us-east-1"
PUBLIC_SUBNET_1A="subnet-03acc54c38c1707b0"   # bpt-shared-public-1a (us-east-1a)
PUBLIC_SUBNET_1B="subnet-0178e887f60ebc854"   # bpt-shared-public-1b (us-east-1b)

LAMBDA_FUNCTIONS=(
  "staking-alert-upgrade-analyzer"
  "staking-alert-docs-fetcher"
  "staking-alert-rca-analyzer"
  "staking-alert-bot-endpoint"
  "staking-alert-teams-notifier"
)

LAMBDA_ROLE_NAME="staking-alert-rca-role"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

echo "=============================================="
echo " VPC Lambda Migration: bpt-shared-vpc"
echo "=============================================="
echo ""

# ── Step 1: Private subnets ──────────────────────────────────────────────────
echo "=== Step 1: Private subnets ==="

# Check if already exist
EXISTING_PRIVATE=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=10.0.3.0/24" \
  --region $REGION --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo "None")

if [ "$EXISTING_PRIVATE" != "None" ] && [ -n "$EXISTING_PRIVATE" ]; then
  warn "Private subnets already exist, skipping creation"
  PRIVATE_SUBNET_1A="$EXISTING_PRIVATE"
  PRIVATE_SUBNET_1B=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=10.0.4.0/24" \
    --region $REGION --query 'Subnets[0].SubnetId' --output text)
else
  PRIVATE_SUBNET_1A=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID --cidr-block 10.0.3.0/24 \
    --availability-zone us-east-1a --region $REGION \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 create-tags --resources $PRIVATE_SUBNET_1A --region $REGION --tags \
    Key=Name,Value=bpt-shared-private-1a Key=ManagedBy,Value=cli Key=Environment,Value=shared

  PRIVATE_SUBNET_1B=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID --cidr-block 10.0.4.0/24 \
    --availability-zone us-east-1b --region $REGION \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 create-tags --resources $PRIVATE_SUBNET_1B --region $REGION --tags \
    Key=Name,Value=bpt-shared-private-1b Key=ManagedBy,Value=cli Key=Environment,Value=shared
fi

ok "Private subnet 1a: $PRIVATE_SUBNET_1A (10.0.3.0/24)"
ok "Private subnet 1b: $PRIVATE_SUBNET_1B (10.0.4.0/24)"

# ── Step 2: Elastic IP ───────────────────────────────────────────────────────
echo ""
echo "=== Step 2: Elastic IP for NAT Gateway ==="

# Check if an EIP tagged for NAT already exists
EXISTING_EIP_ALLOC=$(aws ec2 describe-addresses --region $REGION \
  --filters "Name=tag:Name,Values=bpt-shared-nat-eip" \
  --query 'Addresses[0].AllocationId' --output text 2>/dev/null || echo "None")

if [ "$EXISTING_EIP_ALLOC" != "None" ] && [ -n "$EXISTING_EIP_ALLOC" ]; then
  warn "EIP already exists: $EXISTING_EIP_ALLOC"
  EIP_ALLOC="$EXISTING_EIP_ALLOC"
  EIP_PUBLIC=$(aws ec2 describe-addresses --region $REGION \
    --filters "Name=tag:Name,Values=bpt-shared-nat-eip" \
    --query 'Addresses[0].PublicIp' --output text)
else
  EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --region $REGION \
    --query 'AllocationId' --output text)
  aws ec2 create-tags --resources $EIP_ALLOC --region $REGION --tags \
    Key=Name,Value=bpt-shared-nat-eip Key=ManagedBy,Value=cli
  EIP_PUBLIC=$(aws ec2 describe-addresses --allocation-ids $EIP_ALLOC \
    --region $REGION --query 'Addresses[0].PublicIp' --output text)
fi

ok "Elastic IP: $EIP_PUBLIC (alloc: $EIP_ALLOC)"

# ── Step 3: NAT Gateway ──────────────────────────────────────────────────────
echo ""
echo "=== Step 3: NAT Gateway (in public subnet) ==="

EXISTING_NAT=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
  --region $REGION --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null || echo "None")

if [ "$EXISTING_NAT" != "None" ] && [ -n "$EXISTING_NAT" ]; then
  warn "NAT Gateway already exists: $EXISTING_NAT"
  NAT_GW_ID="$EXISTING_NAT"
else
  NAT_GW_ID=$(aws ec2 create-nat-gateway \
    --subnet-id $PUBLIC_SUBNET_1A \
    --allocation-id $EIP_ALLOC \
    --region $REGION \
    --query 'NatGateway.NatGatewayId' --output text)
  aws ec2 create-tags --resources $NAT_GW_ID --region $REGION --tags \
    Key=Name,Value=bpt-shared-nat-gw Key=ManagedBy,Value=cli

  echo "  Waiting for NAT Gateway to become available (2-3 min)..."
  aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID --region $REGION
fi

ok "NAT Gateway: $NAT_GW_ID → $EIP_PUBLIC"

# ── Step 4: Private route table ──────────────────────────────────────────────
echo ""
echo "=== Step 4: Private route table ==="

EXISTING_PRIVATE_RTB=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=bpt-shared-private-rtb" \
  --region $REGION --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "None")

if [ "$EXISTING_PRIVATE_RTB" != "None" ] && [ -n "$EXISTING_PRIVATE_RTB" ]; then
  warn "Private route table already exists: $EXISTING_PRIVATE_RTB"
  PRIVATE_RTB="$EXISTING_PRIVATE_RTB"
else
  PRIVATE_RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $REGION \
    --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-tags --resources $PRIVATE_RTB --region $REGION --tags \
    Key=Name,Value=bpt-shared-private-rtb Key=ManagedBy,Value=cli

  # Default route → NAT Gateway
  aws ec2 create-route \
    --route-table-id $PRIVATE_RTB \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id $NAT_GW_ID \
    --region $REGION >/dev/null

  # Associate private subnets
  aws ec2 associate-route-table --route-table-id $PRIVATE_RTB \
    --subnet-id $PRIVATE_SUBNET_1A --region $REGION >/dev/null
  aws ec2 associate-route-table --route-table-id $PRIVATE_RTB \
    --subnet-id $PRIVATE_SUBNET_1B --region $REGION >/dev/null
fi

ok "Private route table: $PRIVATE_RTB (0.0.0.0/0 → $NAT_GW_ID)"

# ── Step 5: Lambda security group ────────────────────────────────────────────
echo ""
echo "=== Step 5: Lambda security group ==="

EXISTING_SG=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=staking-alert-lambda-sg" \
  --region $REGION --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$EXISTING_SG" != "None" ] && [ -n "$EXISTING_SG" ]; then
  warn "Security group already exists: $EXISTING_SG"
  LAMBDA_SG="$EXISTING_SG"
else
  LAMBDA_SG=$(aws ec2 create-security-group \
    --group-name staking-alert-lambda-sg \
    --description "Staking alert Lambda functions - allows all outbound" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --query 'GroupId' --output text)
  aws ec2 create-tags --resources $LAMBDA_SG --region $REGION --tags \
    Key=Name,Value=staking-alert-lambda-sg Key=ManagedBy,Value=cli

  # Allow all outbound (default is deny outbound for new SGs in some configs)
  aws ec2 authorize-security-group-egress \
    --group-id $LAMBDA_SG --region $REGION \
    --ip-permissions '[{"IpProtocol": "-1", "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]' \
    2>/dev/null || true  # May already exist
fi

ok "Lambda security group: $LAMBDA_SG (all outbound allowed)"

# ── Step 6: IAM — add EC2 VPC permissions to Lambda role ────────────────────
echo ""
echo "=== Step 6: IAM — VPC network interface permissions ==="

cat > /tmp/lambda-vpc-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeVpcs"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# Check if policy already attached
EXISTING_POLICY=$(aws iam list-role-policies \
  --role-name $LAMBDA_ROLE_NAME \
  --query 'PolicyNames' --output text 2>/dev/null || echo "")

if echo "$EXISTING_POLICY" | grep -q "LambdaVPCAccess"; then
  warn "VPC IAM policy already attached"
else
  aws iam put-role-policy \
    --role-name $LAMBDA_ROLE_NAME \
    --policy-name LambdaVPCAccess \
    --policy-document file:///tmp/lambda-vpc-policy.json
fi

rm -f /tmp/lambda-vpc-policy.json
ok "IAM: ec2:CreateNetworkInterface + related permissions added to $LAMBDA_ROLE_NAME"

# ── Step 7: Update Lambda functions ──────────────────────────────────────────
echo ""
echo "=== Step 7: Attach Lambda functions to VPC ==="

for FN in "${LAMBDA_FUNCTIONS[@]}"; do
  # Check if function exists
  if ! aws lambda get-function --function-name $FN --region $REGION >/dev/null 2>&1; then
    warn "Function not found, skipping: $FN"
    continue
  fi

  # Check current VPC config
  CURRENT_VPC=$(aws lambda get-function-configuration \
    --function-name $FN --region $REGION \
    --query 'VpcConfig.VpcId' --output text 2>/dev/null || echo "")

  if [ "$CURRENT_VPC" = "$VPC_ID" ]; then
    warn "$FN: already in VPC $VPC_ID"
    continue
  fi

  echo "  Updating $FN..."
  aws lambda update-function-configuration \
    --function-name $FN \
    --region $REGION \
    --vpc-config "SubnetIds=$PRIVATE_SUBNET_1A,$PRIVATE_SUBNET_1B,SecurityGroupIds=$LAMBDA_SG" \
    --output text --query 'FunctionName' >/dev/null

  # Wait for update to complete
  aws lambda wait function-updated --function-name $FN --region $REGION
  ok "$FN → VPC attached"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " Migration Complete"
echo "=============================================="
echo ""
echo "  VPC:              $VPC_ID"
echo "  Private subnets:  $PRIVATE_SUBNET_1A (1a), $PRIVATE_SUBNET_1B (1b)"
echo "  NAT Gateway:      $NAT_GW_ID"
echo "  Outbound IP:      $EIP_PUBLIC  ← Notion will see this IP"
echo "  Security Group:   $LAMBDA_SG"
echo ""
echo "All Lambda functions now route outbound traffic through:"
echo "  $EIP_PUBLIC (Elastic IP, not in AWS Lambda IP range)"
echo ""
echo "Next: Test Notion writes by clicking the Upgrade Plan button in Teams."
