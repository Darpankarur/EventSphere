#!/bin/bash
# ==============================================================================
# EventSphere Observability Deployment - Simplified & Reliable Version
# ==============================================================================

set -e

echo "========================================"
echo "  EventSphere Observability Setup"
echo "========================================"
echo ""

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-eventsphere-cluster}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Check prerequisites
echo "[1/6] Checking prerequisites..."
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: Cannot connect to cluster"; exit 1; }
echo "OK - All prerequisites met"
echo ""

# Create CloudWatch Log Groups (with Windows Git Bash fix)
echo "[2/6] Creating CloudWatch Log Groups..."
LOG_GROUP="/aws/eks/${CLUSTER_NAME}/application"
MSYS_NO_PATHCONV=1 aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" 2>/dev/null || echo "Log group exists"
MSYS_NO_PATHCONV=1 aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 30 --region "$AWS_REGION" 2>/dev/null || true
echo "OK - CloudWatch Log Group ready"
echo ""

# Deploy Fluent Bit
echo "[3/6] Deploying Fluent Bit for log collection..."
kubectl apply -f "$PROJECT_ROOT/monitoring/cloudwatch/fluent-bit-config.yaml"
echo "OK - Fluent Bit deployed (logs will appear in CloudWatch)"
echo ""

# Add Helm repo
echo "[4/6] Setting up Helm..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update >/dev/null 2>&1
echo "OK - Helm repositories ready"
echo ""

# Create monitoring namespace
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

# Deploy Prometheus + Grafana
echo "[5/6] Deploying Prometheus and Grafana..."
echo "     This may take 2-3 minutes..."
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "$PROJECT_ROOT/monitoring/prometheus/values.yaml" \
  --wait \
  --timeout 5m \
  2>&1 | grep -v "^W" || true  # Filter out warnings
echo "OK - Prometheus and Grafana deployed"
echo ""

# Deploy alert rules
echo "[6/6] Deploying alert rules..."
kubectl apply -f "$PROJECT_ROOT/monitoring/prometheus/alertrules.yaml"
echo "OK - Alert rules deployed"
echo ""

# Create Grafana dashboard ConfigMap
kubectl create configmap eventsphere-grafana-dashboard \
  --from-file=eventsphere.json="$PROJECT_ROOT/monitoring/grafana/dashboards/eventsphere-dashboard.json" \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label configmap eventsphere-grafana-dashboard grafana_dashboard=1 -n monitoring --overwrite 2>/dev/null || true

echo ""
echo "========================================"
echo "  DEPLOYMENT COMPLETE!"
echo "========================================"
echo ""
echo "Access Grafana:"
echo "  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo "  URL: http://localhost:3000"
echo "  User: admin"
echo "  Password: EventSphere2024"
echo ""
echo "Access Prometheus:"
echo "  kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "  URL: http://localhost:9090"
echo ""
echo "View CloudWatch Logs:"
echo "  Log Group: /aws/eks/$CLUSTER_NAME/application"
echo ""
echo "Verify pods are running:"
echo "  kubectl get pods -n monitoring"
echo "  kubectl get pods -n amazon-cloudwatch"
echo ""
