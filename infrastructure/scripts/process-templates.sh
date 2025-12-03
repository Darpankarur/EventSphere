#!/bin/bash

# EventSphere Template Processing Script
# This script processes Kubernetes manifest templates using environment variable substitution

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/infrastructure/config"
CONFIG_FILE="$CONFIG_DIR/config.env"
OUTPUT_DIR="$PROJECT_ROOT/k8s/generated"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔧 EventSphere Template Processing Script${NC}"
echo ""

# Check prerequisites
echo -e "${BLUE}🔍 Checking prerequisites...${NC}"

if ! command -v envsubst &> /dev/null; then
    echo -e "${RED}❌ envsubst is not installed.${NC}"
    echo "   On macOS: brew install gettext"
    echo "   On Linux: Usually pre-installed, or install gettext package"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo -e "${YELLOW}⚠️  AWS CLI is not installed. Auto-detection of AWS Account ID will be skipped.${NC}"
fi

echo -e "${GREEN}✅ Prerequisites check passed${NC}"
echo ""

# Load configuration
echo -e "${BLUE}📋 Loading configuration...${NC}"

if [ -f "$CONFIG_FILE" ]; then
    echo -e "${GREEN}✅ Loading config from: $CONFIG_FILE${NC}"
    source "$CONFIG_FILE"
else
    echo -e "${YELLOW}⚠️  Config file not found: $CONFIG_FILE${NC}"
    echo "   Using environment variables and defaults"
    echo "   To create config file, copy: $CONFIG_DIR/config.env.example"
    echo ""
fi

# Auto-detect AWS Account ID if not set
if [ -z "$AWS_ACCOUNT_ID" ] && command -v aws &> /dev/null; then
    echo "📋 Auto-detecting AWS Account ID..."
    if aws sts get-caller-identity &> /dev/null; then
        AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        export AWS_ACCOUNT_ID
        echo -e "${GREEN}✅ Detected AWS Account ID: $AWS_ACCOUNT_ID${NC}"
    else
        echo -e "${YELLOW}⚠️  AWS credentials not configured. Skipping auto-detection.${NC}"
    fi
fi

# Set defaults if not provided
export AWS_REGION="${AWS_REGION:-us-east-1}"
export CLUSTER_NAME="${CLUSTER_NAME:-eventsphere-cluster}"

# Calculate derived values
if [ -n "$AWS_ACCOUNT_ID" ]; then
    export ECR_REGISTRY="${ECR_REGISTRY:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com}"
    export FLUENT_BIT_ROLE_ARN="${FLUENT_BIT_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNT_ID}:role/fluent-bit-role}"
    export EXTERNAL_SECRETS_ROLE_ARN="${EXTERNAL_SECRETS_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNT_ID}:role/external-secrets-role}"
fi

echo ""
echo -e "${GREEN}Configuration:${NC}"
echo "  AWS_ACCOUNT_ID: ${AWS_ACCOUNT_ID:-<not set>}"
echo "  AWS_REGION: $AWS_REGION"
echo "  ECR_REGISTRY: ${ECR_REGISTRY:-<not set>}"
echo "  CLUSTER_NAME: $CLUSTER_NAME"
echo "  ACM_CERTIFICATE_ARN: ${ACM_CERTIFICATE_ARN:-<not set>}"
echo "  FLUENT_BIT_ROLE_ARN: ${FLUENT_BIT_ROLE_ARN:-<not set>}"
echo ""

# Validate required variables
if [ -z "$ECR_REGISTRY" ]; then
    echo -e "${RED}❌ ECR_REGISTRY is not set. Please set AWS_ACCOUNT_ID or ECR_REGISTRY in config.env${NC}"
    exit 1
fi

# Create output directory
echo -e "${BLUE}📁 Creating output directory...${NC}"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/base"
mkdir -p "$OUTPUT_DIR/ingress"
mkdir -p "$OUTPUT_DIR/overlays/dev"
mkdir -p "$OUTPUT_DIR/overlays/staging"
mkdir -p "$PROJECT_ROOT/monitoring/cloudwatch/generated"

#Function to process a template file
process_template() {
    local template_file="$1"
    local output_file="$2"
    
    if [ ! -f "$template_file" ]; then
        echo -e "${YELLOW}⚠️  Template not found: $template_file${NC}"
        return 1
    fi
   
    # Process template with envsubst
    # envsubst will substitute all environment variables in ${VAR} format
    envsubst < "$template_file" > "$output_file"
    
    # Remove .template from output filename if present
    if [[ "$output_file" == *.template ]]; then
        local new_output="${output_file%.template}"
        mv "$output_file" "$new_output"
        output_file="$new_output"
    fi
    
    echo -e "${GREEN}✅ Processed: $(basename "$template_file") -> $(basename "$output_file")${NC}"
}



