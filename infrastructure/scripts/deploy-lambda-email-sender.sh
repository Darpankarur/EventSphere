#!/bin/bash

# Deploy Lambda Function for SNS to SES Email Sending
# This Lambda function receives messages from SNS and sends emails via SES

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAMBDA_DIR="$PROJECT_ROOT/infrastructure/lambda/email-sender"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Deploy Lambda Email Sender Function${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
FUNCTION_NAME="eventsphere-email-sender"
SNS_TOPIC_NAME="eventsphere-notifications"
FROM_EMAIL="${FROM_EMAIL:-noreply@example.com}"

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI not found${NC}"
    exit 1
fi

# Check for zip command (optional - will use alternative if not found)
if ! command -v zip &> /dev/null; then
    echo -e "${YELLOW}⚠️  zip command not found, will use alternative method${NC}"
    USE_POWERSHELL_ZIP=true
else
    USE_POWERSHELL_ZIP=false
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}✅ AWS Account ID: ${AWS_ACCOUNT_ID}${NC}"
echo ""

# Step 1: Verify email in SES
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 1: Verify Email in SES${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -p "Enter the email address to use as sender (e.g., your-email@gmail.com): " FROM_EMAIL

echo -e "${YELLOW}Verifying email in SES...${NC}"

# Check if email is already verified using the newer API
VERIFICATION_STATUS=$(aws ses get-identity-verification-attributes \
    --identities "$FROM_EMAIL" \
    --region $AWS_REGION \
    --query "VerificationAttributes.\"$FROM_EMAIL\".VerificationStatus" \
    --output text 2>/dev/null || echo "NotFound")

if [ "$VERIFICATION_STATUS" = "Success" ]; then
    echo -e "${GREEN}✅ Email already verified: $FROM_EMAIL${NC}"
else
    echo -e "${YELLOW}Email not verified. Sending verification email...${NC}"
    aws ses verify-email-identity --email-address "$FROM_EMAIL" --region $AWS_REGION
    echo -e "${GREEN}✅ Verification email sent to $FROM_EMAIL${NC}"
    echo -e "${YELLOW}⚠️  Please check your inbox and click the verification link${NC}"
    echo ""
    read -p "Press Enter after you've verified the email..."
fi
echo ""

# Step 2: Create SNS Topic
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 2: Create SNS Topic${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

SNS_TOPIC_ARN=$(aws sns create-topic \
    --name "${SNS_TOPIC_NAME}" \
    --region "${AWS_REGION}" \
    --query 'TopicArn' \
    --output text 2>/dev/null || \
    aws sns list-topics --region "${AWS_REGION}" --query "Topics[?contains(TopicArn, '${SNS_TOPIC_NAME}')].TopicArn" --output text)

echo -e "${GREEN}✅ SNS Topic ARN: ${SNS_TOPIC_ARN}${NC}"
echo ""

# Step 3: Create IAM Role for Lambda
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 3: Create IAM Role for Lambda${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

ROLE_NAME="eventsphere-lambda-email-sender-role"

# Create trust policy
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

# Check if role exists
if aws iam get-role --role-name $ROLE_NAME &> /dev/null; then
    echo -e "${YELLOW}⚠️  Role already exists: $ROLE_NAME${NC}"
else
    echo "$TRUST_POLICY" > trust-policy.json
    aws iam create-role \
        --role-name $ROLE_NAME \
        --assume-role-policy-document file://trust-policy.json \
        --tags Key=Project,Value=EventSphere
    rm -f trust-policy.json
    echo -e "${GREEN}✅ Created IAM role: $ROLE_NAME${NC}"
fi

# Create policy for SES sending
POLICY_NAME="eventsphere-lambda-ses-send-policy"
POLICY_DOCUMENT=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ses:SendEmail",
        "ses:SendRawEmail"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
EOF
)

# Check if policy exists
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)

if [ -z "$POLICY_ARN" ]; then
    echo "$POLICY_DOCUMENT" > policy.json
    POLICY_ARN=$(aws iam create-policy \
        --policy-name $POLICY_NAME \
        --policy-document file://policy.json \
        --query 'Policy.Arn' \
        --output text)
    rm -f policy.json
    echo -e "${GREEN}✅ Created IAM policy: $POLICY_NAME${NC}"
else
    echo -e "${YELLOW}⚠️  Policy already exists: $POLICY_NAME${NC}"
fi

# Attach policy to role
aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn $POLICY_ARN 2>/dev/null || true

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
echo -e "${GREEN}✅ Role ARN: ${ROLE_ARN}${NC}"
echo ""

# Wait for role to propagate
echo -e "${YELLOW}Waiting for IAM role to propagate (10 seconds)...${NC}"
sleep 10

# Step 4: Package Lambda Function
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 4: Package Lambda Function${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

cd "$LAMBDA_DIR"

echo -e "${YELLOW}Installing dependencies...${NC}"
npm install --production

echo -e "${YELLOW}Creating deployment package...${NC}"

if [ "$USE_POWERSHELL_ZIP" = true ]; then
    # Use PowerShell Compress-Archive (Windows alternative)
    powershell.exe -Command "Compress-Archive -Path index.js,node_modules -DestinationPath function.zip -Force" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to create zip file${NC}"
        echo "Please install zip: http://gnuwin32.sourceforge.net/packages/zip.htm"
        exit 1
    fi
else
    # Use standard zip command
    zip -r function.zip index.js node_modules/ > /dev/null
fi

echo -e "${GREEN}✅ Lambda package created${NC}"
echo ""

# Step 5: Deploy Lambda Function
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 5: Deploy Lambda Function${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if function exists
if aws lambda get-function --function-name $FUNCTION_NAME --region $AWS_REGION &> /dev/null; then
    echo -e "${YELLOW}Updating existing function...${NC}"
    aws lambda update-function-code \
        --function-name $FUNCTION_NAME \
        --zip-file fileb://function.zip \
        --region $AWS_REGION > /dev/null
    
    aws lambda update-function-configuration \
        --function-name $FUNCTION_NAME \
        --environment "Variables={FROM_EMAIL=$FROM_EMAIL}" \
        --region $AWS_REGION > /dev/null
    
    echo -e "${GREEN}✅ Lambda function updated${NC}"
else
    echo -e "${YELLOW}Creating new function...${NC}"
    aws lambda create-function \
        --function-name $FUNCTION_NAME \
        --runtime nodejs20.x \
        --role $ROLE_ARN \
        --handler index.handler \
        --zip-file fileb://function.zip \
        --timeout 30 \
        --memory-size 256 \
        --environment "Variables={FROM_EMAIL=$FROM_EMAIL}" \
        --region $AWS_REGION > /dev/null
    
    echo -e "${GREEN}✅ Lambda function created${NC}"
fi

LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${FUNCTION_NAME}"
echo ""

# Step 6: Subscribe Lambda to SNS Topic
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 6: Subscribe Lambda to SNS Topic${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Add permission for SNS to invoke Lambda
aws lambda add-permission \
    --function-name $FUNCTION_NAME \
    --statement-id sns-invoke \
    --action lambda:InvokeFunction \
    --principal sns.amazonaws.com \
    --source-arn $SNS_TOPIC_ARN \
    --region $AWS_REGION 2>/dev/null || echo -e "${YELLOW}⚠️  Permission already exists${NC}"

# Subscribe Lambda to SNS
SUBSCRIPTION_ARN=$(aws sns subscribe \
    --topic-arn $SNS_TOPIC_ARN \
    --protocol lambda \
    --notification-endpoint $LAMBDA_ARN \
    --region $AWS_REGION \
    --query 'SubscriptionArn' \
    --output text 2>/dev/null || echo "")

if [ -n "$SUBSCRIPTION_ARN" ] && [ "$SUBSCRIPTION_ARN" != "None" ]; then
    echo -e "${GREEN}✅ Lambda subscribed to SNS topic${NC}"
else
    echo -e "${YELLOW}⚠️  Subscription may already exist${NC}"
fi

echo ""

# Cleanup
rm -f function.zip

# Summary
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Deployment Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo "  SNS Topic ARN: ${SNS_TOPIC_ARN}"
echo "  Lambda Function: ${FUNCTION_NAME}"
echo "  From Email: ${FROM_EMAIL}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Update notification service with SNS_TOPIC_ARN:"
echo "   SNS_TOPIC_ARN=${SNS_TOPIC_ARN}"
echo ""
echo "2. Test the setup:"
echo "   aws sns publish \\"
echo "     --topic-arn ${SNS_TOPIC_ARN} \\"
echo "     --subject 'Test Email' \\"
echo "     --message 'This is a test message' \\"
echo "     --message-attributes 'email={DataType=String,StringValue=your-email@gmail.com}'"
echo ""
echo "3. Check your email inbox for the test message"
echo ""
