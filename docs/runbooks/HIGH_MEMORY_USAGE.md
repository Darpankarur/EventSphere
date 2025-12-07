# High Memory Usage Per Pod Runbook

> **Alert:** HighMemoryUsage  
> **Severity:** Warning / Critical  
> **Threshold:** Memory usage > 90% of limit for 5 minutes

---

## 📊 Quick Assessment

### 1. Check Current Memory Usage
```bash
# All pods sorted by memory usage
kubectl top pods -n prod --sort-by=memory

# Specific service
kubectl top pods -n prod -l app=<service-name>

# Memory usage as percentage of limit
kubectl get pods -n prod -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources.limits.memory}{"\n"}{end}'
```

### 2. Check for OOMKill Risk
```bash
# Pods approaching memory limit
kubectl describe pod <pod-name> -n prod | grep -A 5 "Limits:"

# Previous OOMKills
kubectl get events -n prod | grep OOMKilled
```

---

## 🔍 Diagnosis Steps

### Step 1: Identify High-Memory Pods
```bash
# Get memory usage for all pods
kubectl top pods -n prod

# Compare to limits
for pod in $(kubectl get pods -n prod -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $pod ==="
  kubectl top pod $pod -n prod
  kubectl describe pod $pod -n prod | grep -A 2 "Limits:"
done
```

### Step 2: Check Memory Trend
```bash
# Prometheus query for memory over time
# container_memory_working_set_bytes{namespace="prod"} / container_spec_memory_limit_bytes{namespace="prod"}

# Watch memory in real-time
watch -n 5 'kubectl top pods -n prod --sort-by=memory | head -10'
```

### Step 3: Analyze Memory Pattern
```bash
# Is memory growing over time? (memory leak)
# Is memory high but stable? (need more resources)
# Is memory spiking periodically? (batch job or cache issue)

# Check pod age - older pods with high memory may have leak
kubectl get pods -n prod -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp,RESTARTS:.status.containerStatuses[0].restartCount
```

### Step 4: Check Application Logs
```bash
# Look for memory-related warnings
kubectl logs -n prod <pod-name> --tail=200 | grep -i "memory\|heap\|cache\|buffer"

# Node.js specific - check for heap issues
kubectl logs -n prod <pod-name> --tail=200 | grep -i "heap\|allocation"
```

---

## 🛠️ Remediation Actions

### Scenario 1: Immediate Relief - Increase Limits

**Symptoms:** Legitimate memory usage, limits too low

```bash
# Check current limits
kubectl get deployment <deployment-name> -n prod -o yaml | grep -A 5 "resources:"

# Increase memory limits
kubectl set resources deployment/<deployment-name> -n prod \
  --limits=memory=1Gi \
  --requests=memory=512Mi

# Verify new pods have more headroom
watch -n 5 'kubectl top pods -n prod -l app=<service-name>'
```

---

### Scenario 2: Memory Leak - Rolling Restart

**Symptoms:** Memory grows continuously over time, older pods use more memory

```bash
# Terminate all pods and restart fresh
kubectl rollout restart deployment/<deployment-name> -n prod

# Monitor that memory stays stable after restart
watch -n 30 'kubectl top pods -n prod -l app=<service-name>'

# If memory grows again quickly, root cause is in code
# Consider more frequent restarts as temporary mitigation:
# Add preStop hook or use CronJob to restart periodically
```

**Set Up Automatic Restart (Temporary Mitigation):**
```bash
# Add annotation to force rolling restart on schedule
# Use external tool like kube-restart or add preStop lifecycle hook

# Or scale to more replicas with same total memory
kubectl scale deployment/<deployment-name> -n prod --replicas=6
```

---

### Scenario 3: Horizontal Scaling

**Symptoms:** Total traffic requires more memory than a single pod can handle

```bash
# Scale up to distribute memory usage
kubectl scale deployment/<deployment-name> -n prod --replicas=5

# Adjust HPA min replicas
kubectl patch hpa <hpa-name> -n prod -p '{"spec":{"minReplicas":4}}'

# With more pods, each handles less traffic and uses less memory
```

---

### Scenario 4: Cache/Buffer Tuning

**Symptoms:** Large data structures or caches consuming memory

