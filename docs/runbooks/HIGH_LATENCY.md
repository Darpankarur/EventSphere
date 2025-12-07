# High Latency (p99) Runbook

> **Alert:** High Latency (p99)  
> **Severity:** Warning / Critical  
> **Threshold:** p99 latency > 2s for 5 minutes (critical), > 500ms for 10 minutes (warning)

---

## 📊 Quick Assessment

### 1. Check Current Latency
```bash
# Via Prometheus (port-forward first)
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090

# Query: p99 latency by service
# histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="prod"}[5m])) by (service, le))
```

### 2. Identify Slow Endpoints
```bash
# Check application logs for slow operations
kubectl logs -n prod -l app=<service-name> --tail=100 | grep -i "slow\|timeout\|took"

# Quick latency test
time curl -s -o /dev/null https://enpm818rgroup7.work.gd/api/events
```

---

## 🔍 Diagnosis Steps

### Step 1: Check Pod Resource Usage
```bash
# High CPU/memory can cause latency
kubectl top pods -n prod --sort-by=cpu
kubectl top pods -n prod --sort-by=memory

# Check if pods are being throttled
kubectl describe pod <pod-name> -n prod | grep -A 5 "Limits:"
```

### Step 2: Check HPA Status
```bash
# Insufficient replicas can cause request queuing
kubectl get hpa -n prod

# If at max replicas, cluster may be overloaded
kubectl describe hpa <service-name>-hpa -n prod
```

### Step 3: Check MongoDB Performance
```bash
# Database queries are often the bottleneck
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.setProfilingLevel(1, {slowms: 100});
  db.system.profile.find().sort({ts: -1}).limit(10).pretty();
"

# Check current operations
kubectl exec -it mongodb-0 -n prod -- mongosh --eval "db.currentOp()"
```

### Step 4: Check Network Latency
```bash
# Test internal network latency
kubectl run network-test --image=busybox --rm -it --restart=Never -- \
  sh -c "time wget -qO- http://event-service.prod.svc.cluster.local:4002/health"

# Check if pods are spread across AZs
kubectl get pods -n prod -o wide
kubectl get nodes -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.'topology\.kubernetes\.io/zone'
```

---

## 🛠️ Remediation Actions

### Scenario 1: Insufficient Replicas

**Symptoms:** HPA showing high utilization, pods at or near resource limits

```bash
# Immediate: Scale up manually
kubectl scale deployment/<service-name> -n prod --replicas=5

# Long-term: Adjust HPA settings
kubectl patch hpa <service-name>-hpa -n prod -p '{"spec":{"minReplicas":3}}'

# If at max replicas, increase max
kubectl patch hpa <service-name>-hpa -n prod -p '{"spec":{"maxReplicas":15}}'
```

---

### Scenario 2: Database Slow Queries

**Symptoms:** MongoDB profile shows slow queries > 100ms

```bash
# Check current indexes on collections
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.events.getIndexes();
  db.users.getIndexes();
  db.bookings.getIndexes();
"

# Create missing indexes for common queries
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.events.createIndex({category: 1, date: 1});
  db.events.createIndex({isActive: 1});
  db.bookings.createIndex({userId: 1, createdAt: -1});
"

# Kill long-running queries (if needed)
kubectl exec -it mongodb-0 -n prod -- mongosh --eval "
  db.killOp(<opid>)
"
```

---

### Scenario 3: CPU Throttling

**Symptoms:** kubectl top shows high CPU, latency spikes correlate with load

```bash
# Check current limits
kubectl get deployment <service-name> -n prod -o yaml | grep -A 5 "limits:"

# Increase CPU limits
kubectl set resources deployment/<service-name> -n prod \
  --limits=cpu=1000m \
  --requests=cpu=200m

# Verify new pods are not throttled
watch -n 5 'kubectl top pods -n prod -l app=<service-name>'
```

---

### Scenario 4: Memory Pressure

**Symptoms:** High memory usage, garbage collection pauses (for Node.js apps)

```bash
# Check memory usage
kubectl top pods -n prod -l app=<service-name>

# Increase memory limits
kubectl set resources deployment/<service-name> -n prod \
  --limits=memory=1Gi \
  --requests=memory=512Mi

# If memory leak suspected, restart pods
kubectl rollout restart deployment/<service-name> -n prod
```

---

### Scenario 5: Network Issues / Cross-AZ Traffic

**Symptoms:** Latency varies significantly between requests

```bash
# Check node topology
kubectl get nodes -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.'topology\.kubernetes\.io/zone'

# Ensure pods are spread evenly
kubectl get pods -n prod -o wide | grep <service-name>

# Add topology spread constraints if needed (update deployment)
# topologySpreadConstraints:
# - maxSkew: 1
#   topologyKey: topology.kubernetes.io/zone
#   whenUnsatisfiable: ScheduleAnyway
```

---

### Scenario 6: Ingress/Load Balancer Issues

**Symptoms:** High latency on initial connection, TLS handshake delays

```bash
# Check ALB health and latency
aws elbv2 describe-target-health --target-group-arn <tg-arn>

# Check ingress controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100

# Reduce ALB idle timeout for faster failover
kubectl annotate ingress eventsphere-ingress -n prod \
  alb.ingress.kubernetes.io/idle-timeout=60 --overwrite
```

---

## 📈 Monitoring & Verification

### Confirm Latency is Decreasing
```bash
# Continuous latency test
while true; do
  curl -w "time_total: %{time_total}s\n" -o /dev/null -s https://enpm818rgroup7.work.gd/api/events
  sleep 2
done

# Check Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Dashboard: EventSphere Dashboard
```

### Key Prometheus Queries
```promql
# p99 latency by service
histogram_quantile(0.99, 
  sum(rate(http_request_duration_seconds_bucket{namespace="prod"}[5m])) by (service, le)
)

# p50 latency (median)
histogram_quantile(0.50, 
  sum(rate(http_request_duration_seconds_bucket{namespace="prod"}[5m])) by (service, le)
)

# Latency by route (find slowest endpoints)
histogram_quantile(0.99, 
  sum(rate(http_request_duration_seconds_bucket{namespace="prod"}[5m])) by (route, le)
)

# Request rate (check if traffic spike caused latency)
sum(rate(http_requests_total{namespace="prod"}[5m])) by (service)
```

---

## 🚨 Escalation

If p99 latency remains > 2s after 15 minutes:

1. **Check for infrastructure issues** (AWS service health)
2. **Consider enabling debug logging** temporarily
3. **Page on-call engineer** with diagnostics
4. **Prepare for potential traffic shedding** if critical

---

## 📋 Post-Incident Checklist

- [ ] Latency returned to acceptable levels (< 500ms p99)
- [ ] Root cause identified
- [ ] Scaling adjustments made permanent (if needed)
- [ ] Database indexes optimized (if applicable)
- [ ] Resource limits updated in Helm/K8s manifests

---

**Last Updated:** 2024-12-07  
**Maintained By:** EventSphere DevOps Team
