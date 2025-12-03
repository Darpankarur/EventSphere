# EventSphere Deployment and Rollback Runbook

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Pre-Deployment Checklist](#pre-deployment-checklist)
3. [Deployment Methods](#deployment-methods)
4. [Manual Deployment](#manual-deployment)
5. [CI/CD Pipeline Deployment](#cicd-pipeline-deployment)
6. [Blue-Green Deployment](#blue-green-deployment)
7. [Canary Deployment](#canary-deployment)
8. [Rollback Procedures](#rollback-procedures)
9. [Post-Deployment Verification](#post-deployment-verification)
10. [Troubleshooting Failed Deployments](#troubleshooting-failed-deployments)
11. [Related Documentation](#related-documentation)

---

## Quick Reference

### Emergency Rollback Commands

```bash
# Quick rollback to previous deployment
kubectl rollout undo deployment/<service-name> -n prod

# Rollback to specific revision
kubectl rollout undo deployment/<service-name> -n prod --to-revision=<revision-number>

# Check rollout status
kubectl rollout status deployment/<service-name> -n prod

# Check rollout history
kubectl rollout history deployment/<service-name> -n prod
```

### Deployment Status Check

```bash
# Check all deployments
kubectl get deployments -n prod

# Watch pods during deployment
watch -n 2 'kubectl get pods -n prod'

# Check recent events
kubectl get events -n prod --sort-by='.lastTimestamp' | head -20
```

---

## Pre-Deployment Checklist

### 1. Code Review and Testing

- [ ] All code changes reviewed and approved
- [ ] Unit tests passing
- [ ] Integration tests passing
- [ ] Security scans passing (Trivy)
- [ ] No critical/high vulnerabilities

```bash
# Run tests locally
cd services/auth-service
npm test

# Run security scan
trivy image ${ECR_REGISTRY}/auth-service:latest
```

### 2. Backup Before Deployment

```bash
# Create backup before deployment
velero backup create pre-deployment-$(date +%Y%m%d-%H%M%S) \
  --include-namespaces prod \
  --labels backup-type=pre-deployment

# Wait for backup to complete
velero backup describe pre-deployment-TIMESTAMP --details

# Verify backup
velero backup get | grep pre-deployment
```

### 3. Verify Cluster Health

```bash
# Check node status
kubectl get nodes
# All nodes should be Ready

# Check resource availability
kubectl top nodes

# Check current pod status
kubectl get pods -n prod
# All pods should be Running

# Check HPA status
kubectl get hpa -n prod

# Check PVC status
kubectl get pvc -n prod
# All should be Bound
```

### 4. Notification

```bash
# Notify team via Slack/Email
echo "Deployment starting at $(date) by $(whoami)" | \
  aws sns publish --topic-arn <deployment-topic-arn> --message file://-

# Create deployment tracking issue
DEPLOY_ID="DEPLOY-$(date +%Y%m%d-%H%M%S)"
```

### 5. Maintenance Window (if required)

```bash
# For production deployments, schedule maintenance window
# Update status page
# Notify users if downtime expected
```

---

## Deployment Methods

### Method Comparison

| Method | Downtime | Rollback Speed | Complexity | Use Case |
|--------|----------|----------------|------------|----------|
| **Rolling Update** | None | Fast (30s) | Low | Standard releases |
| **Blue-Green** | Minimal (seconds) | Instant | Medium | Major releases |
| **Canary** | None | Fast | High | High-risk changes |
| **Manual** | Varies | Fast | Low | Emergency fixes |

---

## Manual Deployment

### Use Case
Emergency fixes, configuration updates, or when CI/CD is unavailable.

### Step 1: Build and Push Images

```bash
# Set variables
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-east-1
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
SERVICE_NAME="auth-service"
VERSION_TAG=$(git rev-parse --short HEAD)

# Login to ECR
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${ECR_REGISTRY}

# Build image
cd services/${SERVICE_NAME}
docker build -t ${ECR_REGISTRY}/${SERVICE_NAME}:${VERSION_TAG} .

# Scan image
trivy image ${ECR_REGISTRY}/${SERVICE_NAME}:${VERSION_TAG} --severity CRITICAL,HIGH --exit-code 1

# Push image
docker push ${ECR_REGISTRY}/${SERVICE_NAME}:${VERSION_TAG}

# Tag as latest (optional)
docker tag ${ECR_REGISTRY}/${SERVICE_NAME}:${VERSION_TAG} ${ECR_REGISTRY}/${SERVICE_NAME}:latest
docker push ${ECR_REGISTRY}/${SERVICE_NAME}:latest

# Sign image with cosign (if configured)
cosign sign --key cosign.key ${ECR_REGISTRY}/${SERVICE_NAME}:${VERSION_TAG}
```

### Step 2: Update Kubernetes Manifests

```bash
# Update deployment with new image
kubectl set image deployment/${SERVICE_NAME} -n prod \
  ${SERVICE_NAME}=${ECR_REGISTRY}/${SERVICE_NAME}:${VERSION_TAG} \
  --record

# Alternative: Apply updated manifest
kubectl apply -f k8s/base/${SERVICE_NAME}-deployment.yaml --record
```

### Step 3: Monitor Deployment

```bash
# Watch rollout status
kubectl rollout status deployment/${SERVICE_NAME} -n prod

# Watch pods
watch -n 2 'kubectl get pods -n prod -l app=${SERVICE_NAME}'

# Check deployment events
kubectl describe deployment ${SERVICE_NAME} -n prod | grep -A 10 Events

# Check pod logs
kubectl logs -n prod -l app=${SERVICE_NAME} --tail=50 -f
```

### Step 4: Verify Deployment

```bash
# Check deployment is updated
kubectl get deployment ${SERVICE_NAME} -n prod -o wide

# Test service health
kubectl run test-pod --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://${SERVICE_NAME}.prod.svc.cluster.local:4001/health

# Test via ingress
curl -f https://api.enpm818rgroup7.work.gd/api/auth/health
```

---

## CI/CD Pipeline Deployment

### GitHub Actions Automated Deployment

#### Trigger Deployment

```bash
# Merge to main branch triggers production deployment
git checkout main
git pull origin main
git merge develop
git push origin main

# Or manually trigger deployment
gh workflow run deploy.yml -f environment=prod
```

#### Monitor Pipeline

```bash
# Check workflow status
gh run list --workflow=deploy.yml --limit 5

# View logs
gh run view <run-id> --log

# Or view in GitHub UI
# https://github.com/your-org/EventSphere/actions
```

#### Pipeline Stages

1. **Checkout Code**: Pull latest code from repository
2. **Configure AWS**: Set up AWS credentials
3. **Update kubeconfig**: Connect to EKS cluster
4. **Replace Placeholders**: Update manifests with account ID, certificates
5. **Verify Signatures**: Check image signatures with cosign
6. **Update Images**: Update deployment with new image tags
7. **Apply Manifests**: Deploy to Kubernetes
8. **Wait for Ready**: Wait for all deployments to be available
9. **Verify**: Check all resources are healthy
10. **Auto-Rollback**: Rollback if deployment fails

#### Approval Gate for Production

For production deployments, approval is required:

1. Navigate to Actions tab in GitHub
2. Find pending deployment
3. Review changes
4. Approve or reject

---

## Blue-Green Deployment

### Use Case
Major releases where instant rollback is critical.

### Step 1: Prepare Green Environment

```bash
# Create green namespace
kubectl create namespace prod-green

# Copy secrets and configmaps
kubectl get configmaps -n prod -o yaml | \
  sed 's/namespace: prod/namespace: prod-green/' | \
  kubectl apply -f -

kubectl get secrets -n prod -o yaml | \
  sed 's/namespace: prod/namespace: prod-green/' | \
  kubectl apply -f -

# Deploy to green environment
kubectl apply -f k8s/base/ -n prod-green

# Update image to new version
kubectl set image deployment/auth-service -n prod-green \
  auth-service=${ECR_REGISTRY}/auth-service:new-version
```

### Step 2: Test Green Environment

```bash
# Port-forward to test
kubectl port-forward -n prod-green svc/frontend 8080:80

# Open browser to http://localhost:8080
# Perform smoke tests

# Or create temporary ingress for testing
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: eventsphere-green-test
  namespace: prod-green
  annotations:
    alb.ingress.kubernetes.io/scheme: internal
spec:
  ingressClassName: alb
  rules:
  - host: green.eventsphere.internal
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 80
EOF

# Test via internal endpoint
curl http://green.eventsphere.internal
```

### Step 3: Switch Traffic to Green

```bash
# Update ingress to point to green namespace
kubectl patch ingress eventsphere-ingress -n prod --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/rules/0/http/paths/0/backend/service/name",
    "value": "frontend"
  },
  {
    "op": "replace",
    "path": "/spec/rules/0/http/paths/0/backend/service/namespace",
    "value": "prod-green"
  }
]'

# Alternative: Update service selector
kubectl patch service frontend -n prod -p '{"spec":{"selector":{"app":"frontend","version":"green"}}}'

# Monitor traffic switch
watch -n 5 'kubectl get pods -n prod-green -o wide'
```

### Step 4: Monitor and Validate

```bash
# Monitor error rates
kubectl logs -n prod-green -l app=frontend --tail=100 -f | grep -i error

# Check metrics in Grafana
# Open Grafana dashboard and verify:
# - Request rate
# - Error rate
# - Latency

# If issues detected, rollback immediately (see rollback section)
```

### Step 5: Decommission Blue Environment

```bash
# After 24-48 hours of stable green environment
# Scale down blue environment
kubectl scale deployment --all -n prod --replicas=0

# After 1 week, delete blue environment
kubectl delete namespace prod
kubectl label namespace prod-green name=prod
```

---

## Canary Deployment

### Use Case
High-risk changes where gradual rollout is needed.

### Step 1: Deploy Canary Version

```bash
# Create canary deployment (10% traffic)
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-service-canary
  namespace: prod
  labels:
    app: auth-service
    version: canary
spec:
  replicas: 1  # 10% of production replicas
  selector:
    matchLabels:
      app: auth-service
      version: canary
  template:
    metadata:
      labels:
        app: auth-service
        version: canary
    spec:
      containers:
      - name: auth-service
        image: ${ECR_REGISTRY}/auth-service:canary
        # ... rest of container spec
EOF
```

### Step 2: Configure Traffic Splitting

```bash
# Update service to include both stable and canary
kubectl patch service auth-service -n prod -p '{
  "spec": {
    "selector": {
      "app": "auth-service"
    }
  }
}'

# Service will load balance across both stable and canary pods
# With 9 stable pods and 1 canary pod = ~10% canary traffic
```

### Step 3: Monitor Canary Metrics

```bash
# Monitor canary pod logs
kubectl logs -n prod -l app=auth-service,version=canary -f

# Compare error rates
# Stable pods
kubectl logs -n prod -l app=auth-service,version=stable | grep -c ERROR

# Canary pods
kubectl logs -n prod -l app=auth-service,version=canary | grep -c ERROR

# Monitor in Prometheus
# Query: rate(http_requests_total{version="canary",status=~"5.."}[5m])
```

### Step 4: Gradual Rollout

```bash
# If canary is healthy, increase to 25%
kubectl scale deployment auth-service-canary -n prod --replicas=3

# Monitor for 30 minutes

# Increase to 50%
kubectl scale deployment auth-service-canary -n prod --replicas=5

# Monitor for 30 minutes

# Increase to 100% (promote canary)
kubectl set image deployment/auth-service -n prod \
  auth-service=${ECR_REGISTRY}/auth-service:canary

# Delete canary deployment
kubectl delete deployment auth-service-canary -n prod
```

### Step 5: Rollback Canary (if issues detected)

```bash
# Delete canary deployment immediately
kubectl delete deployment auth-service-canary -n prod

# Verify all traffic to stable version
kubectl get pods -n prod -l app=auth-service
```

---

## Rollback Procedures

### When to Rollback

- Error rate > 5%
- P95 latency > 2x baseline
- Critical functionality broken
- Data corruption detected
- Security vulnerability introduced

### Automatic Rollback (CI/CD)

The CI/CD pipeline includes automatic rollback:

```yaml
# .github/workflows/deploy.yml includes:
- name: Rollback on failure
  if: failure()
  run: |
    kubectl rollout undo deployment/$service -n prod
```

### Manual Rollback - Quick Method

```bash
# Rollback to previous version (fastest)
kubectl rollout undo deployment/auth-service -n prod
kubectl rollout undo deployment/event-service -n prod
kubectl rollout undo deployment/booking-service -n prod
kubectl rollout undo deployment/frontend -n prod

# Monitor rollback
watch -n 2 'kubectl get pods -n prod'
```

### Manual Rollback - Specific Revision

```bash
# View deployment history
kubectl rollout history deployment/auth-service -n prod

# Output shows revisions:
# REVISION  CHANGE-CAUSE
# 1         Initial deployment
# 2         Update to v1.1.0
# 3         Update to v1.2.0

# Rollback to specific revision
kubectl rollout undo deployment/auth-service -n prod --to-revision=2

# Verify rollback
kubectl rollout status deployment/auth-service -n prod
```

### Manual Rollback - Specific Image

```bash
# Rollback to known good image
GOOD_IMAGE="${ECR_REGISTRY}/auth-service:v1.1.0"

kubectl set image deployment/auth-service -n prod \
  auth-service=${GOOD_IMAGE}

# Wait for rollout
kubectl rollout status deployment/auth-service -n prod
```

### Database Migration Rollback

```bash
# If deployment included database migration

# 1. Check if migration ran
kubectl logs -n prod -l app=auth-service | grep -i "migration"

# 2. Rollback application first
kubectl rollout undo deployment/auth-service -n prod

# 3. Rollback database migration
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere

# In MongoDB shell:
> db.migrations.find().sort({_id:-1}).limit(1)  // Check last migration
> db.migrations.deleteOne({_id: "migration-v1.2.0"})  // Remove migration record

# Run down migration if available
> // Execute down migration script

# 4. Verify data integrity
> db.users.countDocuments()
> db.events.countDocuments()
```

### Rollback Verification

```bash
# 1. Check deployment status
kubectl get deployments -n prod

# 2. Check pod status
kubectl get pods -n prod
# All should be Running

# 3. Check rollout history
kubectl rollout history deployment/auth-service -n prod

# 4. Test service functionality
curl -f https://api.enpm818rgroup7.work.gd/api/auth/health
curl -f https://api.enpm818rgroup7.work.gd/api/events

# 5. Check error rates
kubectl logs -n prod -l app=auth-service --tail=100 | grep -i error

# 6. Monitor metrics
# Check Grafana for:
# - Error rate back to normal
# - Latency back to normal
# - Request rate stable
```

### Document Rollback

```bash
# Create incident report
cat > rollback-$(date +%Y%m%d-%H%M%S).txt <<EOF
Rollback Incident Report

Date: $(date)
Triggered By: $(whoami)
Reason: [Brief description]

Timeline:
- $(date): Deployment started
- $(date): Issue detected
- $(date): Rollback initiated
- $(date): Rollback completed

Services Affected:
- auth-service: Rolled back from vX.Y.Z to vA.B.C
- [other services]

Root Cause:
[To be determined]

Action Items:
- [ ] Investigate root cause
- [ ] Fix issue
- [ ] Add tests to prevent recurrence
- [ ] Update deployment checklist
EOF

# Upload to S3
aws s3 cp rollback-*.txt s3://eventsphere-incident-reports/
```

---

## Post-Deployment Verification

### Comprehensive Health Check

```bash
# Run health check script
cat > health-check.sh <<'EOF'
#!/bin/bash

echo "=== EventSphere Health Check ==="
echo "Date: $(date)"
echo ""

# 1. Cluster health
echo "1. Cluster Health:"
kubectl get nodes | grep -v NAME | awk '{print "   - " $1 ": " $2}'

# 2. Pod status
echo ""
echo "2. Pod Status:"
TOTAL_PODS=$(kubectl get pods -n prod --no-headers | wc -l)
RUNNING_PODS=$(kubectl get pods -n prod --no-headers | grep Running | wc -l)
echo "   - Total: $TOTAL_PODS"
echo "   - Running: $RUNNING_PODS"

if [ "$TOTAL_PODS" != "$RUNNING_PODS" ]; then
  echo "   ⚠ Not all pods are running!"
  kubectl get pods -n prod | grep -v Running
fi

# 3. Service endpoints
echo ""
echo "3. Service Endpoints:"
for svc in auth-service event-service booking-service frontend; do
  ENDPOINTS=$(kubectl get endpoints $svc -n prod -o jsonpath='{.subsets[*].addresses[*].ip}' | wc -w)
  echo "   - $svc: $ENDPOINTS endpoints"
done

# 4. Ingress status
echo ""
echo "4. Ingress Status:"
ALB=$(kubectl get ingress eventsphere-ingress -n prod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "   - ALB: $ALB"

# 5. HPA status
echo ""
echo "5. HPA Status:"
kubectl get hpa -n prod --no-headers | awk '{print "   - " $1 ": " $3 "/" $4 " replicas"}'

# 6. Service health endpoints
echo ""
echo "6. Service Health:"
for svc in auth-service event-service booking-service; do
  PORT=$(kubectl get svc $svc -n prod -o jsonpath='{.spec.ports[0].port}')
  STATUS=$(kubectl run test-pod --image=curlimages/curl --rm -i --restart=Never -- \
    curl -s -o /dev/null -w "%{http_code}" http://$svc.prod.svc.cluster.local:$PORT/health)
  if [ "$STATUS" == "200" ]; then
    echo "   - $svc: ✓ Healthy"
  else
    echo "   - $svc: ✗ Unhealthy (HTTP $STATUS)"
  fi
done

# 7. External accessibility
echo ""
echo "7. External Access:"
FRONTEND_STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://enpm818rgroup7.work.gd)
API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://api.enpm818rgroup7.work.gd/api/events)

if [ "$FRONTEND_STATUS" == "200" ]; then
  echo "   - Frontend: ✓ Accessible"
else
  echo "   - Frontend: ✗ Not accessible (HTTP $FRONTEND_STATUS)"
fi

if [ "$API_STATUS" == "200" ]; then
  echo "   - API: ✓ Accessible"
else
  echo "   - API: ✗ Not accessible (HTTP $API_STATUS)"
fi

echo ""
echo "=== Health Check Complete ==="
EOF

chmod +x health-check.sh
./health-check.sh
```

### Performance Baseline Check

```bash
# Run performance test
echo "Testing response times..."

for i in {1..10}; do
  curl -w "@curl-format.txt" -o /dev/null -s https://enpm818rgroup7.work.gd/
  sleep 1
done

# curl-format.txt:
# time_total: %{time_total}s
```

### Database Integrity Check

```bash
# Check database connectivity and data
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  print('=== Database Health ===');
  print('Connection: OK');
  print('');
  print('Collections:');
  db.getCollectionNames().forEach(function(col) {
    print('  - ' + col + ': ' + db[col].countDocuments() + ' documents');
  });
  print('');
  print('Recent records:');
  print('  - Last user: ' + db.users.find().sort({createdAt: -1}).limit(1).toArray()[0]?.email);
  print('  - Last event: ' + db.events.find().sort({createdAt: -1}).limit(1).toArray()[0]?.title);
  print('  - Last booking: ' + db.bookings.find().sort({createdAt: -1}).limit(1).toArray()[0]?._id);
"
```

---

## Troubleshooting Failed Deployments

### Issue 1: ImagePullBackOff

```bash
# Symptom
kubectl get pods -n prod
# NAME                            READY   STATUS             RESTARTS   AGE
# auth-service-xxxxx              0/1     ImagePullBackOff   0          2m

# Diagnose
kubectl describe pod auth-service-xxxxx -n prod | grep -A 10 Events

# Common causes:
# 1. Image doesn't exist in ECR
aws ecr describe-images --repository-name auth-service --image-ids imageTag=v1.2.0

# 2. Image tag typo
kubectl get deployment auth-service -n prod -o yaml | grep image:

# 3. ECR permissions issue
# Check node IAM role has AmazonEC2ContainerRegistryReadOnly policy

# Fix
# Update with correct image
kubectl set image deployment/auth-service -n prod \
  auth-service=${ECR_REGISTRY}/auth-service:correct-tag
```

### Issue 2: CrashLoopBackOff

```bash
# Symptom
kubectl get pods -n prod
# NAME                            READY   STATUS              RESTARTS   AGE
# auth-service-xxxxx              0/1     CrashLoopBackOff   5          10m

# Diagnose
kubectl logs -n prod auth-service-xxxxx
kubectl logs -n prod auth-service-xxxxx --previous

# Common causes:
# 1. Application error on startup
# Check logs for error messages

# 2. Missing environment variables
kubectl describe pod auth-service-xxxxx -n prod | grep -A 20 Environment

# 3. Database connection failure
kubectl exec -it mongodb-0 -n prod -- mongosh --eval "db.adminCommand('ping')"

# 4. Resource limits too low
kubectl describe pod auth-service-xxxxx -n prod | grep -A 5 Limits

# Fix based on root cause
# Example: Update environment variable
kubectl set env deployment/auth-service -n prod MONGO_URI=<correct-uri>
```

### Issue 3: Deployment Stuck (Progressing)

```bash
# Symptom
kubectl get deployments -n prod
# NAME              READY   UP-TO-DATE   AVAILABLE   AGE
# auth-service      1/2     1            1           15m

kubectl rollout status deployment/auth-service -n prod
# Waiting for deployment "auth-service" rollout to finish: 1 out of 2 new replicas have been updated...

# Diagnose
kubectl describe deployment auth-service -n prod

# Common causes:
# 1. Insufficient resources
kubectl describe nodes | grep -A 5 "Allocated resources"

# 2. Pod security policy blocking
kubectl get events -n prod | grep -i "security\|policy"

# 3. Image pull taking too long
kubectl get pods -n prod -l app=auth-service -o wide

# Fix
# Scale up cluster if needed
kubectl get nodes

# Or reduce resource requests
kubectl edit deployment auth-service -n prod
# Adjust resources.requests values
```

### Issue 4: Service Not Accessible

```bash
# Symptom
curl https://api.enpm818rgroup7.work.gd/api/auth/health
# curl: (7) Failed to connect

# Diagnose
# 1. Check pods
kubectl get pods -n prod -l app=auth-service

# 2. Check service
kubectl get svc auth-service -n prod
kubectl get endpoints auth-service -n prod

# 3. Check ingress
kubectl get ingress -n prod
kubectl describe ingress eventsphere-ingress -n prod

# 4. Check ALB
aws elbv2 describe-load-balancers | grep -A 10 k8s-prod

# 5. Check target groups
aws elbv2 describe-target-health --target-group-arn <tg-arn>

# Fix
# If endpoints empty, check pod labels match service selector
kubectl get pods -n prod -l app=auth-service --show-labels
kubectl get svc auth-service -n prod -o yaml | grep -A 5 selector

# If ALB issues, recreate ingress
kubectl delete ingress eventsphere-ingress -n prod
kubectl apply -f k8s/ingress/ingress.yaml
```

---

## Related Documentation

- [Backup and Restore Runbook](BACKUP_RESTORE.md)
- [Disaster Recovery Runbook](DISASTER_RECOVERY.md)
- [Troubleshooting Runbook](TROUBLESHOOTING.md)
- [Deployment Guide](../../DEPLOYMENT.md)
- [CI/CD Workflows](../../.github/workflows/)

---

**Last Updated**: 2025-01-12  
**Version**: 1.0  
**Maintained By**: EventSphere DevOps Team

**Deployment Schedule**:
- Production: Tuesdays and Thursdays, 2:00 PM UTC
- Staging: Daily, automated
- Emergency Fixes: As needed (follow this runbook)




