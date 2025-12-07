# Pod Restart Spike Runbook

> **Alert:** PodCrashLooping / High Pod Restart Count  
> **Severity:** Critical  
> **Threshold:** Pod restart rate > 0 over 15 minutes for 5 minutes

---

## 📊 Quick Assessment

### 1. Identify Restarting Pods
```bash
# List all pods with restart counts
kubectl get pods -n prod -o wide

# Specifically find pods with high restarts
kubectl get pods -n prod -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | sort -t$'\t' -k2 -n -r

# Check restart count in last hour (via Prometheus)
# Query: increase(kube_pod_container_status_restarts_total{namespace="prod"}[1h])
```

### 2. Check Recent Events
```bash
# Get events sorted by time
kubectl get events -n prod --sort-by='.lastTimestamp' | grep -i "restart\|kill\|back-off\|failed" | head -20
```

---

## 🔍 Diagnosis Steps

### Step 1: Check Pod Status and Last State
```bash
# Get detailed pod information
kubectl describe pod <pod-name> -n prod | grep -A 10 "Last State:"

# Check current and previous container state
kubectl get pod <pod-name> -n prod -o yaml | grep -A 20 "containerStatuses:"
```

### Step 2: Check Logs
```bash
# Current logs
kubectl logs -n prod <pod-name>

# Previous container logs (before restart)
kubectl logs -n prod <pod-name> --previous

# Look for crash patterns
kubectl logs -n prod <pod-name> --previous | grep -i "error\|exception\|fatal\|panic\|killed"
```

### Step 3: Check Resource Usage
```bash
# Check if pods were OOMKilled
kubectl describe pod <pod-name> -n prod | grep -i "OOMKilled\|reason:"

# Check current resource usage
kubectl top pods -n prod

# Check resource limits vs usage
kubectl describe pod <pod-name> -n prod | grep -A 2 "Limits:" | grep memory
```

### Step 4: Check Liveness/Readiness Probes
```bash
# Get probe configuration
kubectl get deployment <deployment-name> -n prod -o yaml | grep -A 15 "livenessProbe:"

# Check for probe failures in events
kubectl get events -n prod --field-selector reason=Unhealthy
```

---

## 🛠️ Remediation Actions

### Scenario 1: OOMKilled (Out of Memory)

**Symptoms:** `Last State: Terminated`, `Reason: OOMKilled`

```bash
# Confirm OOMKilled
kubectl describe pod <pod-name> -n prod | grep -i "OOMKilled"

# Check current memory limit
kubectl get deployment <deployment-name> -n prod -o yaml | grep -A 3 "limits:"

# Increase memory limit
kubectl set resources deployment/<deployment-name> -n prod \
  --limits=memory=512Mi \
  --requests=memory=256Mi

# Monitor new pods
watch -n 5 'kubectl top pods -n prod -l app=<service-name>'
```

**For Memory Leaks:**
```bash
# If memory grows continuously, there may be a leak
# Temporary: Enable automatic restart with lower threshold

# Scale up to reduce memory per pod
kubectl scale deployment/<deployment-name> -n prod --replicas=4

# Long-term: Review application code for memory leaks
# Common causes in Node.js:
# - Event listeners not removed
# - Large arrays/objects accumulating
# - Unclosed database connections
```

---

### Scenario 2: Application Crash (Error/Exception)

**Symptoms:** Logs show unhandled exception or error

```bash
# Get error from previous logs
kubectl logs -n prod <pod-name> --previous | tail -100

# Common issues to look for:
# - "Cannot find module" - missing dependency
# - "Connection refused" - database/service unreachable
# - "SyntaxError" - code bug
# - "ECONNREFUSED" - network issue

# If recent deployment caused crash
kubectl rollout undo deployment/<deployment-name> -n prod
kubectl rollout status deployment/<deployment-name> -n prod

# Verify rollback fixed issue
kubectl get pods -n prod -l app=<service-name> -w
```

---

### Scenario 3: Failed Liveness Probe

**Symptoms:** Events show "Liveness probe failed"

