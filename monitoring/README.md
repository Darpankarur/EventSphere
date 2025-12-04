# EventSphere Observability

Simple, reliable observability stack for EventSphere.

## What's Included

| Component | Purpose | Access |
|-----------|---------|--------|
| **Fluent Bit** | Ships container logs to CloudWatch | CloudWatch Console |
| **Prometheus** | Collects metrics from Kubernetes | `localhost:9090` |
| **Grafana** | Visualizes metrics dashboards | `localhost:3000` |
| **AlertManager** | Handles alerts | Built into Prometheus stack |

## Quick Start

```bash
cd infrastructure/scripts
chmod +x deploy-observability.sh
./deploy-observability.sh
```

## Access Dashboards

### Grafana
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```
- URL: http://localhost:3000
- Username: `admin`
- Password: `EventSphere2024`

### Prometheus
```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
```
- URL: http://localhost:9090

## CloudWatch Logs

View application logs in AWS Console:
- Log Group: `/aws/eks/eventsphere-cluster/application`

Or via CLI:
```bash
aws logs tail /aws/eks/eventsphere-cluster/application --follow
```

## Alerts Configured

| Alert | Condition | Severity |
|-------|-----------|----------|
| PodCrashLooping | Pod restarting frequently | Critical |
| PodNotReady | Pod stuck in Pending/Failed | Warning |
| HighMemoryUsage | Memory > 90% of limit | Warning |
| HighCPUUsage | CPU > 80% of limit | Warning |
| DeploymentReplicasMismatch | Replicas not matching desired | Warning |
| HPAAtMaxReplicas | HPA at maximum for 15min | Warning |

## Verify Deployment

```bash
# Check monitoring pods
kubectl get pods -n monitoring

# Check Fluent Bit pods
kubectl get pods -n amazon-cloudwatch

# Check alerts
kubectl get prometheusrules -n monitoring
```

## Troubleshooting

### Pods not starting
```bash
kubectl describe pod <pod-name> -n monitoring
kubectl logs <pod-name> -n monitoring
```

### No metrics in Grafana
1. Check Prometheus is running: `kubectl get pods -n monitoring | grep prometheus`
2. Check targets: Go to Prometheus UI → Status → Targets

### No logs in CloudWatch
1. Check Fluent Bit: `kubectl get pods -n amazon-cloudwatch`
2. Check logs: `kubectl logs -n amazon-cloudwatch -l app=fluent-bit`
