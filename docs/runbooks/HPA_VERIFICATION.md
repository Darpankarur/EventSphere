# HPA Verification Guide

Based on your `kubectl describe hpa auth-service-hpa -n prod` output, your HPA is **working correctly** now. The earlier warnings were likely due to:
1. Metrics Server not being ready yet
2. Pods being unready during initial deployment

## Current Status ✅

From your output:
- **Metrics are working**: CPU 3% (3m) / 70%, Memory 25% (33412Ki) / 80%
- **ScalingActive**: True - HPA can calculate metrics
- **AbleToScale**: True - HPA can scale the deployment
- **Current replicas**: 2/2 (within min/max range)

## Quick Verification Commands

### 1. Verify Metrics Server
```bash
# Check Metrics Server is running
kubectl get deployment metrics-server -n kube-system

# Check Metrics Server pods (using correct label selector)
kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server

# Alternative: Find by name
kubectl get pods -n kube-system | grep metrics-server

# Test metrics API
kubectl top nodes
kubectl top pods -n prod
```

### 2. Check All HPAs
```bash
# List all HPAs
kubectl get hpa -n prod

# Get detailed status
kubectl describe hpa auth-service-hpa -n prod
kubectl describe hpa event-service-hpa -n prod
kubectl describe hpa booking-service-hpa -n prod
kubectl describe hpa frontend-hpa -n prod
```

### 3. Verify HPA Conditions
For each HPA, you should see:
- ✅ `ScalingActive: True` with reason `ValidMetricFound`
- ✅ `AbleToScale: True`
- ✅ `ScalingLimited: False` (unless at min/max replicas)

## Testing HPA Scaling

### Test Scale-Up

```bash
# Method 1: Generate load using a pod
kubectl run load-generator \
  --image=busybox \
  --restart=Never \
  -n prod \
  -- /bin/sh -c "while true; do wget -q -O- http://auth-service:4001/health; sleep 0.1; done"

# Watch HPA in real-time (in another terminal)
watch -n 2 'kubectl get hpa auth-service-hpa -n prod'

# Watch pods scaling up
watch -n 2 'kubectl get pods -n prod -l app=auth-service'

# Check HPA events
kubectl describe hpa auth-service-hpa -n prod | grep -A 20 "Events:"
```

**Expected behavior:**
- When CPU exceeds 70% or Memory exceeds 80%, HPA will scale up
- Pods should increase from 2 to more (up to max 10)
- Scale-up happens quickly (0s stabilization window)

### Test Scale-Down

```bash
# Stop the load generator
kubectl delete pod load-generator -n prod

# Wait 5+ minutes (scale-down has 300s stabilization window)
# Then check if pods scaled down
kubectl get hpa auth-service-hpa -n prod
kubectl get pods -n prod -l app=auth-service
```

**Expected behavior:**
- After 5 minutes of low load, HPA will scale down
- Scale-down is gradual (50% reduction per 60 seconds)
- Will not go below min replicas (2)

## Understanding HPA Behavior

From your configuration:

### Scale-Up Policy
- **Stabilization Window**: 0 seconds (immediate scaling)
- **Policies**:
  - Percent: 100% increase per 30 seconds
  - Pods: Add 2 pods per 30 seconds
- **Select Policy**: Max (uses the more aggressive policy)

### Scale-Down Policy
- **Stabilization Window**: 300 seconds (5 minutes)
- **Policy**: 50% reduction per 60 seconds
- **Select Policy**: Max

## Troubleshooting

### If you see "FailedGetResourceMetric" warnings:

1. **Check Metrics Server:**
   ```bash
   kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server
   kubectl logs -n kube-system -l app.kubernetes.io/name=metrics-server --tail=50
   ```

2. **Verify resource requests are defined:**
   ```bash
   kubectl get deployment auth-service -n prod -o yaml | grep -A 5 "requests:"
   ```
   HPA needs resource requests to calculate percentages.

3. **Check if pods are ready:**
   ```bash
   kubectl get pods -n prod -l app=auth-service
   ```
   Unready pods won't report metrics.

4. **Reinstall Metrics Server if needed:**
   ```bash
   kubectl delete deployment metrics-server -n kube-system
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   ```

### If HPA is not scaling:

1. **Check if at min/max:**
   ```bash
   kubectl get hpa auth-service-hpa -n prod
   ```
   If current = min, it won't scale down. If current = max, it won't scale up.

2. **Check metrics:**
   ```bash
   kubectl describe hpa auth-service-hpa -n prod
   ```
   Look at "Metrics:" section - are current values below/above targets?

3. **Check HPA conditions:**
   ```bash
   kubectl get hpa auth-service-hpa -n prod -o yaml | grep -A 10 "conditions:"
   ```

## Monitoring HPA

### Watch HPA status continuously:
```bash
watch -n 2 'kubectl get hpa -n prod'
```

### Check HPA events:
```bash
kubectl describe hpa auth-service-hpa -n prod | tail -20
```

### View HPA metrics history (if Prometheus is installed):
```bash
# Query HPA metrics
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1
```

## Expected HPA Metrics

For `auth-service-hpa`:
- **CPU Target**: 70% of request (request is 100m, so target is ~70m)
- **Memory Target**: 80% of request (request is 128Mi, so target is ~102Mi)
- **Min Replicas**: 2
- **Max Replicas**: 10

Your current metrics (3% CPU, 25% memory) are well below thresholds, so HPA correctly maintains 2 replicas.

## Integration with Cluster Autoscaler

HPA scales pods, Cluster Autoscaler scales nodes. They work together:

1. **HPA scales pods up** → More pods need resources
2. **If no nodes available** → Cluster Autoscaler adds nodes
3. **HPA scales pods down** → Nodes become underutilized
4. **After 10+ minutes** → Cluster Autoscaler removes nodes

To test both together:
```bash
# Create load that exceeds node capacity
kubectl create deployment load-test --image=containerstack/cpustress:latest \
  --replicas=20 \
  -n prod

# Watch both HPA and nodes
watch -n 5 'kubectl get hpa -n prod; echo ""; kubectl get nodes'
```

