#!/bin/bash

# EventSphere Comprehensive Deployment Script
# This script automates Steps 6-9 from DEPLOYMENT.md:
# - Configure AWS Secrets Manager
# - Create IAM Roles for Service Accounts
# - Deploy MongoDB
# - Deploy Microservices

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/infrastructure/config"
CONFIG_FILE="$CONFIG_DIR/config.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
SKIP_SECRETS=false
SKIP_IAM=false
SKIP_MONGODB=false
SKIP_SERVICES=false
SKIP_INGRESS=false
USE_EXTERNAL_SECRETS=false
DRY_RUN=false
MONGODB_PASSWORD=""
JWT_SECRET=""
AWS_REGION="us-east-1"
CLUSTER_NAME="eventsphere-cluster"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-secrets)
            SKIP_SECRETS=true
            shift
            ;;
        --skip-iam)
            SKIP_IAM=true
            shift
            ;;
        --skip-mongodb)
            SKIP_MONGODB=true
            shift
            ;;
        --skip-services)
            SKIP_SERVICES=true
            shift
            ;;
        --skip-ingress)
            SKIP_INGRESS=true
            shift
            ;;
        --use-external-secrets)
            USE_EXTERNAL_SECRETS=true
            shift
            ;;
        --mongodb-password)
            MONGODB_PASSWORD="$2"
            shift 2
            ;;
        --jwt-secret)
            JWT_SECRET="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-secrets           Skip AWS Secrets Manager creation"
            echo "  --skip-iam               Skip IAM role creation"
            echo "  --skip-mongodb           Skip MongoDB deployment"
            echo "  --skip-services          Skip microservices deployment"
            echo "  --skip-ingress           Skip ingress deployment"
            echo "  --use-external-secrets   Use External Secrets Operator"
            echo "  --mongodb-password PASS  Custom MongoDB password"
            echo "  --jwt-secret SECRET      Custom JWT secret"
            echo "  --dry-run                Show what would be done without executing"
            echo "  --help                   Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}🚀 EventSphere Comprehensive Deployment Script${NC}"
echo ""

# Check prerequisites
echo -e "${BLUE}🔍 Checking prerequisites...${NC}"

if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI is not installed. Please install it first.${NC}"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl is not installed. Please install it first.${NC}"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}❌ AWS credentials not configured. Please run 'aws configure'${NC}"
    exit 1
fi

