#!/bin/bash
# ==============================================================================
# EventSphere Observability Stack Deployment Script
# ==============================================================================
# This script deploys the complete observability stack including:
# - Fluent Bit for CloudWatch Logs
# - Prometheus for metrics collection
# - Grafana for dashboards
# - AlertManager for alert notifications
# ==============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MONITORING_DIR="$PROJECT_ROOT/monitoring"

# Configuration
AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME=${CLUSTER_NAME:-eventsphere-cluster}
NAMESPACE_MONITORING="monitoring"
NAMESPACE_CLOUDWATCH="amazon-cloudwatch"

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found. Please install kubectl."
        exit 1
    fi
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        print_error "helm not found. Please install helm."
        exit 1
    fi
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found. Please install AWS CLI."
        exit 1
    fi
    
    # Check cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi
    
    print_success "All prerequisites met."
}

# Function to get AWS Account ID
get_aws_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        print_error "Failed to get AWS Account ID. Please check your AWS credentials."
        exit 1
    fi
    print_status "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Function to create SNS topics for alerts
create_sns_topics() {
    print_status "Creating SNS topics for alerts..."
    
    # Create main alerts topic
    aws sns create-topic --name eventsphere-alerts --region $AWS_REGION 2>/dev/null || true
    print_success "Created/verified SNS topic: eventsphere-alerts"
    
    # Create critical alerts topic
    aws sns create-topic --name eventsphere-critical-alerts --region $AWS_REGION 2>/dev/null || true
    print_success "Created/verified SNS topic: eventsphere-critical-alerts"
    
    # Create database alerts topic
    aws sns create-topic --name eventsphere-database-alerts --region $AWS_REGION 2>/dev/null || true
    print_success "Created/verified SNS topic: eventsphere-database-alerts"
    
    print_warning "Remember to subscribe email addresses to the SNS topics in AWS Console!"
}

# Function to create IAM role for Fluent Bit
create_fluent_bit_iam_role() {
    print_status "Setting up IAM role for Fluent Bit..."
    
    # Check if the service account already exists with IRSA
    EXISTING_ROLE=$(kubectl get sa fluent-bit -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_ROLE" ]; then
        print_success "Fluent Bit IAM role already configured: $EXISTING_ROLE"
        return
    fi
    
    print_warning "Fluent Bit IAM role should be created via eksctl or manually."
    print_warning "Ensure the role has CloudWatchAgentServerPolicy attached."
}

# Function to deploy Fluent Bit
deploy_fluent_bit() {
    print_status "Deploying Fluent Bit for CloudWatch Logs..."
    
    # Create namespace if not exists
    kubectl create namespace $NAMESPACE_CLOUDWATCH --dry-run=client -o yaml | kubectl apply -f -
    
    # Process the Fluent Bit config template
    sed "s/\${AWS_ACCOUNT_ID}/$AWS_ACCOUNT_ID/g" "$MONITORING_DIR/cloudwatch/fluent-bit-config.yaml" | \
    sed "s/\${AWS_REGION}/$AWS_REGION/g" | \
    kubectl apply -f -
    
    # Wait for Fluent Bit to be ready
    print_status "Waiting for Fluent Bit pods to be ready..."
    kubectl wait --for=condition=ready pod -l k8s-app=fluent-bit -n $NAMESPACE_CLOUDWATCH --timeout=120s || true
    
    print_success "Fluent Bit deployed successfully."
}

# Function to add Helm repositories
add_helm_repos() {
    print_status "Adding Helm repositories..."
    
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo update
    
    print_success "Helm repositories updated."
}

# Function to deploy Prometheus stack
deploy_prometheus_stack() {
    print_status "Deploying Prometheus and Grafana stack..."
    
    # Create monitoring namespace
    kubectl create namespace $NAMESPACE_MONITORING --dry-run=client -o yaml | kubectl apply -f -
    
    # Install/upgrade kube-prometheus-stack
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        -n $NAMESPACE_MONITORING \
        -f "$MONITORING_DIR/prometheus/values.yaml" \
        --wait \
        --timeout 10m
    
    print_success "Prometheus stack deployed successfully."
}

# Function to deploy ServiceMonitors
deploy_service_monitors() {
    print_status "Deploying ServiceMonitors..."
    
    kubectl apply -f "$MONITORING_DIR/prometheus/servicemonitors.yaml"
    
    print_success "ServiceMonitors deployed."
}

# Function to deploy alert rules
deploy_alert_rules() {
    print_status "Deploying Prometheus Alert Rules..."
    
    kubectl apply -f "$MONITORING_DIR/prometheus/alertrules.yaml"
    
    print_success "Alert rules deployed."
}

# Function to deploy AlertManager config
deploy_alertmanager_config() {
    print_status "Deploying AlertManager configuration..."
    
    # Process the AlertManager config template
    sed "s/\${AWS_ACCOUNT_ID}/$AWS_ACCOUNT_ID/g" "$MONITORING_DIR/alertmanager/alertmanager-config.yaml" | \
    kubectl apply -f -
    
    # Restart AlertManager to pick up new config
    kubectl rollout restart statefulset alertmanager-prometheus-kube-prometheus-alertmanager -n $NAMESPACE_MONITORING 2>/dev/null || true
    
    print_success "AlertManager configuration deployed."
}

# Function to deploy Grafana dashboards
deploy_grafana_dashboards() {
    print_status "Deploying Grafana dashboards..."
    
    # Create ConfigMap for EventSphere dashboard
    kubectl create configmap eventsphere-dashboard \
        --from-file=eventsphere-dashboard.json="$MONITORING_DIR/grafana/dashboards/eventsphere-dashboard.json" \
        -n $NAMESPACE_MONITORING \
        --dry-run=client -o yaml | \
    kubectl label -f - grafana_dashboard=1 --local --dry-run=client -o yaml | \
    kubectl apply -f -
    
    print_success "Grafana dashboards deployed."
}

# Function to create CloudWatch Log Groups
create_cloudwatch_log_groups() {
    print_status "Creating CloudWatch Log Groups..."
    
    # Application logs
    aws logs create-log-group --log-group-name /aws/eks/$CLUSTER_NAME/application --region $AWS_REGION 2>/dev/null || true
    aws logs put-retention-policy --log-group-name /aws/eks/$CLUSTER_NAME/application --retention-in-days 30 --region $AWS_REGION
    
    # Dataplane logs
    aws logs create-log-group --log-group-name /aws/eks/$CLUSTER_NAME/dataplane --region $AWS_REGION 2>/dev/null || true
    aws logs put-retention-policy --log-group-name /aws/eks/$CLUSTER_NAME/dataplane --retention-in-days 14 --region $AWS_REGION
    
    print_success "CloudWatch Log Groups created/updated."
}

# Function to display access information
display_access_info() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Observability Stack Deployed!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${BLUE}📊 Grafana Access:${NC}"
    echo "   kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    echo "   URL: http://localhost:3000"
    echo "   Username: admin"
    echo "   Password: EventSphere2024!"
    echo ""
    echo -e "${BLUE}📈 Prometheus Access:${NC}"
    echo "   kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
    echo "   URL: http://localhost:9090"
    echo ""
    echo -e "${BLUE}🚨 AlertManager Access:${NC}"
    echo "   kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-alertmanager 9093:9093"
    echo "   URL: http://localhost:9093"
    echo ""
    echo -e "${BLUE}☁️ CloudWatch Logs:${NC}"
    echo "   Log Group: /aws/eks/$CLUSTER_NAME/application"
    echo "   AWS Console: https://$AWS_REGION.console.aws.amazon.com/cloudwatch/home?region=$AWS_REGION#logsV2:log-groups"
    echo ""
    echo -e "${YELLOW}📝 Next Steps:${NC}"
    echo "   1. Subscribe to SNS topics for alert notifications"
    echo "   2. Add Prometheus metrics endpoint to your services (/metrics)"
    echo "   3. Import additional Grafana dashboards as needed"
    echo "   4. Configure alert notification channels in AlertManager"
    echo ""
}

