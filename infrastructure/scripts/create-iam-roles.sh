#!/bin/bash

# Script to create IAM roles for EventSphere EKS cluster service accounts
# This script creates IRSA (IAM Roles for Service Accounts) roles for:
# - Fluent Bit (CloudWatch Logs access)
# - External Secrets Operator (Secrets Manager access)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CLUSTER_NAME="eventsphere-cluster"
REGION="us-east-1"

echo "🔐 Creating IAM roles for EventSphere EKS cluster..."

# Check if AWS CLI is installed and configured
if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI is not installed. Please install it first.${NC}"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}❌ AWS credentials not configured. Please run 'aws configure'${NC}"
    exit 1
fi

# Get AWS Account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo -e "${RED}❌ Failed to retrieve AWS Account ID${NC}"
    exit 1
fi
echo -e "${GREEN}✅ AWS Account ID: $AWS_ACCOUNT_ID${NC}"

# Get OIDC provider ID
echo "📋 Retrieving OIDC provider ID..."
OIDC_ISSUER=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
    --query "cluster.identity.oidc.issuer" --output text 2>/dev/null || echo "")

if [ -z "$OIDC_ISSUER" ]; then
    echo -e "${YELLOW}⚠️  OIDC provider not found. Creating OIDC provider...${NC}"
    eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $REGION --approve
    OIDC_ISSUER=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
        --query "cluster.identity.oidc.issuer" --output text)
fi

OIDC_ID=$(echo $OIDC_ISSUER | cut -d '/' -f 5)
echo -e "${GREEN}✅ OIDC Provider ID: $OIDC_ID${NC}"

# Function to create trust policy
create_trust_policy() {
    local namespace=$1
    local service_account=$2
    local temp_file="trust-policy-temp.json"
    
    cat > $temp_file <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:${namespace}:${service_account}",
          "oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
    echo $temp_file
}

# Function to create IAM role
create_iam_role() {
    local role_name=$1
    local namespace=$2
    local service_account=$3
    local policy_arn=$4
    local custom_policy_file=$5
    
    echo ""
    echo "🔧 Creating IAM role: $role_name"
    
    # Check if role already exists
    if aws iam get-role --role-name $role_name &> /dev/null; then
        echo -e "${YELLOW}⚠️  Role $role_name already exists. Skipping creation.${NC}"
        return 0
    fi
    
    # Create trust policy
    TRUST_POLICY_FILE=$(create_trust_policy $namespace $service_account)
    
    # Create role
    aws iam create-role \
        --role-name $role_name \
        --assume-role-policy-document file://$TRUST_POLICY_FILE \
        --tags Key=Project,Value=EventSphere Key=Service,Value=$service_account \
        --region $REGION
    
    echo -e "${GREEN}✅ Created IAM role: $role_name${NC}"
    
    # Attach policy
    if [ -n "$custom_policy_file" ] && [ -f "$custom_policy_file" ]; then
        echo "Attaching custom policy from $custom_policy_file..."
        POLICY_NAME="${role_name}-policy"
        aws iam create-policy \
            --policy-name $POLICY_NAME \
            --policy-document file://$custom_policy_file \
            --region $REGION 2>/dev/null || true
        
        POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
        aws iam attach-role-policy \
            --role-name $role_name \
            --policy-arn $POLICY_ARN \
            --region $REGION
        echo -e "${GREEN}✅ Attached custom policy: $POLICY_NAME${NC}"
    elif [ -n "$policy_arn" ]; then
        aws iam attach-role-policy \
            --role-name $role_name \
            --policy-arn $policy_arn \
            --region $REGION
        echo -e "${GREEN}✅ Attached policy: $policy_arn${NC}"
    fi
    
    # Cleanup
    rm -f $TRUST_POLICY_FILE
    
    # Output role ARN for service account annotation
    ROLE_ARN=$(aws iam get-role --role-name $role_name --query 'Role.Arn' --output text)
    echo -e "${GREEN}✅ Role ARN: $ROLE_ARN${NC}"
    echo ""
    echo "To annotate the service account, run:"
    echo "  kubectl annotate serviceaccount $service_account -n $namespace \\"
    echo "    eks.amazonaws.com/role-arn=$ROLE_ARN"
}

# Create Fluent Bit Role
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Fluent Bit Role"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

create_iam_role \
    "fluent-bit-role" \
    "kube-system" \
    "fluent-bit" \
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy" \
    ""

# Create External Secrets Operator Role
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. External Secrets Operator Role"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create custom policy for Secrets Manager (least privilege)
SECRETS_POLICY_FILE="secrets-policy-temp.json"
cat > $SECRETS_POLICY_FILE <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:${REGION}:${AWS_ACCOUNT_ID}:secret:eventsphere/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:ListSecrets"
      ],
      "Resource": "*"
    }
  ]
}
EOF

create_iam_role \
    "external-secrets-role" \
    "external-secrets-system" \
    "external-secrets" \
    "" \
    "$SECRETS_POLICY_FILE"

rm -f $SECRETS_POLICY_FILE

# Create Notification Service Role
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. Notification Service Role"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create custom policy for SNS publish
NOTIFICATION_POLICY_FILE="notification-policy-temp.json"
cat > $NOTIFICATION_POLICY_FILE <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sns:Publish"
      ],
      "Resource": "arn:aws:sns:${REGION}:${AWS_ACCOUNT_ID}:eventsphere-notifications"
    }
  ]
}
EOF

create_iam_role \
    "notification-service-role" \
    "prod" \
    "notification-service-sa" \
    "" \
    "$NOTIFICATION_POLICY_FILE"

rm -f $NOTIFICATION_POLICY_FILE

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ IAM role creation completed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "1. Annotate service accounts with role ARNs (see commands above)"
echo "2. Verify roles are working:"
echo "   kubectl describe sa fluent-bit -n kube-system"
echo "   kubectl describe sa external-secrets -n external-secrets-system"
echo "   kubectl describe sa notification-service-sa -n prod"
echo ""
echo "Note: ALB Controller, Cluster Autoscaler, EBS CSI, and EFS CSI roles"
echo "      are created automatically by eksctl when using wellKnownPolicies."