```bash
# Check liveness probe config
kubectl get deployment <deployment-name> -n prod -o yaml | grep -A 15 "livenessProbe:"

# Test health endpoint manually
kubectl exec -it <pod-name> -n prod -- curl -s http://localhost:<port>/health

# If endpoint is slow, adjust probe timeouts
kubectl patch deployment <deployment-name> -n prod --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds", "value": 60},
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/periodSeconds", "value": 30},
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/timeoutSeconds", "value": 10},
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/failureThreshold", "value": 5}
]'

# Temporarily disable liveness probe (emergency only)
kubectl patch deployment <deployment-name> -n prod -p '{"spec":{"template":{"spec":{"containers":[{"name":"<container-name>","livenessProbe":null}]}}}}'
```

---

### Scenario 4: Database Connection Failure

**Symptoms:** Logs show MongoDB connection errors

```bash
# Check MongoDB status
kubectl get pods -n prod -l app=mongodb
kubectl logs -n prod mongodb-0 --tail=50

# Test MongoDB connectivity
kubectl exec -it mongodb-0 -n prod -- mongosh --eval "db.adminCommand('ping')"

# Check secret has correct connection string
kubectl get secret mongodb-secret -n prod -o jsonpath='{.data.connection-string}' | base64 -d

# If MongoDB is down, restart it
kubectl delete pod mongodb-0 -n prod
# Wait for StatefulSet to recreate

# Restart application pods after database is up
kubectl rollout restart deployment/<deployment-name> -n prod
```

---

### Scenario 5: Image Pull Failure

**Symptoms:** Status shows `ImagePullBackOff` or `ErrImagePull`

```bash
# Check events for image pull errors
kubectl describe pod <pod-name> -n prod | grep -A 5 "Events:"

# Verify image exists in ECR
aws ecr describe-images --repository-name <service-name>

# Check if using correct image tag
kubectl get deployment <deployment-name> -n prod -o jsonpath='{.spec.template.spec.containers[0].image}'

# Update to correct image
kubectl set image deployment/<deployment-name> -n prod <container-name>=<correct-image>
```

---

### Scenario 6: Resource Starvation (CPU Throttling)

**Symptoms:** High CPU, slow response causing probe failures

```bash
# Check CPU usage
kubectl top pods -n prod -l app=<service-name>

# Increase CPU limits
kubectl set resources deployment/<deployment-name> -n prod \
  --limits=cpu=1000m \
  --requests=cpu=200m

# Scale horizontally to distribute load
kubectl scale deployment/<deployment-name> -n prod --replicas=5
```

---

## 📈 Monitoring & Verification

### Confirm Restarts Have Stopped
```bash
# Watch pod status
kubectl get pods -n prod -l app=<service-name> -w

# Monitor restart count (should stay stable)
watch -n 10 'kubectl get pods -n prod -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount'

# Check Grafana dashboard
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open Dashboard -> "Restarts (1h)" panel
```

### Prometheus Queries
```promql
# Restart count by pod in last hour
increase(kube_pod_container_status_restarts_total{namespace="prod"}[1h])

# Pods with recent restarts
kube_pod_container_status_restarts_total{namespace="prod"} > 0

# OOMKill events
kube_pod_container_status_terminated_reason{reason="OOMKilled", namespace="prod"}
```

---

## 🚨 Escalation

If pods continue restarting after 15 minutes:

1. **Collect logs** from multiple restart cycles
2. **Check cluster-wide issues** (node problems, resource exhaustion)
3. **Page on-call engineer** with timeline and logs
4. **Consider disabling deployment** if causing cascade failures

```bash
# Emergency: Scale to zero to stop crash loop
kubectl scale deployment/<deployment-name> -n prod --replicas=0
```

---

## 📋 Post-Incident Checklist

- [ ] Pod restarts stopped
- [ ] Root cause identified (OOM/bug/probe/dependency)
- [ ] Resource limits adjusted if needed
- [ ] Probe configuration optimized if needed
- [ ] Rollback completed (if deployment issue)
- [ ] Monitoring alert resolved
- [ ] Incident documented

---

**Last Updated:** 2024-12-07  
**Maintained By:** EventSphere DevOps Team
