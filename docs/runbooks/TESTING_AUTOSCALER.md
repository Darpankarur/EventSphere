# Testing Autoscaler

This document provides step-by-step instructions to test each acceptance criterion for the EventSphere EKS deployment.

## Prerequisites

Before testing, ensure:
- `kubectl` is configured to access your EKS cluster
- `aws` CLI is configured with appropriate credentials
- You have cluster admin access

```bash
# Verify cluster access
kubectl cluster-info
kubectl get nodes
```

---

## 1. Test: Nodes in Multiple Availability Zones

### Objective
Verify that nodes are distributed across multiple Availability Zones (AZs).

### Test Command
```bash
kubectl get nodes -o wide
```

### Expected Output
You should see nodes with different `ZONE` values (e.g., `us-east-1a`, `us-east-1b`, `us-east-1c`).

### Detailed Verification
```bash
# Get nodes with zone information
kubectl get nodes -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels."topology\.kubernetes\.io/zone",INSTANCE-TYPE:.metadata.labels."node\.kubernetes\.io/instance-type",STATUS:.status.conditions[-1].type

# Count nodes per AZ
kubectl get nodes -o json | jq -r '.items[] | .metadata.labels."topology.kubernetes.io/zone"' | sort | uniq -c

# Alternative: Using kubectl with JSONPath
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' | sort -k2
```

### Success Criteria
- ✅ At least 2 different availability zones are present
- ✅ Nodes are distributed across multiple AZs (not all in one AZ)

### Troubleshooting
If all nodes are in one AZ:
1. Check node group configuration in `infrastructure/eksctl-cluster.yaml`
2. Ensure `availabilityZones` is not restricted to a single AZ
3. Recreate node groups with explicit AZ distribution if needed

---

## 2. Test: Autoscaler Responds to Load Changes

### Objective
Verify that the Cluster Autoscaler responds to load changes and logs scale events.

### Step 1: Verify Autoscaler is Running
```bash
# Check autoscaler deployment
kubectl get deployment cluster-autoscaler -n kube-system

# Check autoscaler pods
kubectl get pods -n kube-system -l app=cluster-autoscaler

# View autoscaler logs
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50
```

### Step 2: Verify Metrics Server is Running
```bash
# Check Metrics Server deployment (required for HPA and Cluster Autoscaler)
kubectl get deployment metrics-server -n kube-system

# Check Metrics Server pods (using correct label selector)
kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server

# Alternative: Find Metrics Server pods by name
kubectl get pods -n kube-system | grep metrics-server

# Verify Metrics Server is working
kubectl top nodes
kubectl top pods -n prod

# If Metrics Server is missing, install it:
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

### Step 3: Check Current Node Count
```bash
# Get current node count
kubectl get nodes --no-headers | wc -l

# Get node group status
aws eks describe-nodegroup --cluster-name eventsphere-cluster --nodegroup-name eventsphere-mng-1 --region us-east-1 --query 'nodegroup.scalingConfig'
```

### Step 4: Create Load to Trigger Scale-Up
```bash
# Create a test deployment that will trigger scaling
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: load-test
  namespace: prod
spec:
  replicas: 20
  selector:
    matchLabels:
      app: load-test
  template:
    metadata:
      labels:
        app: load-test
    spec:
      containers:
      - name: stress
        image: containerstack/cpustress:latest
        resources:
          requests:
            cpu: "500m"
            memory: "256Mi"
          limits:
            cpu: "1000m"
            memory: "512Mi"
        args:
        - "-l"
        - "800"
        - "-t"
        - "4"
EOF

# Watch pods being created (they may be pending if nodes need to scale)
kubectl get pods -n prod -l app=load-test -w
```

### Step 5: Monitor Autoscaler Logs for Scale Events
```bash
# In a separate terminal, watch autoscaler logs
kubectl logs -n kube-system -l app=cluster-autoscaler -f | grep -E "scale|node|Scaling"
```

### Step 6: Verify Scale-Up Event
```bash
# Check if new nodes were added
kubectl get nodes -o wide

# Check autoscaler events
kubectl get events -n kube-system --sort-by='.lastTimestamp' | grep -i autoscaler

# Check node group scaling
aws eks describe-nodegroup --cluster-name eventsphere-cluster --nodegroup-name eventsphere-mng-1 --region us-east-1 --query 'nodegroup.scalingConfig.desiredSize'
```

### Step 7: Trigger Scale-Down
```bash
# Delete the load test deployment
kubectl delete deployment load-test -n prod

# Wait a few minutes, then check if nodes were removed
kubectl get nodes -o wide

