# EventSphere Observability Stack

This directory contains the complete observability setup for EventSphere, including logging, metrics, dashboards, and alerting.

## 📁 Directory Structure

```
monitoring/
├── README.md                          # This file
├── cloudwatch/
│   └── fluent-bit-config.yaml        # Fluent Bit DaemonSet for CloudWatch Logs
├── prometheus/
│   ├── values.yaml                   # Helm values for kube-prometheus-stack
│   ├── servicemonitors.yaml          # ServiceMonitors for EventSphere services
│   └── alertrules.yaml               # Prometheus alert rules
├── grafana/
│   └── dashboards/
│       └── eventsphere-dashboard.json # Pre-built Grafana dashboard
└── alertmanager/
    └── alertmanager-config.yaml      # AlertManager routing and SNS config
```

## 🚀 Quick Start

### Deploy Everything

```bash
# Run the deployment script
cd infrastructure/scripts
chmod +x deploy-observability.sh
./deploy-observability.sh
```

### Deploy Individual Components

```bash
# Deploy only Fluent Bit
./deploy-observability.sh --skip-prometheus --skip-alerts

# Deploy only Prometheus/Grafana
./deploy-observability.sh --skip-fluent-bit --skip-alerts

# Skip alert configuration
./deploy-observability.sh --skip-alerts
```

## 📊 Components

### 1. Logging (CloudWatch + Fluent Bit)

**Purpose**: Centralized log aggregation for all container logs

**Features**:
- Ships all container logs to CloudWatch Logs
- Structured JSON log parsing
- 30-day retention for application logs
- 14-day retention for dataplane logs

**Log Groups**:
- `/aws/eks/eventsphere-cluster/application` - Application container logs
- `/aws/eks/eventsphere-cluster/dataplane` - Kubernetes system logs

**Access Logs**:
```bash
# Via AWS CLI
aws logs tail /aws/eks/eventsphere-cluster/application --follow

# Filter by service
aws logs filter-log-events \
  --log-group-name /aws/eks/eventsphere-cluster/application \
  --filter-pattern '{ $.kubernetes_labels_app = "auth-service" }'
```

### 2. Metrics (Prometheus)

**Purpose**: Time-series metrics collection and storage

**Features**:
- 15-day metric retention
- ServiceMonitors for automatic service discovery
- Custom scrape configs for EventSphere services
- Node, pod, and container metrics

**Access Prometheus**:
```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Open http://localhost:9090
```

**Example Queries**:
```promql
# Request rate by service
sum(rate(http_requests_total{namespace="prod"}[5m])) by (app)

# P99 latency
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="prod"}[5m])) by (le, app))

# Error rate
sum(rate(http_requests_total{status_code=~"5.."}[5m])) by (app) / sum(rate(http_requests_total[5m])) by (app)

# Pod memory usage
container_memory_working_set_bytes{namespace="prod", container!=""}
```

### 3. Dashboards (Grafana)

**Purpose**: Visualization and monitoring dashboards

**Features**:
- Pre-built EventSphere dashboard
- Request rate, latency, and error metrics
- Resource usage (CPU, memory, network)
- HPA status and scaling metrics
- Pod health overview

**Access Grafana**:
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open http://localhost:3000
# Username: admin
# Password: EventSphere2024!
```

**Available Dashboards**:
- EventSphere Application Dashboard (eventsphere-main)
- Kubernetes cluster metrics (built-in)
- Node exporter metrics (built-in)

### 4. Alerting (AlertManager + SNS)

**Purpose**: Alert routing and notification delivery

**Alert Categories**:

| Alert | Severity | Threshold | Description |
|-------|----------|-----------|-------------|
| HighErrorRate | Critical | >5% errors | 5xx responses exceeding threshold |
| HighLatencyP99 | Warning | >2s | P99 latency above 2 seconds |
| PodCrashLooping | Critical | >3 restarts/15m | Pod restarting repeatedly |
| HighMemoryUsage | Warning | >90% | Memory near limit |
| HighCPUUsage | Warning | >80% | CPU usage high |
| MongoDBDown | Critical | down | Database not responding |
| HPAAtMaxReplicas | Warning | at max | HPA cannot scale further |

**SNS Topics**:
- `eventsphere-alerts` - General warnings
- `eventsphere-critical-alerts` - Critical alerts
- `eventsphere-database-alerts` - Database team alerts

**Configure Notifications**:
```bash
# Subscribe email to alerts
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:ACCOUNT_ID:eventsphere-alerts \
  --protocol email \
  --notification-endpoint your-email@example.com