```bash
# Check for large in-memory caches in application
kubectl exec -it <pod-name> -n prod -- node -e "console.log(process.memoryUsage())"

# Environment variable to limit Node.js heap
kubectl patch deployment <deployment-name> -n prod --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "NODE_OPTIONS", "value": "--max-old-space-size=384"}}
]'
```

---

### Scenario 5: Database Connection Pool

**Symptoms:** Many idle connections consuming memory

```bash
# Check MongoDB connections
kubectl exec -it mongodb-0 -n prod -- mongosh --eval "db.currentOp(true).inprog.length"

# Reduce connection pool size in application config
# For MongoDB: set maxPoolSize in connection string
# mongodb://...?maxPoolSize=10
```

---

### Scenario 6: Optimize Resource Requests

**Symptoms:** Pods requesting too little memory, getting scheduled on overloaded nodes

```bash
# Update requests to match actual usage
kubectl set resources deployment/<deployment-name> -n prod \
  --requests=memory=400Mi \
  --limits=memory=600Mi

# This ensures better pod placement by scheduler
```

---

## 📈 Monitoring & Verification

### Confirm Memory is Under Control
```bash
# Memory should be < 80% of limit
kubectl top pods -n prod -l app=<service-name>

# Calculate percentage
kubectl get pods -n prod -l app=<service-name> -o jsonpath='{.items[0].spec.containers[0].resources.limits.memory}'
# Compare to kubectl top output

# Grafana dashboard
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Dashboard: EventSphere Dashboard -> Memory Usage by Pod
```

### Prometheus Queries
```promql
# Memory usage as percentage of limit
container_memory_working_set_bytes{namespace="prod", container!=""}
  / container_spec_memory_limit_bytes{namespace="prod", container!=""} * 100

# Pods using > 80% of memory limit
(container_memory_working_set_bytes{namespace="prod", container!=""}
  / container_spec_memory_limit_bytes{namespace="prod", container!=""}) > 0.8

# Memory usage trend (average over time)
avg_over_time(container_memory_working_set_bytes{namespace="prod", pod=~"<pod-name>.*"}[1h])

# Memory growth rate (indicates leak)
deriv(container_memory_working_set_bytes{namespace="prod", pod=~"<pod-name>.*"}[30m])
```

---

## 🚨 Escalation

If memory issues persist after 15 minutes:

1. **Emergency: Restart pods** to prevent OOMKill cascade
2. **Increase limits** beyond normal if needed temporarily
3. **Page on-call engineer** with memory usage data
4. **Create ticket** for application team to investigate leak

```bash
# Emergency restart
kubectl rollout restart deployment/<deployment-name> -n prod

# Emergency scale up with relaxed limits
kubectl scale deployment/<deployment-name> -n prod --replicas=8
kubectl set resources deployment/<deployment-name> -n prod --limits=memory=2Gi
```

---

## 🔧 Prevention & Best Practices

### Resource Limit Guidelines
| Service | Request | Limit | Notes |
|---------|---------|-------|-------|
| auth-service | 256Mi | 512Mi | Stateless, scales well |
| event-service | 256Mi | 512Mi | May cache event data |
| booking-service | 256Mi | 512Mi | Transaction handling |
| notification-service | 128Mi | 256Mi | Lightweight |

### Monitoring Setup
```yaml
# Add alert for memory approaching limit
# In monitoring/prometheus/alertrules.yaml
- alert: HighMemoryUsage
  expr: |
    (container_memory_working_set_bytes{namespace="prod", container!=""} 
    / container_spec_memory_limit_bytes{namespace="prod", container!=""}) > 0.9
  for: 5m
  labels:
    severity: warning
```

### Application Best Practices
1. **Use streaming** for large data instead of loading into memory
2. **Implement pagination** for list endpoints
3. **Clear caches** periodically or use LRU eviction
4. **Close database connections** when done
5. **Profile memory** regularly in development

---

## 📋 Post-Incident Checklist

- [ ] Memory usage below 80% of limits
- [ ] Root cause identified (leak/underprovisioned/traffic spike)
- [ ] Resource limits adjusted in deployment manifests
- [ ] HPA settings reviewed for memory-based scaling
- [ ] Application team notified if code fix needed
- [ ] Monitoring alert resolved
- [ ] Incident documented

---

**Last Updated:** 2024-12-07  
**Maintained By:** EventSphere DevOps Team