# Check autoscaler logs for scale-down events
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=100 | grep -i "scale.*down\|removed\|drain"
```

### Success Criteria
- ✅ Autoscaler pod is running
- ✅ Autoscaler logs show scale-up events when load increases
- ✅ New nodes are added to the cluster
- ✅ Autoscaler logs show scale-down events when load decreases
- ✅ Nodes are removed after load decreases (may take 10+ minutes)

### Alternative: Test with HPA (Horizontal Pod Autoscaler)

HPA scales pods within the cluster, while Cluster Autoscaler scales nodes. Both work together.

#### Verify HPA is Working
```bash
# Check all HPAs
kubectl get hpa -n prod

# Describe HPA to see current metrics and events
kubectl describe hpa auth-service-hpa -n prod

# Check HPA status (should show current/target metrics)
kubectl get hpa auth-service-hpa -n prod -o yaml | grep -A 10 "status:"
```

**Expected Output:**
- `ScalingActive: True` - HPA is able to calculate metrics
- `AbleToScale: True` - HPA can scale the deployment
- Current metrics showing (e.g., `3% (3m) / 70%` for CPU)

#### Test HPA Scale-Up
```bash
# Generate load on auth-service to trigger HPA scaling
kubectl run load-generator --image=busybox --restart=Never -n prod -- /bin/sh -c "while true; do wget -q -O- http://auth-service:4001/health; sleep 0.1; done"

# In another terminal, watch HPA
watch -n 2 'kubectl get hpa auth-service-hpa -n prod'

# Watch pod count increase
watch -n 2 'kubectl get pods -n prod -l app=auth-service'

# Check HPA events
kubectl describe hpa auth-service-hpa -n prod | grep -A 10 "Events:"
```

#### Test HPA Scale-Down
```bash
# Stop the load generator
kubectl delete pod load-generator -n prod

# Wait a few minutes, then check if pods scaled down
kubectl get hpa auth-service-hpa -n prod
kubectl get pods -n prod -l app=auth-service

# Note: Scale-down has a 300-second stabilization window (configured in HPA)
```

#### Troubleshooting HPA Issues

If you see warnings like:
- `failed to get metrics for resource cpu: no metrics returned from resource metrics API`
- `did not receive metrics for targeted pods (pods might be unready)`

**Solutions:**
```bash
# 1. Verify Metrics Server is running
kubectl get deployment metrics-server -n kube-system
kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server

# 2. Check if pods have resource requests defined (required for HPA)
kubectl get deployment auth-service -n prod -o yaml | grep -A 5 "requests:"

# 3. Verify pods are ready
kubectl get pods -n prod -l app=auth-service

# 4. Check Metrics Server logs
kubectl logs -n kube-system -l app.kubernetes.io/name=metrics-server --tail=50

# 5. Test metrics API directly
kubectl top pods -n prod
kubectl top nodes
```

---

## 3. Test: Workload Uses IRSA for AWS Access

### Objective
Verify that at least one workload uses IRSA (IAM Roles for Service Accounts) for AWS access.

### Step 1: Identify Workloads Using IRSA
```bash
# Check service accounts with IRSA annotations
kubectl get serviceaccounts -A -o json | jq -r '.items[] | select(.metadata.annotations."eks.amazonaws.com/role-arn") | "\(.metadata.namespace)/\(.metadata.name): \(.metadata.annotations."eks.amazonaws.com/role-arn")"'

# Alternative: Using kubectl
kubectl get serviceaccounts -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,ROLE-ARN:.metadata.annotations."eks\.amazonaws\.com/role-arn" | grep -v "<none>"
```

### Step 2: Verify External Secrets Operator Uses IRSA
The External Secrets Operator is configured to use IRSA. Verify:

```bash
# Check External Secrets service account
kubectl get serviceaccount external-secrets -n external-secrets-system -o yaml

# Verify the annotation exists
kubectl get serviceaccount external-secrets -n external-secrets-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

# Check if pods are using the service account
kubectl get pods -n external-secrets-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\n"}{end}'
```

### Step 3: Test AWS Access from Pod
```bash
# Get a pod using IRSA (External Secrets Operator)
kubectl get pods -n external-secrets-system -l app.kubernetes.io/name=external-secrets

# Execute a command in the pod to test AWS access
POD_NAME=$(kubectl get pods -n external-secrets-system -l app.kubernetes.io/name=external-secrets -o jsonpath='{.items[0].metadata.name}')

# Test AWS credentials (this should work if IRSA is configured)
kubectl exec -n external-secrets-system $POD_NAME -- aws sts get-caller-identity