```

## 🔧 Adding Metrics to Your Services

To enable Prometheus scraping for your Node.js services, add the `prom-client` library:

### 1. Install prom-client

```bash
npm install prom-client
```

### 2. Add Metrics to Your Service

```javascript
const express = require('express');
const client = require('prom-client');

const app = express();

// Collect default metrics
const collectDefaultMetrics = client.collectDefaultMetrics;
collectDefaultMetrics({ prefix: 'myservice_' });

// Custom metrics
const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.1, 0.3, 0.5, 0.7, 1, 3, 5, 7, 10]
});

const httpRequestTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code']
});

// Middleware to track metrics
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    httpRequestDuration.labels(req.method, req.path, res.statusCode).observe(duration);
    httpRequestTotal.labels(req.method, req.path, res.statusCode).inc();
  });
  next();
});

// Metrics endpoint
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});
```

### 3. Add Prometheus Annotations to Your Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "4001"
    prometheus.io/path: "/metrics"
```

## 🛠️ Troubleshooting

### Fluent Bit Not Shipping Logs

```bash
# Check Fluent Bit pods
kubectl get pods -n amazon-cloudwatch -l k8s-app=fluent-bit

# Check logs
kubectl logs -n amazon-cloudwatch -l k8s-app=fluent-bit --tail=50

# Verify IAM role
kubectl get sa fluent-bit -n amazon-cloudwatch -o yaml | grep eks.amazonaws.com/role-arn
```

### Prometheus Not Scraping Metrics

```bash
# Check targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Visit http://localhost:9090/targets

# Check ServiceMonitors
kubectl get servicemonitors -n monitoring

# Verify service has correct labels
kubectl get svc -n prod --show-labels
```

### Alerts Not Firing

```bash
# Check AlertManager
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-alertmanager 9093:9093
# Visit http://localhost:9093

# Check alert rules
kubectl get prometheusrules -n monitoring

# Verify SNS topic permissions
aws sns list-subscriptions-by-topic --topic-arn arn:aws:sns:us-east-1:ACCOUNT_ID:eventsphere-alerts
```

### Grafana Dashboard Empty

```bash
# Check data source
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Go to Configuration > Data Sources > Prometheus > Test

# Check if metrics exist
# In Prometheus, query: up{namespace="prod"}
```

## 📈 Metrics Reference

### Application Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `http_requests_total` | Counter | method, route, status_code, app | Total HTTP requests |
| `http_request_duration_seconds` | Histogram | method, route, status_code, app | Request latency |

### Kubernetes Metrics

| Metric | Description |
|--------|-------------|
| `kube_pod_status_phase` | Pod lifecycle phase |
| `kube_pod_container_status_restarts_total` | Container restart count |
| `container_cpu_usage_seconds_total` | CPU usage |
| `container_memory_working_set_bytes` | Memory usage |
| `kube_horizontalpodautoscaler_status_current_replicas` | HPA replica count |

## 🔒 Security Considerations

1. **Grafana Password**: Change the default password in production
2. **SNS Access**: Restrict SNS publish permissions to AlertManager
3. **IRSA**: Use IAM Roles for Service Accounts for Fluent Bit
4. **Network Policies**: Restrict access to monitoring namespace
5. **Secrets**: Store sensitive configs in AWS Secrets Manager

## 📚 Related Documentation

- [Troubleshooting Runbook](../docs/runbooks/TROUBLESHOOTING.md)
- [Deployment Guide](../DEPLOYMENT.md)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [AWS CloudWatch Logs](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/)