# Function to verify deployment
verify_deployment() {
    print_status "Verifying deployment..."
    
    echo ""
    echo "Fluent Bit pods:"
    kubectl get pods -n $NAMESPACE_CLOUDWATCH -l k8s-app=fluent-bit
    
    echo ""
    echo "Prometheus pods:"
    kubectl get pods -n $NAMESPACE_MONITORING -l app.kubernetes.io/name=prometheus
    
    echo ""
    echo "Grafana pods:"
    kubectl get pods -n $NAMESPACE_MONITORING -l app.kubernetes.io/name=grafana
    
    echo ""
    echo "AlertManager pods:"
    kubectl get pods -n $NAMESPACE_MONITORING -l app.kubernetes.io/name=alertmanager
    
    echo ""
    print_success "Deployment verification complete."
}

# Main function
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     EventSphere Observability Stack Deployment              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Parse arguments
    SKIP_FLUENT_BIT=false
    SKIP_PROMETHEUS=false
    SKIP_ALERTS=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-fluent-bit)
                SKIP_FLUENT_BIT=true
                shift
                ;;
            --skip-prometheus)
                SKIP_PROMETHEUS=true
                shift
                ;;
            --skip-alerts)
                SKIP_ALERTS=true
                shift
                ;;
            --help)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --skip-fluent-bit    Skip Fluent Bit deployment"
                echo "  --skip-prometheus    Skip Prometheus/Grafana deployment"
                echo "  --skip-alerts        Skip alert rules and AlertManager config"
                echo "  --help               Show this help message"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Execute deployment steps
    check_prerequisites
    get_aws_account_id
    create_sns_topics
    create_cloudwatch_log_groups
    add_helm_repos
    
    if [ "$SKIP_FLUENT_BIT" = false ]; then
        deploy_fluent_bit
    else
        print_warning "Skipping Fluent Bit deployment."
    fi
    
    if [ "$SKIP_PROMETHEUS" = false ]; then
        deploy_prometheus_stack
        deploy_service_monitors
        deploy_grafana_dashboards
    else
        print_warning "Skipping Prometheus/Grafana deployment."
    fi
    
    if [ "$SKIP_ALERTS" = false ]; then
        deploy_alert_rules
        deploy_alertmanager_config
    else
        print_warning "Skipping alert rules deployment."
    fi
    
    verify_deployment
    display_access_info
}

# Run main function
main "$@"