# Test access to Secrets Manager (the actual permission)
kubectl exec -n external-secrets-system $POD_NAME -- aws secretsmanager list-secrets --region us-east-1 --max-items 5
```

### Step 4: Verify IRSA Token Mount
```bash
# Check if the AWS token is mounted in the pod
kubectl exec -n external-secrets-system $POD_NAME -- ls -la /var/run/secrets/eks.amazonaws.com/serviceaccount/

# Check the token file exists
kubectl exec -n external-secrets-system $POD_NAME -- cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

### Step 5: Verify External Secret is Working
```bash
# Check if External Secrets are syncing
kubectl get externalsecrets -n prod

# Check External Secret status
kubectl describe externalsecret mongodb-secret -n prod

# Verify the secret was created
kubectl get secret mongodb-secret -n prod
```

### Success Criteria
- ✅ At least one service account has `eks.amazonaws.com/role-arn` annotation
- ✅ Pods using that service account can assume the IAM role
- ✅ `aws sts get-caller-identity` returns the expected IAM role ARN
- ✅ Pods can access AWS services (e.g., Secrets Manager) using IRSA
- ✅ External Secrets Operator successfully syncs secrets from AWS Secrets Manager

### Additional IRSA Workloads to Check
```bash
# Check Fluent Bit (if deployed)
kubectl get serviceaccount fluent-bit -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

# Check AWS Load Balancer Controller
kubectl get serviceaccount aws-load-balancer-controller -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

# Check Cluster Autoscaler
kubectl get serviceaccount cluster-autoscaler -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
```

---

## 4. Test: ALB or NGINX Ingress Controller Routes Public Traffic

### Objective
Verify that the ALB (AWS Load Balancer Controller) routes public traffic correctly.

### Step 1: Verify Ingress Controller is Running
```bash
# Check AWS Load Balancer Controller deployment
kubectl get deployment aws-load-balancer-controller -n kube-system

# Check controller pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

### Step 2: Verify Ingress Resource
```bash
# Check ingress resource
kubectl get ingress -n prod

# Describe ingress to see ALB details
kubectl describe ingress eventsphere-ingress -n prod

# Get ingress details in YAML
kubectl get ingress eventsphere-ingress -n prod -o yaml
```

### Step 3: Get ALB DNS Name
```bash
# Get the ALB address from ingress status
kubectl get ingress eventsphere-ingress -n prod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Or describe to see full status
kubectl describe ingress eventsphere-ingress -n prod | grep -A 5 "Address:"
```

### Step 4: Verify ALB in AWS Console
```bash
# Get ALB ARN from ingress annotations
ALB_ARN=$(kubectl get ingress eventsphere-ingress -n prod -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/load-balancer-id}')

# List ALBs
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[?contains(LoadBalancerName, `k8s-prod`)].{Name:LoadBalancerName,DNS:DNSName,State:State.Code}' --output table

