#!/bin/bash

# Create IAM Role for Notification Service to access SNS
# This uses IRSA (IAM Roles for Service Accounts) to grant SNS publish permissions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/infrastructure/config"
CONFIG_FILE="$CONFIG_DIR/config.env"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-eventsphere-cluster}"
ROLE_NAME="eventsphere-notification-service-role"
POLICY_NAME="eventsphere-notification-sns-policy"
NAMESPACE="prod"
SERVICE_ACCOUNT="notification-service-sa"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Creating IAM Role for Notification Service${NC}"
echo ""

# Get OIDC provider
echo -e "${YELLOW}Getting OIDC provider...${NC}"
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
echo -e "${GREEN}✅ OIDC Provider: $OIDC_PROVIDER${NC}"
echo ""

# Create trust policy
echo -e "${YELLOW}Creating trust policy...${NC}"
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

# Create IAM role
if aws iam get-role --role-name $ROLE_NAME &> /dev/null; then
    echo -e "${YELLOW}⚠️  Role already exists: $ROLE_NAME${NC}"
else
    echo "$TRUST_POLICY" > trust-policy.json
    aws iam create-role \
        --role-name $ROLE_NAME \
        --assume-role-policy-document file://trust-policy.json \
        --tags Key=Project,Value=EventSphere Key=Service,Value=notification-service
    rm -f trust-policy.json
    echo -e "${GREEN}✅ Created IAM role: $ROLE_NAME${NC}"
fi
echo ""

# Create SNS publish policy
echo -e "${YELLOW}Creating SNS publish policy...${NC}"
POLICY_DOCUMENT=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sns:Publish"
      ],
      "Resource": "arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:eventsphere-notifications"
    }
  ]
}
EOF
)

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn $POLICY_ARN &> /dev/null; then
    echo -e "${YELLOW}⚠️  Policy already exists: $POLICY_NAME${NC}"
else
    echo "$POLICY_DOCUMENT" > policy.json
    aws iam create-policy \
        --policy-name $POLICY_NAME \
        --policy-document file://policy.json
    rm -f policy.json
    echo -e "${GREEN}✅ Created IAM policy: $POLICY_NAME${NC}"
fi
echo ""

# Attach policy to role
echo -e "${YELLOW}Attaching policy to role...${NC}"
aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn $POLICY_ARN 2>/dev/null || echo -e "${YELLOW}⚠️  Policy already attached${NC}"
echo -e "${GREEN}✅ Policy attached${NC}"
echo ""

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ IAM Role Setup Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Role ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
echo ""
echo "Next steps:"
echo "1. The service account annotation is already configured in rbac.yaml"
echo "2. Deploy/restart notification service to use the new role"
echo ""