# Find and process all template files
echo -e "${BLUE}🔄 Processing template files...${NC}"
echo ""

# Process base deployment templates
if [ -f "$PROJECT_ROOT/k8s/base/auth-service-deployment.yaml.template" ]; then
    process_template "$PROJECT_ROOT/k8s/base/auth-service-deployment.yaml.template" \
        "$OUTPUT_DIR/base/auth-service-deployment.yaml"
fi

if [ -f "$PROJECT_ROOT/k8s/base/event-service-deployment.yaml.template" ]; then
    process_template "$PROJECT_ROOT/k8s/base/event-service-deployment.yaml.template" \
        "$OUTPUT_DIR/base/event-service-deployment.yaml"
fi

if [ -f "$PROJECT_ROOT/k8s/base/booking-service-deployment.yaml.template" ]; then
    process_template "$PROJECT_ROOT/k8s/base/booking-service-deployment.yaml.template" \
        "$OUTPUT_DIR/base/booking-service-deployment.yaml"
fi

if [ -f "$PROJECT_ROOT/k8s/base/notification-service-deployment.yaml.template" ]; then
    process_template "$PROJECT_ROOT/k8s/base/notification-service-deployment.yaml.template" \
        "$OUTPUT_DIR/base/notification-service-deployment.yaml"
fi

if [ -f "$PROJECT_ROOT/k8s/base/frontend-deployment.yaml.template" ]; then
    process_template "$PROJECT_ROOT/k8s/base/frontend-deployment.yaml.template" \
        "$OUTPUT_DIR/base/frontend-deployment.yaml"
fi

# Copy non-template base files
echo -e "${BLUE}📋 Copying non-template base files...${NC}"
for file in "$PROJECT_ROOT/k8s/base"/*.yaml; do
    if [ -f "$file" ] && [[ ! "$file" == *.template ]]; then
        cp "$file" "$OUTPUT_DIR/base/"
        echo -e "${GREEN}✅ Copied: $(basename "$file")${NC}"
    fi
done

# Process ingress template
if [ -f "$PROJECT_ROOT/k8s/ingress/ingress.yaml.template" ]; then
    process_template "$PROJECT_ROOT/k8s/ingress/ingress.yaml.template" \
        "$OUTPUT_DIR/ingress/ingress.yaml"
fi

# Copy non-template ingress files
for file in "$PROJECT_ROOT/k8s/ingress"/*.yaml; do
    if [ -f "$file" ] && [[ ! "$file" == *.template ]]; then
        cp "$file" "$OUTPUT_DIR/ingress/"
        echo -e "${GREEN}✅ Copied: $(basename "$file")${NC}"
    fi
done

# Process overlay templates
if [ -f "$PROJECT_ROOT/k8s/overlays/dev/kustomization.yaml.template" ]; then
    process_template "$PROJECT_ROOT/k8s/overlays/dev/kustomization.yaml.template" \
        "$OUTPUT_DIR/overlays/dev/kustomization.yaml"
fi

if [ -f "$PROJECT_ROOT/k8s/overlays/staging/kustomization.yaml.template" ]; then
    process_template "$PROJECT_ROOT/k8s/overlays/staging/kustomization.yaml.template" \
        "$OUTPUT_DIR/overlays/staging/kustomization.yaml"
fi

# Process monitoring templates
if [ -f "$PROJECT_ROOT/monitoring/cloudwatch/fluent-bit-config.yaml.template" ]; then
    process_template "$PROJECT_ROOT/monitoring/cloudwatch/fluent-bit-config.yaml.template" \
        "$PROJECT_ROOT/monitoring/cloudwatch/generated/fluent-bit-config.yaml"
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Template processing completed!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Processed files are in: $OUTPUT_DIR"
echo ""
echo "Next steps:"
echo "  1. Review generated files in: $OUTPUT_DIR"
echo "  2. Deploy using: kubectl apply -f $OUTPUT_DIR/base/"
echo "  3. Deploy ingress: kubectl apply -f $OUTPUT_DIR/ingress/"
echo "  4. Deploy monitoring: kubectl apply -f $PROJECT_ROOT/monitoring/cloudwatch/generated/"
echo ""

