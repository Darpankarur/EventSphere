# Error Rate Runbook

> **Alert:** High Error Rate  
> **Severity:** Critical  
> **Threshold:** Error rate > 1% over 5 minutes

---

## 📊 Quick Assessment

### 1. Check Current Error Rate
```bash
# Via Prometheus (port-forward first)
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090

# Query: Error rate per service (HTTP 5xx responses)
# sum(rate(http_requests_total{status=~"5.."}[5m])) by (service) / sum(rate(http_requests_total[5m])) by (service) * 100
```

### 2. Identify Affected Services
```bash
# Check which pods are returning errors
kubectl get pods -n prod
kubectl logs -n prod -l app=<service-name> --tail=100 | grep -i "error\|exception\|failed"
```

---

## 🔍 Diagnosis Steps

### Step 1: Check Service Health
```bash
# Quick health check for all services
for svc in auth-service event-service booking-service notification-service; do
  echo "=== $svc ===" 
  kubectl get pods -n prod -l app=$svc
  kubectl logs -n prod -l app=$svc --tail=20 | grep -i error
done
```

### Step 2: Check Recent Deployments
```bash
# Recent changes could cause error spikes
kubectl rollout history deployment -n prod
kubectl get events -n prod --sort-by='.lastTimestamp' | head -20
```

### Step 3: Check Dependencies
```bash
# MongoDB connectivity
kubectl exec -it mongodb-0 -n prod -- mongosh --eval "db.adminCommand('ping')"

# Check if any service is failing to connect to MongoDB
kubectl logs -n prod -l app=auth-service --tail=50 | grep -i "mongo\|database\|connection"
```

---

## 🛠️ Remediation Actions

### Scenario 1: Application Bug (Recent Deployment)

**Symptoms:** Error spike after deployment

```bash
# Check last deployment time
kubectl rollout history deployment/<service-name> -n prod

# Rollback to previous version
kubectl rollout undo deployment/<service-name> -n prod

# Verify rollback
kubectl rollout status deployment/<service-name> -n prod
kubectl get pods -n prod -l app=<service-name>
```

---

### Scenario 2: Database Connection Failures

**Symptoms:** Logs show "connection refused" or "timeout" to MongoDB

```bash
# Check MongoDB status
kubectl get pods -n prod -l app=mongodb
kubectl describe pod mongodb-0 -n prod

# Check MongoDB logs
kubectl logs -n prod mongodb-0 --tail=100

# Restart MongoDB if unresponsive (use with caution)
kubectl delete pod mongodb-0 -n prod
# StatefulSet will recreate it automatically

# Verify services can connect after restart
kubectl logs -n prod -l app=auth-service --tail=20 | grep -i mongo
```

---

### Scenario 3: Resource Exhaustion

**Symptoms:** OOMKilled, high CPU causing request failures

```bash
# Check pod resource usage
kubectl top pods -n prod

# Check for OOMKilled events
kubectl get events -n prod | grep OOMKilled

# Increase resource limits
kubectl set resources deployment/<service-name> -n prod \
  --limits=memory=512Mi,cpu=500m \
  --requests=memory=256Mi,cpu=100m

# Scale up to reduce per-pod load
kubectl scale deployment/<service-name> -n prod --replicas=5
```

---

### Scenario 4: External Dependency Failure

**Symptoms:** Errors related to AWS services (SNS, Secrets Manager)

```bash
# Check notification-service for SNS errors
kubectl logs -n prod -l app=notification-service --tail=50 | grep -i "sns\|aws"

# Verify IAM role configuration
kubectl get sa notification-service -n prod -o yaml | grep -i role

# Check AWS service health
aws health describe-events --region us-east-1
```

---

### Scenario 5: Rate Limiting or Throttling

**Symptoms:** 429 status codes in logs

```bash
# Check for rate limit errors
kubectl logs -n prod -l app=<service-name> --tail=100 | grep -i "429\|rate\|throttle"

# If external API throttling, implement backoff
# Temporary: reduce request rate by scaling down
kubectl scale deployment/<service-name> -n prod --replicas=2
```

---

## 📈 Monitoring & Verification

### Confirm Error Rate is Decreasing
```bash
# Watch logs for error patterns
kubectl logs -n prod -l app=<service-name> -f | grep -i error

# Check Grafana dashboard
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open: http://localhost:3000
# Dashboard: EventSphere Dashboard -> Check error panels
```

### Prometheus Queries for Error Analysis
```promql
# Error rate by service
sum(rate(http_requests_total{namespace="prod", status=~"5.."}[5m])) by (service)
  / sum(rate(http_requests_total{namespace="prod"}[5m])) by (service) * 100

# Error rate by route (identify problematic endpoints)
sum(rate(http_requests_total{namespace="prod", status=~"5.."}[5m])) by (route)

# Error distribution by status code
sum(rate(http_requests_total{namespace="prod", status=~"4..|5.."}[5m])) by (status)
```

---

## 🚨 Escalation

If error rate persists after 15 minutes of troubleshooting:

1. **Page on-call engineer** with findings
2. **Document timeline** of events and actions taken
3. **Consider feature toggle** to disable problematic functionality
4. **Prepare for incident review** with logs and metrics

---

## 📋 Post-Incident Checklist

- [ ] Error rate returned to < 1%
- [ ] Root cause identified and documented
- [ ] Rollback completed (if applicable)
- [ ] Alert resolved in Prometheus/Grafana
- [ ] Incident report created for major issues

---

**Last Updated:** 2024-12-07  
**Maintained By:** EventSphere DevOps Team
