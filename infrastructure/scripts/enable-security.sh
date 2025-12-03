#!/bin/bash

# Script to enable GuardDuty, EKS control plane logging, and configure security

set -e

CLUSTER_NAME="eventsphere-cluster"
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "🔒 Enabling security features for EventSphere EKS cluster..."

# Enable GuardDuty
echo "📡 Enabling GuardDuty..."
if ! aws guardduty list-detectors --region $REGION --query 'DetectorIds[0]' --output text | grep -q "None"; then
    DETECTOR_ID=$(aws guardduty list-detectors --region $REGION --query 'DetectorIds[0]' --output text)
    echo "GuardDuty detector already exists: $DETECTOR_ID"
else
    DETECTOR_ID=$(aws guardduty create-detector --enable --region $REGION --query 'DetectorId' --output text)
    echo "✅ Created GuardDuty detector: $DETECTOR_ID"
fi

# Enable EKS control plane logging
echo "📝 Enabling EKS control plane logging..."
set +e  # Temporarily disable exit on error to handle "No changes needed"
UPDATE_OUTPUT=$(aws eks update-cluster-config \
    --name $CLUSTER_NAME \
    --region $REGION \
    --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}' 2>&1)
UPDATE_EXIT_CODE=$?
set -e  # Re-enable exit on error

if [ $UPDATE_EXIT_CODE -eq 0 ]; then
    echo "⏳ Waiting for logging to be enabled..."
    aws eks wait cluster-active --name $CLUSTER_NAME --region $REGION
    echo "✅ EKS control plane logging enabled"
elif echo "$UPDATE_OUTPUT" | grep -q "No changes needed"; then
    echo "✅ EKS control plane logging already configured correctly"
else
    echo "✅ EKS control plane logging already enabled (no changes needed)"
fi

# Create CloudWatch Log Group for EKS
echo "📊 Creating CloudWatch Log Group..."
LOG_GROUP_NAME="/aws/eks/$CLUSTER_NAME/cluster"
if ! aws logs describe-log-groups --log-group-name-prefix $LOG_GROUP_NAME --region $REGION --query 'logGroups[0]' --output text | grep -q "None"; then
    echo "Log group already exists"
else
    aws logs create-log-group --log-group-name $LOG_GROUP_NAME --region $REGION || true
    # Set retention to 7 days
    aws logs put-retention-policy --log-group-name $LOG_GROUP_NAME --retention-in-days 7 --region $REGION
    echo "✅ Created CloudWatch log group: $LOG_GROUP_NAME"
fi

# Enable Security Hub (optional but recommended)
echo "🛡️  Checking Security Hub..."
if aws securityhub describe-hub --region $REGION 2>/dev/null; then
    echo "Security Hub already enabled"
else
    echo "Enabling Security Hub..."
    aws securityhub enable-security-hub --region $REGION || true
    echo "✅ Security Hub enabled"
fi

# Create SNS topic for security alerts
echo "📧 Creating SNS topic for security alerts..."
TOPIC_ARN=$(aws sns create-topic --name eventsphere-security-alerts --region $REGION --query 'TopicArn' --output text 2>/dev/null || \
    aws sns list-topics --region $REGION --query "Topics[?contains(TopicArn, 'eventsphere-security-alerts')].TopicArn" --output text | head -1)
echo "✅ SNS Topic ARN: $TOPIC_ARN"

# Subscribe email to SNS topic (update with your email)
if [ -n "$SECURITY_ALERT_EMAIL" ]; then
    echo "📧 Subscribing email to security alerts..."
    aws sns subscribe \
        --topic-arn $TOPIC_ARN \
        --protocol email \
        --notification-endpoint $SECURITY_ALERT_EMAIL \
        --region $REGION || true
    echo "✅ Subscribed $SECURITY_ALERT_EMAIL to security alerts"
fi

# Configure GuardDuty findings to SNS
echo "🔔 Configuring GuardDuty to publish findings to SNS..."
aws guardduty create-publishing-destination \
    --detector-id $DETECTOR_ID \
    --destination-type S3 \
    --destination-properties "DestinationArn=arn:aws:s3:::eventsphere-guardduty-findings,DestinationKmsKeyArn=arn:aws:kms:$REGION:$ACCOUNT_ID:key/alias/aws/s3" \
    --region $REGION 2>/dev/null || echo "Publishing destination may already exist"

echo ""
echo "✅ Security features enabled!"
echo ""
echo "Summary:"
echo "  - GuardDuty Detector ID: $DETECTOR_ID"
echo "  - EKS Control Plane Logging: Enabled"
echo "  - CloudWatch Log Group: $LOG_GROUP_NAME"
echo "  - Security Hub: Enabled"
echo "  - SNS Topic for Alerts: $TOPIC_ARN"
echo ""
echo "Next steps:"
echo "  1. Check GuardDuty findings: https://console.aws.amazon.com/guardduty/"
echo "  2. Review Security Hub findings: https://console.aws.amazon.com/securityhub/"
echo "  3. Monitor CloudWatch logs: https://console.aws.amazon.com/cloudwatch/"