# Get specific ALB details
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[?contains(LoadBalancerName, `k8s-prod`)].LoadBalancerArn' --output text | head -1 | xargs -I {} aws elbv2 describe-load-balancers --load-balancer-arns {} --region us-east-1
```

### Step 5: Test HTTP Routing
```bash
# Get ALB DNS name
ALB_DNS=$(kubectl get ingress eventsphere-ingress -n prod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test frontend route (should return HTML or redirect)
curl -v -H "Host: www.enpm818rgroup7.work.gd" http://$ALB_DNS/

# Test API health endpoint
curl -v -H "Host: api.enpm818rgroup7.work.gd" http://$ALB_DNS/health

# Test auth service endpoint
curl -v -H "Host: api.enpm818rgroup7.work.gd" http://$ALB_DNS/api/auth/health

# Test events service endpoint
curl -v -H "Host: api.enpm818rgroup7.work.gd" http://$ALB_DNS/api/events/health
```

### Step 6: Test HTTPS Routing (if certificate is configured)
```bash
# Test HTTPS endpoint
curl -v -k -H "Host: www.enpm818rgroup7.work.gd" https://$ALB_DNS/

# Test with proper hostname (if DNS is configured)
curl -v https://www.enpm818rgroup7.work.gd/
curl -v https://api.enpm818rgroup7.work.gd/health
```

### Step 7: Verify Target Health
```bash
# Get target group ARNs
aws elbv2 describe-target-groups --region us-east-1 --query 'TargetGroups[?contains(TargetGroupName, `k8s-prod`)].{Name:TargetGroupName,Health:HealthCheckPath,Port:Port}' --output table

# Get target health for a specific target group
TG_ARN=$(aws elbv2 describe-target-groups --region us-east-1 --query 'TargetGroups[?contains(TargetGroupName, `k8s-prod-eventsphere`)].TargetGroupArn' --output text | head -1)
aws elbv2 describe-target-health --target-group-arn $TG_ARN --region us-east-1
```

### Step 8: Verify Backend Services
```bash
# Check that backend services are running
kubectl get svc -n prod

# Check service endpoints
kubectl get endpoints -n prod

# Verify pods are ready
kubectl get pods -n prod
```

### Step 9: Test Path-Based Routing
```bash
# Test different paths route to correct services
ALB_DNS=$(kubectl get ingress eventsphere-ingress -n prod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Frontend
curl -I -H "Host: www.enpm818rgroup7.work.gd" http://$ALB_DNS/

# Auth service
curl -I -H "Host: api.enpm818rgroup7.work.gd" http://$ALB_DNS/api/auth/health

# Events service
curl -I -H "Host: api.enpm818rgroup7.work.gd" http://$ALB_DNS/api/events/health

# Bookings service
curl -I -H "Host: api.enpm818rgroup7.work.gd" http://$ALB_DNS/api/bookings/health
```

### Success Criteria
- ✅ AWS Load Balancer Controller is running
- ✅ Ingress resource is created and has an ALB address
- ✅ ALB is accessible via public DNS
- ✅ HTTP requests to the ALB return expected responses
- ✅ Path-based routing works correctly (different paths route to different services)
- ✅ Host-based routing works correctly (different hosts route to different services)
- ✅ Target groups show healthy targets
- ✅ HTTPS works if certificate is configured

### Troubleshooting
If ingress is not getting an address:
```bash
# Check controller logs for errors
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100

# Check ingress events
kubectl describe ingress eventsphere-ingress -n prod

# Verify service account has correct permissions
kubectl get serviceaccount aws-load-balancer-controller -n kube-system -o yaml
```

---

## Quick Test Script

Save this as `test-acceptance-criteria.sh`:

```bash
#!/bin/bash

echo "=== Testing Acceptance Criteria ==="
echo ""

echo "1. Testing Nodes in Multiple AZs..."
kubectl get nodes -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels."topology\.kubernetes\.io/zone" --no-headers | sort -k2
AZ_COUNT=$(kubectl get nodes -o json | jq -r '.items[] | .metadata.labels."topology.kubernetes.io/zone"' | sort -u | wc -l)
if [ "$AZ_COUNT" -ge 2 ]; then
    echo "✅ PASS: Nodes in $AZ_COUNT AZs"
else
    echo "❌ FAIL: Only $AZ_COUNT AZ(s) found"
fi
echo ""

echo "2. Testing Autoscaler..."
if kubectl get deployment cluster-autoscaler -n kube-system &>/dev/null; then
    echo "✅ PASS: Autoscaler deployment exists"
    kubectl logs -n kube-system -l app=cluster-autoscaler --tail=5 | grep -i scale || echo "⚠️  No recent scale events in logs"
else
    echo "❌ FAIL: Autoscaler not found"
fi
echo ""

echo "3. Testing IRSA..."
IRSA_COUNT=$(kubectl get serviceaccounts -A -o json | jq -r '.items[] | select(.metadata.annotations."eks.amazonaws.com/role-arn") | .metadata.name' | wc -l)
if [ "$IRSA_COUNT" -ge 1 ]; then
    echo "✅ PASS: $IRSA_COUNT service account(s) using IRSA"
    kubectl get serviceaccounts -A -o json | jq -r '.items[] | select(.metadata.annotations."eks.amazonaws.com/role-arn") | "  - \(.metadata.namespace)/\(.metadata.name)"'
else
    echo "❌ FAIL: No IRSA service accounts found"
fi
echo ""

echo "4. Testing ALB Ingress..."
if kubectl get ingress eventsphere-ingress -n prod &>/dev/null; then
    ALB_DNS=$(kubectl get ingress eventsphere-ingress -n prod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    if [ -n "$ALB_DNS" ]; then
        echo "✅ PASS: Ingress has ALB address: $ALB_DNS"
        if curl -s -o /dev/null -w "%{http_code}" -H "Host: api.enpm818rgroup7.work.gd" http://$ALB_DNS/health | grep -q "200\|301\|302"; then
            echo "✅ PASS: ALB is routing traffic"
        else
            echo "⚠️  WARN: ALB exists but may not be routing correctly"
        fi
    else
        echo "❌ FAIL: Ingress has no ALB address"
    fi
else
    echo "❌ FAIL: Ingress not found"
fi
echo ""

echo "=== Test Complete ==="
```

Make it executable and run:
```bash
chmod +x test-acceptance-criteria.sh
./test-acceptance-criteria.sh
```

