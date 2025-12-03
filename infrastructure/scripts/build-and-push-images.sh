#!/bin/bash

# EventSphere Docker Image Build and Push Script
# This script builds Docker images for all services and pushes them to ECR

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
AWS_REGION="${AWS_REGION:-us-east-1}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_REPO_CREATION="${SKIP_REPO_CREATION:-false}"

# Services to build
SERVICES=("auth-service" "event-service" "booking-service" "notification-service" "frontend")

echo -e "${BLUE}🐳 EventSphere Docker Image Build and Push Script${NC}"
echo ""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD="true"
            shift
            ;;
        --skip-repo-creation)
            SKIP_REPO_CREATION="true"
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --region REGION           AWS region (default: us-east-1)"
            echo "  --tag TAG                 Image tag (default: latest)"
            echo "  --skip-build              Skip building images, only push existing ones"
            echo "  --skip-repo-creation      Skip ECR repository creation"
            echo "  --help                    Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  AWS_REGION                AWS region (overridden by --region)"
            echo "  IMAGE_TAG                 Image tag (overridden by --tag)"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check prerequisites
echo -e "${BLUE}🔍 Checking prerequisites...${NC}"

if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI is not installed. Please install it first.${NC}"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ Docker is not installed. Please install it first.${NC}"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}❌ AWS credentials not configured. Please run 'aws configure'${NC}"
    exit 1
fi

# Get AWS Account ID
echo "📋 Retrieving AWS Account ID..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo -e "${RED}❌ Failed to retrieve AWS Account ID${NC}"
    exit 1
fi

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo -e "${GREEN}✅ Prerequisites check passed${NC}"
echo -e "${GREEN}✅ AWS Account ID: $AWS_ACCOUNT_ID${NC}"
echo -e "${GREEN}✅ AWS Region: $AWS_REGION${NC}"
echo -e "${GREEN}✅ ECR Registry: $ECR_REGISTRY${NC}"
echo -e "${GREEN}✅ Image Tag: $IMAGE_TAG${NC}"
echo ""

# Create ECR repositories if needed
if [ "$SKIP_REPO_CREATION" != "true" ]; then
    echo -e "${BLUE}📦 Creating ECR repositories...${NC}"
    
    for service in "${SERVICES[@]}"; do
        echo "Checking repository: $service"
        
        if aws ecr describe-repositories --repository-names "$service" --region "$AWS_REGION" &> /dev/null; then
            echo -e "${YELLOW}⚠️  Repository '$service' already exists, skipping...${NC}"
        else
            echo "Creating repository: $service"
            aws ecr create-repository \
                --repository-name "$service" \
                --region "$AWS_REGION" \
                --image-scanning-configuration scanOnPush=true \
                --encryption-configuration encryptionType=AES256
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ Created repository: $service${NC}"
            else
                echo -e "${RED}❌ Failed to create repository: $service${NC}"
                exit 1
            fi
        fi
    done
    echo ""
else
    echo -e "${YELLOW}⚠️  Skipping ECR repository creation${NC}"
    echo ""
fi

# Login to ECR
echo -e "${BLUE}🔐 Logging into ECR...${NC}"
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Successfully logged into ECR${NC}"
else
    echo -e "${RED}❌ Failed to login to ECR${NC}"
    exit 1
fi
echo ""

# Build and push images
echo -e "${BLUE}🔨 Building and pushing Docker images...${NC}"
echo ""

for service in "${SERVICES[@]}"; do
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}📦 Processing: $service${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Determine build context and Dockerfile path
    if [ "$service" == "frontend" ]; then
        BUILD_CONTEXT="$PROJECT_ROOT/frontend"
        DOCKERFILE="$PROJECT_ROOT/frontend/Dockerfile"
    else
        BUILD_CONTEXT="$PROJECT_ROOT/services/$service"
        DOCKERFILE="$PROJECT_ROOT/services/$service/Dockerfile"
    fi
    
    # Check if Dockerfile exists
    if [ ! -f "$DOCKERFILE" ]; then
        echo -e "${RED}❌ Dockerfile not found: $DOCKERFILE${NC}"
        echo -e "${YELLOW}⚠️  Skipping $service${NC}"
        echo ""
        continue
    fi
    
    # Build image
    if [ "$SKIP_BUILD" != "true" ]; then
        echo "Building image: $service:$IMAGE_TAG"
        echo "  Context: $BUILD_CONTEXT"
        echo "  Dockerfile: $DOCKERFILE"
        
        docker build \
            -t "$service:$IMAGE_TAG" \
            -f "$DOCKERFILE" \
            "$BUILD_CONTEXT"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Successfully built: $service:$IMAGE_TAG${NC}"
        else
            echo -e "${RED}❌ Failed to build: $service:$IMAGE_TAG${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}⚠️  Skipping build (using existing image)${NC}"
        
        # Check if image exists locally
        if ! docker image inspect "$service:$IMAGE_TAG" &> /dev/null; then
            echo -e "${RED}❌ Image not found locally: $service:$IMAGE_TAG${NC}"
            echo -e "${RED}   Cannot push without building. Remove --skip-build or build the image first.${NC}"
            exit 1
        fi
    fi
    
    # Tag image for ECR
    ECR_IMAGE="$ECR_REGISTRY/$service:$IMAGE_TAG"
    echo "Tagging image: $service:$IMAGE_TAG -> $ECR_IMAGE"
    
    docker tag "$service:$IMAGE_TAG" "$ECR_IMAGE"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Successfully tagged: $ECR_IMAGE${NC}"
    else
        echo -e "${RED}❌ Failed to tag: $ECR_IMAGE${NC}"
        exit 1
    fi
    
    # Push image to ECR
    echo "Pushing image to ECR: $ECR_IMAGE"
    
    docker push "$ECR_IMAGE"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Successfully pushed: $ECR_IMAGE${NC}"
    else
        echo -e "${RED}❌ Failed to push: $ECR_IMAGE${NC}"
        exit 1
    fi
    
    echo ""
done

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ All images built and pushed successfully!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Summary:"
echo "  - AWS Account ID: $AWS_ACCOUNT_ID"
echo "  - AWS Region: $AWS_REGION"
echo "  - ECR Registry: $ECR_REGISTRY"
echo "  - Image Tag: $IMAGE_TAG"
echo ""
echo "Pushed images:"
for service in "${SERVICES[@]}"; do
    echo "  - $ECR_REGISTRY/$service:$IMAGE_TAG"
done
echo ""
echo "Next steps:"
echo "  1. Update Kubernetes deployments with ECR image URLs"
echo "  2. Deploy services: kubectl apply -f k8s/base/"
echo ""

