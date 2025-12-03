# EventSphere Troubleshooting Runbook

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Pod Issues](#pod-issues)
3. [Networking Issues](#networking-issues)
4. [Storage Issues](#storage-issues)
5. [Authentication and Authorization](#authentication-and-authorization)
6. [Performance Issues](#performance-issues)
7. [Monitoring and Logging](#monitoring-and-logging)
8. [Diagnostic Commands Reference](#diagnostic-commands-reference)
9. [Related Documentation](#related-documentation)

---

## Quick Reference

### Essential Commands

```bash
# Quick cluster overview
kubectl get nodes
kubectl get pods -A
kubectl get events -A --sort-by='.lastTimestamp' | head -20

# Check specific service
kubectl get pods -n prod -l app=auth-service
kubectl logs -n prod -l app=auth-service --tail=50

# Resource usage
kubectl top nodes
kubectl top pods -n prod

# Describe for detailed information
kubectl describe pod <pod-name> -n prod
kubectl describe node <node-name>
```

### Common Issues Quick Fix

| Issue | Quick Fix Command |
|-------|------------------|
| Pod not starting | `kubectl delete pod <pod-name> -n prod` |
| Service unavailable | `kubectl rollout restart deployment/<name> -n prod` |
| Image pull error | Check ECR: `aws ecr describe-images --repository-name <name>` |
| High memory | `kubectl top pods -n prod --sort-by=memory` |
| Network issue | `kubectl get networkpolicies -n prod` |

---

## Pod Issues

### Issue 1: Pods Not Starting (ImagePullBackOff)

**Symptoms:**
```bash
kubectl get pods -n prod
# NAME                            READY   STATUS             RESTARTS   AGE
# auth-service-xxxxx              0/1     ImagePullBackOff   0          2m
```

**Diagnosis:**
```bash
# Get detailed pod information
kubectl describe pod auth-service-xxxxx -n prod

# Check Events section for error messages
kubectl get events -n prod | grep auth-service-xxxxx

# Common error: "Failed to pull image"
```

**Root Causes & Solutions:**

**1. Image doesn't exist:**
```bash
# Check if image exists in ECR
aws ecr describe-images \
  --repository-name auth-service \
  --image-ids imageTag=v1.2.0

# If not found, build and push the image
cd services/auth-service
docker build -t ${ECR_REGISTRY}/auth-service:v1.2.0 .
docker push ${ECR_REGISTRY}/auth-service:v1.2.0
```

**2. Wrong image tag:**
```bash
# Check deployment image reference
kubectl get deployment auth-service -n prod -o yaml | grep image:

# Update with correct tag
kubectl set image deployment/auth-service -n prod \
  auth-service=${ECR_REGISTRY}/auth-service:correct-tag
```

**3. ECR authentication issue:**
```bash
# Verify node IAM role has ECR permissions
aws iam get-role --role-name <node-role-name>

# Attach ECR read policy if missing
aws iam attach-role-policy \
  --role-name <node-role-name> \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
```

**4. Private ECR in different region:**
```bash
# Verify ECR region matches cluster region
aws ecr describe-repositories --region us-east-1
```

---

### Issue 2: Pods Crashing (CrashLoopBackOff)

**Symptoms:**
```bash
kubectl get pods -n prod
# NAME                            READY   STATUS              RESTARTS   AGE
# auth-service-xxxxx              0/1     CrashLoopBackOff    5          10m
```

**Diagnosis:**
```bash
# Check current logs
kubectl logs -n prod auth-service-xxxxx

# Check previous container logs
kubectl logs -n prod auth-service-xxxxx --previous

# Check pod events
kubectl describe pod auth-service-xxxxx -n prod | grep -A 20 Events
```

**Root Causes & Solutions:**

**1. Application error:**
```bash
# Look for stack traces in logs
kubectl logs -n prod auth-service-xxxxx | grep -i "error\|exception\|fatal"

# Common issues:
# - Missing environment variables
# - Syntax errors in code
# - Dependency issues

# Verify environment variables
kubectl describe pod auth-service-xxxxx -n prod | grep -A 30 "Environment:"

# Check secrets/configmaps
kubectl get secret mongodb-secret -n prod
kubectl get configmap auth-service-config -n prod
```

**2. MongoDB connection failure:**
```bash
# Test MongoDB connectivity
kubectl exec -it mongodb-0 -n prod -- mongosh --eval "db.adminCommand('ping')"

# Check MongoDB pod status
kubectl get pod mongodb-0 -n prod

# Check MongoDB service
kubectl get svc mongodb -n prod
kubectl get endpoints mongodb -n prod

# Check connection string in logs
kubectl logs -n prod auth-service-xxxxx | grep -i "mongo\|database\|connection"

# Verify secret has correct connection string
kubectl get secret mongodb-secret -n prod -o jsonpath='{.data.connection-string}' | base64 -d
```

**3. Resource limits too restrictive:**
```bash
# Check if OOMKilled
kubectl describe pod auth-service-xxxxx -n prod | grep -i "OOMKilled"

# Check resource usage vs limits
kubectl top pod auth-service-xxxxx -n prod

# Get resource limits
kubectl describe pod auth-service-xxxxx -n prod | grep -A 5 "Limits:"

# If OOMKilled, increase memory limits
kubectl edit deployment auth-service -n prod
# Update resources.limits.memory
```

**4. Liveness probe failing:**
```bash
# Check liveness probe configuration
kubectl get deployment auth-service -n prod -o yaml | grep -A 10 livenessProbe

# Test health endpoint manually
kubectl exec -it auth-service-xxxxx -n prod -- wget -O- http://localhost:4001/health

# If health endpoint is broken, temporarily disable probe
kubectl patch deployment auth-service -n prod -p '{"spec":{"template":{"spec":{"containers":[{"name":"auth-service","livenessProbe":null}]}}}}'
```

---

### Issue 3: Pods Running but Not Ready

**Symptoms:**
```bash
kubectl get pods -n prod
# NAME                            READY   STATUS    RESTARTS   AGE
# auth-service-xxxxx              0/1     Running   0          5m
```

**Diagnosis:**
```bash
# Check readiness probe
kubectl describe pod auth-service-xxxxx -n prod | grep -A 10 "Readiness:"

# Check conditions
kubectl describe pod auth-service-xxxxx -n prod | grep -A 10 "Conditions:"

# Check events
kubectl get events -n prod | grep auth-service-xxxxx
```

**Root Causes & Solutions:**

**1. Readiness probe failing:**
```bash
# Test readiness endpoint
kubectl exec -it auth-service-xxxxx -n prod -- curl http://localhost:4001/health

# Check logs for startup issues
kubectl logs -n prod auth-service-xxxxx

# Increase initialDelaySeconds if app takes longer to start
kubectl patch deployment auth-service -n prod --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds", "value": 60}
]'
```

**2. Dependencies not ready:**
```bash
# Check if MongoDB is ready
kubectl get pod mongodb-0 -n prod

# Check if other services are ready
kubectl get pods -n prod

# Check service dependencies in logs
kubectl logs -n prod auth-service-xxxxx | grep -i "waiting\|connecting"
```

---

### Issue 4: High Pod Restart Count

**Symptoms:**
```bash
kubectl get pods -n prod
# NAME                            READY   STATUS    RESTARTS   AGE
# auth-service-xxxxx              1/1     Running   47         2d
```

**Diagnosis:**
```bash
# Check restart reason
kubectl describe pod auth-service-xxxxx -n prod | grep -A 10 "Last State:"

# Check for OOMKills
kubectl describe pod auth-service-xxxxx -n prod | grep -i "OOMKilled"

# Check logs across restarts
kubectl logs -n prod auth-service-xxxxx --previous | tail -100
```

**Root Causes & Solutions:**

**1. Memory leak:**
```bash
# Monitor memory usage over time
watch -n 5 'kubectl top pod auth-service-xxxxx -n prod'

# Check for memory leak in application code
# Review logs for growing object counts, unclosed connections

# Temporary fix: Increase memory limit
kubectl set resources deployment auth-service -n prod \
  --limits=memory=512Mi \
  --requests=memory=256Mi

# Long-term: Fix memory leak in application
```

**2. Liveness probe too aggressive:**
```bash
# Increase probe thresholds
kubectl patch deployment auth-service -n prod --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/failureThreshold", "value": 5},
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/periodSeconds", "value": 20}
]'
```

---

## Networking Issues

### Issue 1: Service Endpoints Not Ready

**Symptoms:**
```bash
kubectl get endpoints auth-service -n prod
# NAME           ENDPOINTS   AGE
# auth-service   <none>      10m
```

**Diagnosis:**
```bash
# Check service selector
kubectl get svc auth-service -n prod -o yaml | grep -A 5 selector

# Check pod labels
kubectl get pods -n prod -l app=auth-service --show-labels

# Check if pods are ready
kubectl get pods -n prod -l app=auth-service
```

**Root Causes & Solutions:**

**1. Label mismatch:**
```bash
# Service selector doesn't match pod labels

# Fix: Update service selector or pod labels
kubectl patch service auth-service -n prod -p '{"spec":{"selector":{"app":"auth-service"}}}'

# Or update deployment labels
kubectl label pods -n prod -l app=auth-service-old app=auth-service --overwrite
```

**2. Pods not ready:**
```bash
# Fix readiness issues first (see Pod Issues section)
kubectl describe pod <pod-name> -n prod
```

---

### Issue 2: DNS Resolution Failures

**Symptoms:**
```bash
# Pods can't resolve service names
kubectl exec -it auth-service-xxxxx -n prod -- nslookup mongodb
# Server:         10.100.0.10
# Address:        10.100.0.10#53
#
# ** server can't find mongodb: NXDOMAIN
```

**Diagnosis:**
```bash
# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns

# Test DNS resolution from pod
kubectl exec -it auth-service-xxxxx -n prod -- nslookup kubernetes.default
```

**Root Causes & Solutions:**

**1. CoreDNS pods not running:**
```bash
# Restart CoreDNS
kubectl rollout restart deployment/coredns -n kube-system

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=60s
```

**2. Incorrect service name:**
```bash
# Use fully qualified domain name
# Format: <service-name>.<namespace>.svc.cluster.local

# Test
kubectl exec -it auth-service-xxxxx -n prod -- \
  nslookup mongodb.prod.svc.cluster.local
```

**3. Network policy blocking DNS:**
```bash
# Check network policies
kubectl get networkpolicies -n prod

# Ensure DNS is allowed in egress
kubectl describe networkpolicy <policy-name> -n prod | grep -A 5 "Egress:"

# Should include:
# - Port: 53/UDP for DNS
```

---

### Issue 3: Ingress/ALB Not Working

**Symptoms:**
```bash
curl https://enpm818rgroup7.work.gd
# curl: (7) Failed to connect to enpm818rgroup7.work.gd port 443: Connection refused
```

**Diagnosis:**
```bash
# Check ingress status
kubectl get ingress -n prod
kubectl describe ingress eventsphere-ingress -n prod

# Check ALB Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check ALB in AWS
aws elbv2 describe-load-balancers | grep -A 10 "k8s-prod"

# Check target groups
ALB_ARN=$(kubectl get ingress eventsphere-ingress -n prod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
aws elbv2 describe-target-groups | grep -B 5 ${ALB_ARN}
```

**Root Causes & Solutions:**

**1. ALB Controller not running:**
```bash
# Check controller pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Restart if not healthy
kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
```

**2. Ingress misconfigured:**
```bash
# Check ingress annotations
kubectl get ingress eventsphere-ingress -n prod -o yaml | grep -A 20 annotations

# Verify certificate ARN is correct
kubectl get ingress eventsphere-ingress -n prod \
  -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/certificate-arn}'

# Update certificate ARN if wrong
kubectl annotate ingress eventsphere-ingress -n prod \
  alb.ingress.kubernetes.io/certificate-arn=arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/CERT_ID \
  --overwrite
```

**3. Security groups blocking traffic:**
```bash
# Get ALB security group
ALB_SG=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-prod')].SecurityGroups[0]" \
  --output text)

# Check inbound rules
aws ec2 describe-security-groups --group-ids ${ALB_SG} \
  --query 'SecurityGroups[0].IpPermissions'

# Add HTTPS rule if missing
aws ec2 authorize-security-group-ingress \
  --group-id ${ALB_SG} \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0
```

**4. Target health check failing:**
```bash
# Get target group ARN
TG_ARN=$(aws elbv2 describe-target-groups \
  --query "TargetGroups[?contains(TargetGroupName, 'k8s-prod-authserv')].TargetGroupArn" \
  --output text)

# Check target health
aws elbv2 describe-target-health --target-group-arn ${TG_ARN}

# If unhealthy, check:
# 1. Pods are ready
kubectl get pods -n prod -l app=auth-service

# 2. Health check path is correct
aws elbv2 describe-target-groups --target-group-arns ${TG_ARN} \
  --query 'TargetGroups[0].HealthCheckPath'

# Update ingress health check if needed
kubectl annotate ingress eventsphere-ingress -n prod \
  alb.ingress.kubernetes.io/healthcheck-path=/health \
  --overwrite
```

---

### Issue 4: Network Policy Blocking Traffic

**Symptoms:**
```bash
# Service can't communicate with MongoDB or other services
kubectl logs -n prod auth-service-xxxxx | grep -i "connection refused\|timeout"
```

**Diagnosis:**
```bash
# List network policies
kubectl get networkpolicies -n prod

# Describe policy
kubectl describe networkpolicy auth-service-netpol -n prod

# Test connectivity
kubectl exec -it auth-service-xxxxx -n prod -- \
  nc -zv mongodb.prod.svc.cluster.local 27017
```

**Root Causes & Solutions:**

**1. Policy too restrictive:**
```bash
# Temporarily remove policy to test
kubectl delete networkpolicy auth-service-netpol -n prod

# Test connectivity again
kubectl exec -it auth-service-xxxxx -n prod -- \
  nc -zv mongodb.prod.svc.cluster.local 27017

# If works, update policy to allow traffic
kubectl apply -f k8s/security/network-policies.yaml
```

**2. Missing egress rules:**
```bash
# Check egress rules
kubectl get networkpolicy auth-service-netpol -n prod -o yaml | grep -A 20 egress

# Ensure MongoDB and DNS are allowed
# Update policy to include:
# - MongoDB (port 27017)
# - DNS (port 53/UDP)
# - Other required services
```

---

## Storage Issues

### Issue 1: PVC Not Binding

**Symptoms:**
```bash
kubectl get pvc -n prod
# NAME                    STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# mongodb-data-mongodb-0  Pending                                      mongodb-ebs    5m
```

**Diagnosis:**
```bash
# Check PVC events
kubectl describe pvc mongodb-data-mongodb-0 -n prod

# Check storage class
kubectl get storageclass mongodb-ebs

# Check available PVs
kubectl get pv
```

**Root Causes & Solutions:**

**1. Storage class doesn't exist:**
```bash
# Create storage class
kubectl apply -f k8s/mongodb/storageclass.yaml

# Verify
kubectl get storageclass mongodb-ebs
```

**2. EBS CSI driver not installed:**
```bash
# Check CSI driver pods
kubectl get pods -n kube-system -l app=ebs-csi-controller

# Install if missing
kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"
```

**3. Insufficient volume capacity in AZ:**
```bash
# Check error in events
kubectl describe pvc mongodb-data-mongodb-0 -n prod

# If "InsufficientFreeAddressesInSubnet", need more capacity
# Or force pod to different AZ by draining node
kubectl drain <node-name> --ignore-daemonsets
```

**4. PV already bound to different PVC:**
```bash
# List PVs and their claims
kubectl get pv

# If PV shows wrong claim, delete the PVC (carefully!)
kubectl delete pvc <wrong-pvc> -n prod

# Then PV should be available for correct PVC
```

---

### Issue 2: Disk Space Exhaustion

**Symptoms:**
```bash
kubectl describe node <node-name> | grep -i "DiskPressure"
# DiskPressure   True   NodeHasDiskPressure
```

**Diagnosis:**
```bash
# Check node conditions
kubectl describe node <node-name> | grep -A 10 "Conditions:"

# Check disk usage on node (if SSH access available)
# df -h

# Check which pods are using most disk
kubectl get pods -A -o wide | grep <node-name>
```

**Root Causes & Solutions:**

**1. Image cache full:**
```bash
# Clean up unused images on node
# SSH to node (if available) or use daemonset

# Via SSM (if configured)
INSTANCE_ID=$(kubectl get node <node-name> -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)

aws ssm send-command \
  --instance-ids ${INSTANCE_ID} \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["docker system prune -af"]'
```

**2. Log files filling disk:**
```bash
# Increase log rotation
# Update Docker daemon.json on nodes

# Or deploy log shipper to reduce local logs
kubectl apply -f monitoring/cloudwatch/fluent-bit-config.yaml
```

**3. PVC full:**
```bash
# Check MongoDB disk usage
kubectl exec -it mongodb-0 -n prod -- df -h /data/db

# If full, need to expand PVC
kubectl edit pvc mongodb-data-mongodb-0 -n prod
# Increase storage size

# For EBS volumes, expansion is automatic
# Wait for resize
kubectl get pvc mongodb-data-mongodb-0 -n prod -w
```

---

## Authentication and Authorization

### Issue 1: RBAC Permission Denied

**Symptoms:**
```bash
kubectl get pods -n prod
# Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:prod:default" cannot list resource "pods"
```

**Diagnosis:**
```bash
# Check current user
kubectl auth whoami

# Check if user/SA can perform action
kubectl auth can-i get pods -n prod
kubectl auth can-i get pods -n prod --as system:serviceaccount:prod:default

# List roles and bindings
kubectl get roles,rolebindings -n prod
kubectl get clusterroles,clusterrolebindings
```

**Root Causes & Solutions:**

**1. Missing role binding:**
```bash
# Create role binding
kubectl create rolebinding pod-reader \
  --clusterrole=view \
  --serviceaccount=prod:default \
  --namespace=prod

# Or apply RBAC manifests
kubectl apply -f k8s/base/rbac.yaml
```

**2. Incorrect service account:**
```bash
# Check pod's service account
kubectl get pod <pod-name> -n prod -o jsonpath='{.spec.serviceAccountName}'

# Update deployment to use correct SA
kubectl patch deployment <deployment-name> -n prod \
  -p '{"spec":{"template":{"spec":{"serviceAccountName":"correct-sa"}}}}'
```

---

### Issue 3: External Secrets Not Syncing

**Symptoms:**
```bash
kubectl get secrets -n prod
# mongodb-secret not found

kubectl get externalsecret -n prod
# NAME              STATUS   SYNCED   AGE
# mongodb-secret    ERROR    False    5m
```

**Diagnosis:**
```bash
# Check external secret status
kubectl describe externalsecret mongodb-secret -n prod

# Check External Secrets Operator logs
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets

# Check secret exists in AWS Secrets Manager
aws secretsmanager describe-secret --secret-id eventsphere/mongodb
```

**Root Causes & Solutions:**

**1. Secret doesn't exist in Secrets Manager:**
```bash
# Create secret
aws secretsmanager create-secret \
  --name eventsphere/mongodb \
  --secret-string '{"username":"admin","password":"CHANGE_ME","connection-string":"mongodb://..."}'
```

**2. IRSA not configured for External Secrets:**
```bash
# Check service account
kubectl get sa external-secrets -n external-secrets-system -o yaml

# Annotate if missing
kubectl annotate serviceaccount external-secrets -n external-secrets-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::ACCOUNT_ID:role/external-secrets-role \
  --overwrite

# Restart operator
kubectl rollout restart deployment external-secrets -n external-secrets-system
```

**3. Secret key path incorrect:**
```bash
# Check ExternalSecret definition
kubectl get externalsecret mongodb-secret -n prod -o yaml

# Verify keys match what's in Secrets Manager
aws secretsmanager get-secret-value --secret-id eventsphere/mongodb \
  --query SecretString --output text | jq keys
```

---

## Performance Issues

### Issue 1: High Latency

**Symptoms:**
```bash
# API responses are slow
curl -w "@curl-format.txt" -o /dev/null -s https://api.enpm818rgroup7.work.gd/api/events
# time_total: 5.234s  (should be < 1s)
```

**Diagnosis:**
```bash
# Check pod resource usage
kubectl top pods -n prod

# Check node resource usage
kubectl top nodes

# Check HPA status
kubectl get hpa -n prod

# Check application logs for slow queries
kubectl logs -n prod -l app=event-service | grep -i "slow\|timeout"

# Check Prometheus metrics
# Query: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))
```

**Root Causes & Solutions:**

**1. Database slow queries:**
```bash
# Enable MongoDB profiling
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.setProfilingLevel(1, {slowms: 100});
  db.system.profile.find().sort({ts: -1}).limit(5).pretty();
"

# Check for missing indexes
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.events.getIndexes();
"

# Create indexes if needed
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.events.createIndex({category: 1, date: 1});
"
```

**2. Insufficient resources:**
```bash
# Check if pods are CPU/memory throttled
kubectl describe pod event-service-xxxxx -n prod | grep -A 5 "Limits:"

# Check metrics
kubectl top pod event-service-xxxxx -n prod

# Increase resources
kubectl set resources deployment event-service -n prod \
  --requests=cpu=200m,memory=256Mi \
  --limits=cpu=1000m,memory=512Mi
```

**3. Not enough replicas:**
```bash
# Check current replicas
kubectl get deployment event-service -n prod

# Scale up temporarily
kubectl scale deployment event-service -n prod --replicas=5

# Or adjust HPA min replicas
kubectl patch hpa event-service-hpa -n prod -p '{"spec":{"minReplicas":4}}'
```

**4. Network latency:**
```bash
# Test internal network latency
kubectl run network-test --image=busybox --rm -it --restart=Never -- \
  time wget -O- http://event-service.prod.svc.cluster.local:4002/health

# Check if pods are in same AZ
kubectl get pods -n prod -o wide
kubectl get nodes -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.'topology\.kubernetes\.io/zone'
```

---

### Issue 2: HPA Not Scaling

**Symptoms:**
```bash
kubectl get hpa -n prod
# NAME              REFERENCE                   TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
# auth-service-hpa  Deployment/auth-service     85%/70%   2         10        2          1d
# Despite high CPU, not scaling
```

**Diagnosis:**
```bash
# Check HPA status
kubectl describe hpa auth-service-hpa -n prod

# Check metrics server
kubectl get apiservice v1beta1.metrics.k8s.io

# Check metrics availability
kubectl top pods -n prod
```

**Root Causes & Solutions:**

**1. Metrics server not running:**
```bash
# Check metrics server pods
kubectl get pods -n kube-system -l k8s-app=metrics-server

# Install if missing
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

**2. Resource requests not defined:**
```bash
# HPA needs resource requests to calculate percentage

# Check if requests are defined
kubectl get deployment auth-service -n prod -o yaml | grep -A 5 "requests:"

# Add requests if missing
kubectl set resources deployment auth-service -n prod \
  --requests=cpu=100m,memory=128Mi
```

**3. HPA at max replicas:**
```bash
# Check if already at max
kubectl get hpa auth-service-hpa -n prod

# Increase max if needed
kubectl patch hpa auth-service-hpa -n prod -p '{"spec":{"maxReplicas":15}}'
```

**4. Cluster autoscaler can't add nodes:**
```bash
# Check cluster autoscaler logs
kubectl logs -n kube-system -l app=cluster-autoscaler

# Check node group limits
aws eks describe-nodegroup \
  --cluster-name eventsphere-cluster \
  --nodegroup-name eventsphere-ng-1 \
  --query 'nodegroup.scalingConfig'

# Increase max size if needed
aws eks update-nodegroup-config \
  --cluster-name eventsphere-cluster \
  --nodegroup-name eventsphere-ng-1 \
  --scaling-config minSize=2,maxSize=10,desiredSize=3
```

---

### Issue 3: Cluster Autoscaler Not Adding Nodes

**Symptoms:**
```bash
# Pods stuck in Pending state due to insufficient resources
kubectl get pods -n prod | grep Pending
```

**Diagnosis:**
```bash
# Check pending pods reason
kubectl describe pod <pending-pod> -n prod | grep -A 5 "Events:"
# Should show: "0/3 nodes are available: 3 Insufficient cpu"

# Check cluster autoscaler logs
kubectl logs -n kube-system -l app=cluster-autoscaler | tail -50

# Check node group configuration
aws eks describe-nodegroup \
  --cluster-name eventsphere-cluster \
  --nodegroup-name eventsphere-ng-1
```

**Root Causes & Solutions:**

**1. Cluster autoscaler not running:**
```bash
# Check pods
kubectl get pods -n kube-system -l app=cluster-autoscaler

# Restart if not healthy
kubectl rollout restart deployment cluster-autoscaler -n kube-system
```

**2. Node group at max size:**
```bash
# Increase max size
aws eks update-nodegroup-config \
  --cluster-name eventsphere-cluster \
  --nodegroup-name eventsphere-ng-1 \
  --scaling-config minSize=2,maxSize=10,desiredSize=3
```

**3. IAM permissions missing:**
```bash
# Check cluster autoscaler IAM role
kubectl get sa cluster-autoscaler -n kube-system -o yaml | grep eks.amazonaws.com/role-arn

# Verify role has autoscaling permissions
aws iam get-role-policy \
  --role-name cluster-autoscaler-role \
  --policy-name cluster-autoscaler-policy
```

**4. Pods have node affinity preventing scheduling:**
```bash
# Check pod affinity/anti-affinity
kubectl get pod <pending-pod> -n prod -o yaml | grep -A 10 "affinity:"

# Temporarily remove affinity if too restrictive
kubectl edit deployment <deployment-name> -n prod
# Remove or adjust affinity rules
```

---

## Monitoring and Logging

### Issue 1: Metrics Not Available in Prometheus

**Symptoms:**
```bash
# Grafana dashboards show "No Data"
```

**Diagnosis:**
```bash
# Check Prometheus pods
kubectl get pods -n monitoring -l app=prometheus

# Check Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Open http://localhost:9090/targets in browser

# Check service monitors
kubectl get servicemonitor -n monitoring
```

**Solutions:**
```bash
# Restart Prometheus
kubectl rollout restart statefulset prometheus-prometheus-kube-prometheus-prometheus -n monitoring

# Verify scrape configs
kubectl get prometheus -n monitoring -o yaml | grep -A 20 "scrapeConfigs"
```

---

### Issue 2: Logs Not Appearing in CloudWatch

**Symptoms:**
```bash
# CloudWatch Logs empty or outdated
aws logs tail /aws/eks/eventsphere-cluster/application --since 1h
# No logs returned
```

**Diagnosis:**
```bash
# Check Fluent Bit pods
kubectl get pods -n kube-system -l k8s-app=fluent-bit

# Check Fluent Bit logs
kubectl logs -n kube-system -l k8s-app=fluent-bit

# Check IAM permissions
kubectl get sa fluent-bit -n kube-system -o yaml | grep eks.amazonaws.com/role-arn
```

**Solutions:**
```bash
# Restart Fluent Bit
kubectl rollout restart daemonset fluent-bit -n kube-system

# Verify log group exists
aws logs describe-log-groups --log-group-name-prefix /aws/eks/eventsphere

# Create if missing
aws logs create-log-group --log-group-name /aws/eks/eventsphere-cluster/application
```

---

## Diagnostic Commands Reference

### Cluster Information
```bash
# Cluster info
kubectl cluster-info
kubectl version
aws eks describe-cluster --name eventsphere-cluster --region us-east-1

# Node information
kubectl get nodes -o wide
kubectl describe node <node-name>
kubectl top nodes

# Namespaces
kubectl get namespaces
```

### Pod Debugging
```bash
# List pods
kubectl get pods -A
kubectl get pods -n prod -o wide
kubectl get pods -n prod --show-labels

# Pod details
kubectl describe pod <pod-name> -n prod
kubectl get pod <pod-name> -n prod -o yaml

# Pod logs
kubectl logs <pod-name> -n prod
kubectl logs <pod-name> -n prod --previous
kubectl logs <pod-name> -n prod -c <container-name>
kubectl logs -n prod -l app=auth-service --tail=50

# Execute commands in pod
kubectl exec -it <pod-name> -n prod -- /bin/sh
kubectl exec -it <pod-name> -n prod -- env

# Debug with ephemeral container
kubectl debug <pod-name> -n prod -it --image=busybox
```

### Service and Networking
```bash
# Services
kubectl get svc -A
kubectl describe svc <service-name> -n prod
kubectl get endpoints <service-name> -n prod

# Ingress
kubectl get ingress -A
kubectl describe ingress <ingress-name> -n prod

# Network policies
kubectl get networkpolicies -n prod
kubectl describe networkpolicy <policy-name> -n prod

# Test connectivity
kubectl run test-pod --image=busybox --rm -it --restart=Never -- wget -O- http://<service>.<namespace>.svc.cluster.local
```

### Storage
```bash
# PVCs
kubectl get pvc -A
kubectl describe pvc <pvc-name> -n prod

# PVs
kubectl get pv
kubectl describe pv <pv-name>

# Storage classes
kubectl get storageclass
```

### Configuration
```bash
# ConfigMaps
kubectl get configmaps -n prod
kubectl describe configmap <configmap-name> -n prod

# Secrets
kubectl get secrets -n prod
kubectl describe secret <secret-name> -n prod
kubectl get secret <secret-name> -n prod -o jsonpath='{.data.key}' | base64 -d
```

### Workloads
```bash
# Deployments
kubectl get deployments -n prod
kubectl describe deployment <deployment-name> -n prod
kubectl rollout status deployment/<deployment-name> -n prod
kubectl rollout history deployment/<deployment-name> -n prod

# StatefulSets
kubectl get statefulsets -n prod
kubectl describe statefulset <statefulset-name> -n prod

# DaemonSets
kubectl get daemonsets -A

# HPA
kubectl get hpa -n prod
kubectl describe hpa <hpa-name> -n prod
```

### Events and Logs
```bash
# Events
kubectl get events -n prod --sort-by='.lastTimestamp'
kubectl get events -A --sort-by='.lastTimestamp' | head -20

# Container logs
for pod in $(kubectl get pods -n prod -o name); do
  echo "=== $pod ==="
  kubectl logs -n prod $pod --tail=10
done
```

### Resource Usage
```bash
# Metrics
kubectl top nodes
kubectl top pods -n prod
kubectl top pods -n prod --sort-by=memory
kubectl top pods -n prod --sort-by=cpu
```

### AWS-Specific
```bash
# EKS cluster
aws eks list-clusters
aws eks describe-cluster --name eventsphere-cluster --region us-east-1

# Node groups
aws eks list-nodegroups --cluster-name eventsphere-cluster --region us-east-1
aws eks describe-nodegroup --cluster-name eventsphere-cluster --nodegroup-name eventsphere-ng-1 --region us-east-1

# EC2 instances
aws ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=eventsphere-cluster"

# Load balancers
aws elbv2 describe-load-balancers | grep k8s-prod

# Target groups
aws elbv2 describe-target-groups | grep k8s-prod
aws elbv2 describe-target-health --target-group-arn <arn>
```

---

## Related Documentation

- [Deployment and Rollback Runbook](DEPLOYMENT_ROLLBACK.md)
- [Alert Runbook](../../monitoring/alertmanager/runbook.md)
- [Disaster Recovery Runbook](DISASTER_RECOVERY.md)
- [Security Incident Response](SECURITY_INCIDENT_RESPONSE.md)
- [Maintenance Runbook](MAINTENANCE.md)
- [Kubernetes Documentation](https://kubernetes.io/docs/home/)
- [AWS EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)

---

**Last Updated**: 2025-01-12  
**Version**: 1.0  
**Maintained By**: EventSphere DevOps Team