# Check kubectl cluster access
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}❌ Cannot access Kubernetes cluster. Please configure kubeconfig${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites check passed${NC}"
echo ""

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    echo -e "${BLUE}📋 Loading configuration from: $CONFIG_FILE${NC}"
    source "$CONFIG_FILE"
else
    echo -e "${YELLOW}⚠️  Config file not found: $CONFIG_FILE${NC}"
    echo "   Using environment variables and defaults"
fi

# Get AWS Account ID if not set
if [ -z "$AWS_ACCOUNT_ID" ]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    export AWS_ACCOUNT_ID
fi

# Set defaults
export AWS_REGION="${AWS_REGION:-$AWS_REGION}"
export CLUSTER_NAME="${CLUSTER_NAME:-$CLUSTER_NAME}"

echo -e "${GREEN}Configuration:${NC}"
echo "  AWS_ACCOUNT_ID: $AWS_ACCOUNT_ID"
echo "  AWS_REGION: $AWS_REGION"
echo "  CLUSTER_NAME: $CLUSTER_NAME"
echo ""

# Function to generate secure password
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# ==============================================================================
# Step 1: Configure AWS Secrets Manager
# ==============================================================================
if [ "$SKIP_SECRETS" != "true" ]; then
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Step 1: Configure AWS Secrets Manager${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Generate passwords if not provided
    if [ -z "$MONGODB_PASSWORD" ]; then
        MONGODB_PASSWORD=$(generate_password)
        echo -e "${YELLOW}⚠️  Generated MongoDB password (save this securely!)${NC}"
    fi
    
    if [ -z "$JWT_SECRET" ]; then
        JWT_SECRET=$(generate_password)
        echo -e "${YELLOW}⚠️  Generated JWT secret (save this securely!)${NC}"
    fi
    
    # MongoDB connection string
    MONGO_CONNECTION_STRING="mongodb://admin:${MONGODB_PASSWORD}@mongodb.prod.svc.cluster.local:27017/eventsphere?authSource=admin"
    
    # Create MongoDB secret
    MONGO_SECRET_NAME="eventsphere/mongodb"
    MONGO_SECRET_JSON="{\"username\":\"admin\",\"password\":\"${MONGODB_PASSWORD}\",\"connection-string\":\"${MONGO_CONNECTION_STRING}\"}"
    
    if [ "$DRY_RUN" != "true" ]; then
        if aws secretsmanager describe-secret --secret-id "$MONGO_SECRET_NAME" --region "$AWS_REGION" &> /dev/null; then
            echo -e "${YELLOW}⚠️  Secret $MONGO_SECRET_NAME already exists. Updating...${NC}"
            aws secretsmanager update-secret \
                --secret-id "$MONGO_SECRET_NAME" \
                --secret-string "$MONGO_SECRET_JSON" \
                --region "$AWS_REGION" > /dev/null
            echo -e "${GREEN}✅ Updated MongoDB secret in AWS Secrets Manager${NC}"
        else
            aws secretsmanager create-secret \
                --name "$MONGO_SECRET_NAME" \
                --secret-string "$MONGO_SECRET_JSON" \
                --region "$AWS_REGION" > /dev/null
            echo -e "${GREEN}✅ Created MongoDB secret in AWS Secrets Manager${NC}"
        fi
    else
        echo -e "${YELLOW}[DRY RUN] Would create/update secret: $MONGO_SECRET_NAME${NC}"
    fi
    
    # Create JWT secret
    JWT_SECRET_NAME="eventsphere/auth-service"
    JWT_SECRET_JSON="{\"jwt-secret\":\"${JWT_SECRET}\"}"
    
    if [ "$DRY_RUN" != "true" ]; then
        if aws secretsmanager describe-secret --secret-id "$JWT_SECRET_NAME" --region "$AWS_REGION" &> /dev/null; then
            echo -e "${YELLOW}⚠️  Secret $JWT_SECRET_NAME already exists. Updating...${NC}"
            aws secretsmanager update-secret \
                --secret-id "$JWT_SECRET_NAME" \
                --secret-string "$JWT_SECRET_JSON" \
                --region "$AWS_REGION" > /dev/null
            echo -e "${GREEN}✅ Updated JWT secret in AWS Secrets Manager${NC}"
        else
            aws secretsmanager create-secret \
                --name "$JWT_SECRET_NAME" \
                --secret-string "$JWT_SECRET_JSON" \
                --region "$AWS_REGION" > /dev/null
            echo -e "${GREEN}✅ Created JWT secret in AWS Secrets Manager${NC}"
        fi
    else
        echo -e "${YELLOW}[DRY RUN] Would create/update secret: $JWT_SECRET_NAME${NC}"
    fi
    
    # Create SNS Topic for notifications
    SNS_TOPIC_NAME="eventsphere-notifications"
    
    if [ "$DRY_RUN" != "true" ]; then
        echo -e "${BLUE}📧 Creating SNS topic for notifications...${NC}"
        
        # Create or get SNS topic
        SNS_TOPIC_ARN=$(aws sns create-topic \
            --name "${SNS_TOPIC_NAME}" \
            --region "${AWS_REGION}" \
            --attributes DisplayName="EventSphere Notifications" \
            --tags Key=Project,Value=EventSphere Key=ManagedBy,Value=Script \
            --query 'TopicArn' \
            --output text 2>/dev/null || \
            aws sns list-topics --region "${AWS_REGION}" --query "Topics[?contains(TopicArn, '${SNS_TOPIC_NAME}')].TopicArn" --output text)
        
        if [ -n "$SNS_TOPIC_ARN" ]; then
            echo -e "${GREEN}✅ SNS Topic created/found: ${SNS_TOPIC_ARN}${NC}"
            
            # Store SNS Topic ARN in Secrets Manager
            NOTIFICATION_SECRET_NAME="eventsphere/notification-service"
            NOTIFICATION_SECRET_JSON="{\"sns-topic-arn\":\"${SNS_TOPIC_ARN}\"}"
            
            if aws secretsmanager describe-secret --secret-id "$NOTIFICATION_SECRET_NAME" --region "$AWS_REGION" &> /dev/null; then
                aws secretsmanager update-secret \
                    --secret-id "$NOTIFICATION_SECRET_NAME" \
                    --secret-string "$NOTIFICATION_SECRET_JSON" \
                    --region "$AWS_REGION" > /dev/null
                echo -e "${GREEN}✅ Updated notification service secret in AWS Secrets Manager${NC}"
            else
                aws secretsmanager create-secret \
                    --name "$NOTIFICATION_SECRET_NAME" \
                    --secret-string "$NOTIFICATION_SECRET_JSON" \
                    --region "$AWS_REGION" > /dev/null
                echo -e "${GREEN}✅ Created notification service secret in AWS Secrets Manager${NC}"
            fi
        else
            echo -e "${RED}❌ Failed to create SNS topic${NC}"
        fi
    else
        echo -e "${YELLOW}[DRY RUN] Would create SNS topic: $SNS_TOPIC_NAME${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}⚠️  IMPORTANT: Save these credentials securely!${NC}"
    echo "  MongoDB Password: $MONGODB_PASSWORD"
    echo "  JWT Secret: $JWT_SECRET"
    if [ -n "$SNS_TOPIC_ARN" ]; then
        echo "  SNS Topic ARN: $SNS_TOPIC_ARN"
    fi
    echo ""
else
    echo -e "${YELLOW}⏭️  Skipping AWS Secrets Manager configuration${NC}"
    echo ""
fi

# ==============================================================================
# Step 2: Create IAM Roles for Service Accounts
# ==============================================================================
if [ "$SKIP_IAM" != "true" ]; then
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Step 2: Create IAM Roles for Service Accounts${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [ "$DRY_RUN" != "true" ]; then
        # Call existing create-iam-roles.sh script
        if [ -f "$SCRIPT_DIR/create-iam-roles.sh" ]; then
            "$SCRIPT_DIR/create-iam-roles.sh"
            
            # Annotate service accounts with role ARNs
            echo ""
            echo -e "${BLUE}📝 Annotating service accounts with IAM role ARNs...${NC}"
            
            # Fluent Bit
            FLUENT_BIT_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/fluent-bit-role"
            if kubectl get serviceaccount fluent-bit -n kube-system &> /dev/null; then
                kubectl annotate serviceaccount fluent-bit -n kube-system \
                    eks.amazonaws.com/role-arn="$FLUENT_BIT_ROLE_ARN" \
                    --overwrite &> /dev/null || true
                echo -e "${GREEN}✅ Annotated fluent-bit service account${NC}"
            fi
            
            # External Secrets
            EXTERNAL_SECRETS_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/external-secrets-role"
            if kubectl get serviceaccount external-secrets -n external-secrets-system &> /dev/null; then
                kubectl annotate serviceaccount external-secrets -n external-secrets-system \
                    eks.amazonaws.com/role-arn="$EXTERNAL_SECRETS_ROLE_ARN" \
                    --overwrite &> /dev/null || true
                echo -e "${GREEN}✅ Annotated external-secrets service account${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️  create-iam-roles.sh not found. Skipping IAM role creation.${NC}"
        fi
    else
        echo -e "${YELLOW}[DRY RUN] Would create IAM roles and annotate service accounts${NC}"
    fi
    
    echo ""
else
    echo -e "${YELLOW}⏭️  Skipping IAM role creation${NC}"
    echo ""
fi

# ==============================================================================
# Step 3: Deploy MongoDB
# ==============================================================================
if [ "$SKIP_MONGODB" != "true" ]; then
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Step 3: Deploy MongoDB${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [ "$DRY_RUN" != "true" ]; then
        # Create namespaces
        echo -e "${BLUE}📦 Creating namespaces...${NC}"
        kubectl apply -f "$PROJECT_ROOT/k8s/base/namespaces.yaml"
        echo -e "${GREEN}✅ Namespaces created${NC}"
        echo ""
        
        # Create storage class
        echo -e "${BLUE}💾 Creating storage class...${NC}"
        kubectl apply -f "$PROJECT_ROOT/k8s/mongodb/storageclass.yaml"
        echo -e "${GREEN}✅ Storage class created${NC}"
        echo ""
        
        # Create Kubernetes secrets (if not using External Secrets)
        if [ "$USE_EXTERNAL_SECRETS" != "true" ]; then
            echo -e "${BLUE}🔐 Creating Kubernetes secrets...${NC}"
            
            # Get password from AWS Secrets Manager if not provided
            if [ -z "$MONGODB_PASSWORD" ]; then
                MONGO_SECRET_JSON=$(aws secretsmanager get-secret-value \
                    --secret-id "eventsphere/mongodb" \
                    --region "$AWS_REGION" \
                    --query SecretString --output text)
                MONGODB_PASSWORD=$(echo "$MONGO_SECRET_JSON" | grep -o '"password":"[^"]*"' | cut -d'"' -f4)
            fi
            
            if [ -z "$JWT_SECRET" ]; then
                JWT_SECRET_JSON=$(aws secretsmanager get-secret-value \
                    --secret-id "eventsphere/auth-service" \
                    --region "$AWS_REGION" \
                    --query SecretString --output text)
                JWT_SECRET=$(echo "$JWT_SECRET_JSON" | grep -o '"jwt-secret":"[^"]*"' | cut -d'"' -f4)
            fi
            
            MONGO_CONNECTION_STRING="mongodb://admin:${MONGODB_PASSWORD}@mongodb.prod.svc.cluster.local:27017/eventsphere?authSource=admin"
            
            # Create MongoDB secret
            kubectl create secret generic mongodb-secret \
                --from-literal=username=admin \
                --from-literal=password="$MONGODB_PASSWORD" \
                --from-literal=connection-string="$MONGO_CONNECTION_STRING" \
                -n prod \
                --dry-run=client -o yaml | kubectl apply -f -
            
            # Create auth service secret
            kubectl create secret generic auth-service-secret \
                --from-literal=jwt-secret="$JWT_SECRET" \
                -n prod \
                --dry-run=client -o yaml | kubectl apply -f -
            
            # Get SNS Topic ARN from AWS Secrets Manager
            if aws secretsmanager describe-secret --secret-id "eventsphere/notification-service" --region "$AWS_REGION" &> /dev/null; then
                NOTIFICATION_SECRET_JSON=$(aws secretsmanager get-secret-value \
                    --secret-id "eventsphere/notification-service" \
                    --region "$AWS_REGION" \
                    --query SecretString --output text)
                SNS_TOPIC_ARN=$(echo "$NOTIFICATION_SECRET_JSON" | grep -o '"sns-topic-arn":"[^"]*"' | cut -d'"' -f4)
                
                # Create notification service secret
                kubectl create secret generic notification-service-secret \
                    --from-literal=sns-topic-arn="$SNS_TOPIC_ARN" \
                    -n prod \
                    --dry-run=client -o yaml | kubectl apply -f -
            else
                echo -e "${YELLOW}⚠️  SNS Topic ARN not found in Secrets Manager. Skipping notification service secret.${NC}"
            fi
            
            echo -e "${GREEN}✅ Kubernetes secrets created${NC}"
            echo ""
        else
            echo -e "${BLUE}📋 Using External Secrets Operator...${NC}"
            # Deploy External Secrets configuration
            if [ -f "$PROJECT_ROOT/k8s/security/external-secrets.yaml" ]; then
                kubectl apply -f "$PROJECT_ROOT/k8s/security/external-secrets.yaml"
                echo -e "${GREEN}✅ External Secrets configuration applied${NC}"
                
                # Wait for secrets to be synced
                echo "⏳ Waiting for External Secrets to sync..."
                echo "   (This may take up to 60 seconds for External Secrets Operator to sync)"
                for i in {1..12}; do
                    if kubectl get secret mongodb-secret -n prod &> /dev/null && \
                       kubectl get secret auth-service-secret -n prod &> /dev/null; then
                        echo -e "${GREEN}✅ External Secrets synced${NC}"
                        break
                    fi
                    echo "   Waiting... ($i/12)"
                    sleep 5
                done
                
                if ! kubectl get secret mongodb-secret -n prod &> /dev/null; then
                    echo -e "${YELLOW}⚠️  External Secrets not synced yet. They will sync automatically.${NC}"
                fi
            else
                echo -e "${YELLOW}⚠️  external-secrets.yaml not found. Skipping External Secrets setup.${NC}"
            fi
            echo ""
        fi
        
        # Deploy MongoDB
        echo -e "${BLUE}🐳 Deploying MongoDB...${NC}"
        kubectl apply -f "$PROJECT_ROOT/k8s/mongodb/"
        echo -e "${GREEN}✅ MongoDB deployment initiated${NC}"
        echo ""
        
        # Wait for MongoDB to be ready
        echo -e "${BLUE}⏳ Waiting for MongoDB to be ready...${NC}"
        kubectl wait --for=condition=ready pod -l app=mongodb -n prod --timeout=300s || {
            echo -e "${YELLOW}⚠️  MongoDB pod not ready within timeout. Checking status...${NC}"
            kubectl get pods -n prod -l app=mongodb
            kubectl describe pod -n prod -l app=mongodb | tail -20
        }
        
        # Verify MongoDB
        echo ""
        echo -e "${BLUE}🔍 Verifying MongoDB deployment...${NC}"
        kubectl get pods -n prod -l app=mongodb
        kubectl get pvc -n prod
        echo ""
        
        # Test MongoDB connection
        MONGODB_POD=$(kubectl get pod -n prod -l app=mongodb -o jsonpath='{.items[0].metadata.name}')
        if [ -n "$MONGODB_POD" ]; then
            if kubectl exec -n prod "$MONGODB_POD" -- mongosh --eval "db.adminCommand('ping')" &> /dev/null; then
                echo -e "${GREEN}✅ MongoDB is running and responding to ping${NC}"
            else
                echo -e "${YELLOW}⚠️  MongoDB pod exists but connection test failed${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}[DRY RUN] Would:${NC}"
        echo "  - Create namespaces"
        echo "  - Create storage class"
        echo "  - Create Kubernetes secrets (or use External Secrets)"
        echo "  - Deploy MongoDB StatefulSet and Service"
        echo "  - Wait for MongoDB to be ready"
    fi
    
    echo ""
else
    echo -e "${YELLOW}⏭️  Skipping MongoDB deployment${NC}"
    echo ""
fi

# ==============================================================================
# Step 4: Deploy Microservices
# ==============================================================================
if [ "$SKIP_SERVICES" != "true" ]; then
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Step 4: Deploy Microservices${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Check if templates are processed
    GENERATED_DIR="$PROJECT_ROOT/k8s/generated"
    if [ ! -d "$GENERATED_DIR" ] || [ -z "$(ls -A "$GENERATED_DIR/base" 2>/dev/null)" ]; then
        echo -e "${YELLOW}⚠️  Generated manifests not found. Processing templates...${NC}"
        if [ -f "$SCRIPT_DIR/process-templates.sh" ]; then
            "$SCRIPT_DIR/process-templates.sh"
        else
            echo -e "${RED}❌ process-templates.sh not found. Please run it manually first.${NC}"
            exit 1
        fi
        echo ""
    fi
    
    if [ "$DRY_RUN" != "true" ]; then
        # Apply ConfigMaps
        echo -e "${BLUE}📋 Applying ConfigMaps...${NC}"
        kubectl apply -f "$GENERATED_DIR/base/configmaps.yaml"
        echo -e "${GREEN}✅ ConfigMaps applied${NC}"
        echo ""
        
        # Apply RBAC
        echo -e "${BLUE}🔐 Applying RBAC...${NC}"
        kubectl apply -f "$GENERATED_DIR/base/rbac.yaml"
        echo -e "${GREEN}✅ RBAC applied${NC}"
        echo ""
        
        # Apply Deployments and Services
        echo -e "${BLUE}🚀 Applying Deployments and Services...${NC}"
        kubectl apply -f "$GENERATED_DIR/base/"
        echo -e "${GREEN}✅ Deployments and Services applied${NC}"
        echo ""
        
        # Apply HPA
        if [ -d "$PROJECT_ROOT/k8s/hpa" ]; then
            echo -e "${BLUE}📊 Applying HPA configurations...${NC}"
            kubectl apply -f "$PROJECT_ROOT/k8s/hpa/"
            echo -e "${GREEN}✅ HPA configurations applied${NC}"
            echo ""
        fi
        
        # Wait for deployments to be ready
        echo -e "${BLUE}⏳ Waiting for deployments to be ready...${NC}"
        for deployment in auth-service event-service booking-service frontend; do
            if kubectl get deployment "$deployment" -n prod &> /dev/null; then
                if kubectl wait --for=condition=available --timeout=300s deployment/"$deployment" -n prod 2>/dev/null; then
                    echo -e "${GREEN}✅ Deployment $deployment is ready${NC}"
                else
                    echo -e "${RED}❌ Deployment $deployment not ready within timeout${NC}"
                    echo ""
                    echo -e "${YELLOW}🔍 Troubleshooting $deployment:${NC}"
                    
                    # Show deployment status
                    echo "Deployment status:"
                    kubectl get deployment "$deployment" -n prod
                    echo ""
                    
                    # Show replica set status
                    echo "ReplicaSet status:"
                    kubectl get rs -n prod -l app="$deployment"
                    echo ""
                    
                    # Show pod status
                    echo "Pod status:"
                    kubectl get pods -n prod -l app="$deployment"
                    echo ""
                    
                    # Show pod events
                    PODS=$(kubectl get pods -n prod -l app="$deployment" -o jsonpath='{.items[*].metadata.name}')
                    for pod in $PODS; do
                        if [ -n "$pod" ]; then
                            echo "Events for pod $pod:"
                            kubectl describe pod "$pod" -n prod | grep -A 20 "Events:" || kubectl get events -n prod --field-selector involvedObject.name="$pod" --sort-by='.lastTimestamp' | tail -10
                            echo ""
                            
                            # Show pod logs if container is running
                            if kubectl get pod "$pod" -n prod -o jsonpath='{.status.containerStatuses[0].ready}' | grep -q "true"; then
                                echo "Recent logs for $pod:"
                                kubectl logs "$pod" -n prod --tail=20 2>&1 || true
                            else
                                echo "Container not ready, showing init container logs if available:"
                                kubectl logs "$pod" -n prod --all-containers=true --tail=20 2>&1 || true
                            fi
                            echo ""
                        fi
                    done
                    
                    # Common issues and solutions
                    echo -e "${YELLOW}💡 Common issues and solutions:${NC}"
                    echo "  1. Image pull errors: Check ECR authentication and image exists"
                    echo "  2. Missing secrets: Verify secrets are created (mongodb-secret, auth-service-secret)"
                    echo "  3. Resource constraints: Check node capacity and resource requests"
                    echo "  4. Configuration errors: Check ConfigMap and environment variables"
                    echo ""
                    echo "Run these commands for more details:"
                    echo "  kubectl describe deployment $deployment -n prod"
                    echo "  kubectl logs -n prod -l app=$deployment --tail=50"
                    echo ""
                fi
            fi
        done
        echo ""
        
        # Verify deployments
        echo -e "${BLUE}🔍 Verifying deployments...${NC}"
        kubectl get deployments -n prod
        kubectl get pods -n prod
        kubectl get services -n prod
        echo ""
        
        # Check pod status
        # Get pods that are not Running or Succeeded (using grep to avoid jsonpath limitations)
        NON_RUNNING_PODS=$(kubectl get pods -n prod --no-headers 2>/dev/null | grep -v -E "(Running|Succeeded)" | awk '{print $1}' || true)
        
        if [ -n "$NON_RUNNING_PODS" ]; then
            echo -e "${YELLOW}⚠️  Some pods are not in Running state:${NC}"
            kubectl get pods -n prod | grep -v -E "(Running|Succeeded|NAME)"
        else
            echo -e "${GREEN}✅ All pods are running${NC}"
        fi
    else
        echo -e "${YELLOW}[DRY RUN] Would:${NC}"
        echo "  - Apply ConfigMaps"
        echo "  - Apply RBAC"
        echo "  - Apply Deployments and Services"
        echo "  - Apply HPA configurations"
        echo "  - Wait for deployments to be ready"
    fi
    
    echo ""
else
    echo -e "${YELLOW}⏭️  Skipping microservices deployment${NC}"
    echo ""
fi

# ==============================================================================
# Step 5: Deploy Ingress
# ==============================================================================
if [ "$SKIP_INGRESS" != "true" ]; then
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Step 5: Deploy Ingress${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    INGRESS_DIR="$PROJECT_ROOT/k8s/generated/ingress"
    
    if [ ! -d "$INGRESS_DIR" ]; then
        echo -e "${YELLOW}⚠️  Ingress directory not found: $INGRESS_DIR${NC}"
        echo -e "${YELLOW}   Checking for template directory...${NC}"
        INGRESS_TEMPLATE_DIR="$PROJECT_ROOT/k8s/ingress"
        if [ -d "$INGRESS_TEMPLATE_DIR" ]; then
            echo -e "${BLUE}📝 Using ingress files from template directory${NC}"
            INGRESS_DIR="$INGRESS_TEMPLATE_DIR"
        else
            echo -e "${RED}❌ Ingress directory not found. Skipping ingress deployment.${NC}"
            echo ""
            SKIP_INGRESS=true
        fi
    fi
    
    if [ "$SKIP_INGRESS" != "true" ]; then
        if [ "$DRY_RUN" != "true" ]; then
            # Check if AWS Load Balancer Controller is installed
            echo -e "${BLUE}🔍 Checking for AWS Load Balancer Controller...${NC}"
            if ! kubectl get deployment aws-load-balancer-controller -n kube-system &> /dev/null; then
                echo -e "${YELLOW}⚠️  AWS Load Balancer Controller not found.${NC}"
                echo -e "${YELLOW}   Ingress will be created but may not work without the controller.${NC}"
                echo -e "${YELLOW}   Install it with: helm install aws-load-balancer-controller eks/aws-load-balancer-controller${NC}"
                echo ""
            else
                echo -e "${GREEN}✅ AWS Load Balancer Controller found${NC}"
                echo ""
            fi
            
            # Deploy IngressClass
            if [ -f "$INGRESS_DIR/ingress-class.yaml" ]; then
                echo -e "${BLUE}📦 Deploying IngressClass...${NC}"
                kubectl apply -f "$INGRESS_DIR/ingress-class.yaml"
                echo -e "${GREEN}✅ IngressClass deployed${NC}"
                echo ""
            else
                echo -e "${YELLOW}⚠️  ingress-class.yaml not found. Skipping...${NC}"
            fi
            
            # Deploy Ingress
            if [ -f "$INGRESS_DIR/ingress.yaml" ]; then
                echo -e "${BLUE}📦 Deploying Ingress...${NC}"
                kubectl apply -f "$INGRESS_DIR/ingress.yaml"
                echo -e "${GREEN}✅ Ingress deployed${NC}"
                echo ""
                
                # Wait for ingress to be ready and get the ALB address
                echo -e "${BLUE}⏳ Waiting for ingress to be ready...${NC}"
                sleep 5
                
                # Get ingress status
                INGRESS_NAME="eventsphere-ingress"
                if kubectl get ingress "$INGRESS_NAME" -n prod &> /dev/null; then
                    echo -e "${GREEN}✅ Ingress created successfully${NC}"
                    echo ""
                    echo -e "${BLUE}📋 Ingress details:${NC}"
                    kubectl get ingress "$INGRESS_NAME" -n prod
                    echo ""
                    
                    # Try to get the ALB address (may take a few minutes to provision)
                    ALB_ADDRESS=$(kubectl get ingress "$INGRESS_NAME" -n prod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
                    if [ -n "$ALB_ADDRESS" ]; then
                        echo -e "${GREEN}✅ ALB Address: $ALB_ADDRESS${NC}"
                        echo ""
                        echo -e "${YELLOW}⚠️  Note: It may take 2-5 minutes for the ALB to be fully provisioned.${NC}"
                        echo -e "${YELLOW}   Check status with: kubectl get ingress $INGRESS_NAME -n prod${NC}"
                    else
                        echo -e "${YELLOW}⚠️  ALB address not yet available. It may take 2-5 minutes to provision.${NC}"
                        echo -e "${YELLOW}   Check status with: kubectl get ingress $INGRESS_NAME -n prod${NC}"
                    fi
                else
                    echo -e "${YELLOW}⚠️  Ingress not found. It may still be creating...${NC}"
                fi
            else
                echo -e "${RED}❌ ingress.yaml not found in $INGRESS_DIR${NC}"
            fi
        else
            echo -e "${YELLOW}[DRY RUN] Would:${NC}"
            echo "  - Deploy IngressClass"
            echo "  - Deploy Ingress"
            echo "  - Wait for ALB provisioning"
        fi
        
        echo ""
    fi
else
    echo -e "${YELLOW}⏭️  Skipping ingress deployment${NC}"
    echo ""
fi

# ==============================================================================
# Summary
# ==============================================================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Deployment completed!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Summary:"
[ "$SKIP_SECRETS" != "true" ] && echo "  ✅ AWS Secrets Manager configured"
[ "$SKIP_IAM" != "true" ] && echo "  ✅ IAM roles created and annotated"
[ "$SKIP_MONGODB" != "true" ] && echo "  ✅ MongoDB deployed"
[ "$SKIP_SERVICES" != "true" ] && echo "  ✅ Microservices deployed"
[ "$SKIP_INGRESS" != "true" ] && echo "  ✅ Ingress deployed"
echo ""
echo "Next steps:"
if [ "$SKIP_INGRESS" == "true" ]; then
    echo "  1. Configure Ingress: kubectl apply -f k8s/generated/ingress/"
    echo "  2. Deploy monitoring: kubectl apply -f monitoring/cloudwatch/generated/"
    echo "  3. Verify services: kubectl get all -n prod"
else
    echo "  1. Deploy monitoring: kubectl apply -f monitoring/cloudwatch/generated/"
    echo "  2. Verify services: kubectl get all -n prod"
    echo "  3. Check ingress status: kubectl get ingress eventsphere-ingress -n prod"
fi
echo ""

