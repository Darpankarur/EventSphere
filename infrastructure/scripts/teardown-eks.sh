#!/bin/bash

# EventSphere EKS Cluster Teardown Script
# WARNING: This will delete the entire cluster and all resources

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/infrastructure/config"
CONFIG_FILE="$CONFIG_DIR/config.env"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

CLUSTER_NAME="${CLUSTER_NAME:-eventsphere-cluster}"
REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null)}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${RED}⚠️  WARNING: This will delete the following resources:${NC}"
echo "  - EKS cluster: $CLUSTER_NAME"
echo "  - Lambda function: eventsphere-email-sender"
echo "  - SNS topic: eventsphere-notifications"
echo "  - IAM roles and policies"
echo "  - CloudWatch log groups"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo -e "${RED}❌ Teardown cancelled${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Starting Teardown Process${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Step 1: Delete Lambda function
echo -e "${BLUE}🗑️  Step 1: Deleting Lambda function...${NC}"
if aws lambda get-function --function-name eventsphere-email-sender --region $REGION &> /dev/null; then
    aws lambda delete-function --function-name eventsphere-email-sender --region $REGION
    echo -e "${GREEN}✅ Lambda function deleted${NC}"
else
    echo -e "${YELLOW}⚠️  Lambda function not found, skipping${NC}"
fi
echo ""

# Step 2: Delete SNS subscriptions and topic
echo -e "${BLUE}🗑️  Step 2: Deleting SNS subscriptions and topic...${NC}"
SNS_TOPIC_ARN="arn:aws:sns:${REGION}:${AWS_ACCOUNT_ID}:eventsphere-notifications"

if aws sns get-topic-attributes --topic-arn $SNS_TOPIC_ARN --region $REGION &> /dev/null; then
    # List and delete all subscriptions
    echo -e "${YELLOW}Deleting SNS subscriptions...${NC}"
    SUBSCRIPTIONS=$(aws sns list-subscriptions-by-topic --topic-arn $SNS_TOPIC_ARN --region $REGION --query 'Subscriptions[].SubscriptionArn' --output text)
    
    if [ -n "$SUBSCRIPTIONS" ]; then
        for SUB_ARN in $SUBSCRIPTIONS; do
            if [ "$SUB_ARN" != "PendingConfirmation" ]; then
                aws sns unsubscribe --subscription-arn $SUB_ARN --region $REGION
                echo -e "${GREEN}✅ Deleted subscription: ${SUB_ARN}${NC}"
            fi
        done
    else
        echo -e "${YELLOW}⚠️  No subscriptions found${NC}"
    fi
    
    # Delete topic
    aws sns delete-topic --topic-arn $SNS_TOPIC_ARN --region $REGION
    echo -e "${GREEN}✅ SNS topic deleted${NC}"
else
    echo -e "${YELLOW}⚠️  SNS topic not found, skipping${NC}"
fi
echo ""

# Step 3: Delete IAM roles and policies
echo -e "${BLUE}🗑️  Step 3: Deleting IAM roles and policies...${NC}"

# Lambda email sender role
LAMBDA_ROLE="eventsphere-lambda-email-sender-role"
LAMBDA_POLICY="eventsphere-lambda-ses-send-policy"
LAMBDA_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${LAMBDA_POLICY}"

if aws iam get-role --role-name $LAMBDA_ROLE &> /dev/null; then
    # Detach policy
    aws iam detach-role-policy --role-name $LAMBDA_ROLE --policy-arn $LAMBDA_POLICY_ARN 2>/dev/null || true
    # Delete role
    aws iam delete-role --role-name $LAMBDA_ROLE
    echo -e "${GREEN}✅ IAM role deleted: $LAMBDA_ROLE${NC}"
else
    echo -e "${YELLOW}⚠️  IAM role not found: $LAMBDA_ROLE${NC}"
fi

if aws iam get-policy --policy-arn $LAMBDA_POLICY_ARN &> /dev/null; then
    aws iam delete-policy --policy-arn $LAMBDA_POLICY_ARN
    echo -e "${GREEN}✅ IAM policy deleted: $LAMBDA_POLICY${NC}"
else
    echo -e "${YELLOW}⚠️  IAM policy not found: $LAMBDA_POLICY${NC}"
fi
echo ""

# Step 4: Delete CloudWatch log groups
echo -e "${BLUE}🗑️  Step 4: Deleting CloudWatch log groups...${NC}"
LOG_GROUP="/aws/lambda/eventsphere-email-sender"
if aws logs describe-log-groups --log-group-name-prefix $LOG_GROUP --region $REGION 2>/dev/null | grep -q $LOG_GROUP; then
    aws logs delete-log-group --log-group-name $LOG_GROUP --region $REGION
    echo -e "${GREEN}✅ CloudWatch log group deleted${NC}"
else
    echo -e "${YELLOW}⚠️  CloudWatch log group not found, skipping${NC}"
fi
echo ""

# Step 5: Delete EKS cluster
echo -e "${BLUE}🗑️  Step 5: Deleting EKS cluster...${NC}"
if eksctl get cluster --name $CLUSTER_NAME --region $REGION &> /dev/null; then
    eksctl delete cluster --name $CLUSTER_NAME --region $REGION
    echo -e "${GREEN}✅ Cluster deletion initiated${NC}"
else
    echo -e "${YELLOW}⚠️  EKS cluster not found, skipping${NC}"
fi
echo ""

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Teardown Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}Note: EKS cluster deletion may take 10-15 minutes.${NC}"
echo -e "${YELLOW}Monitor progress in the AWS Console.${NC}"
echo ""
echo -e "${YELLOW}Resources NOT deleted (manual cleanup required):${NC}"
echo "  - ECR repositories (contain Docker images)"
echo "  - SES verified email identities"
echo "  - EBS volumes (if any persist)"
echo ""




