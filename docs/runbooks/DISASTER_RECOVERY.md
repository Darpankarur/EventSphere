# EventSphere Disaster Recovery Runbook

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Overview](#overview)
3. [Disaster Scenarios](#disaster-scenarios)
4. [Recovery Time and Point Objectives](#recovery-time-and-point-objectives)
5. [Complete Cluster Failure Recovery](#complete-cluster-failure-recovery)
6. [Regional Outage Recovery](#regional-outage-recovery)
7. [Data Corruption Recovery](#data-corruption-recovery)
8. [Security Breach Recovery](#security-breach-recovery)
9. [Post-Recovery Verification](#post-recovery-verification)
10. [Testing Disaster Recovery](#testing-disaster-recovery)
11. [Related Documentation](#related-documentation)

---

## Quick Reference

### Emergency Contacts

- **DevOps Lead**: Contact via Slack @devops-lead or phone
- **Security Team**: security@enpm818rgroup7.work.gd
- **AWS Support**: Access via AWS Console (Enterprise Support)

### Critical Recovery Commands

```bash
# Recreate cluster from IaC
cd infrastructure/scripts && ./setup-eks.sh

# Restore from Velero backup
velero restore create emergency-restore --from-backup <latest-backup>

# Restore secrets from AWS Secrets Manager (automatic via External Secrets Operator)
kubectl annotate externalsecret mongodb-secret -n prod force-sync="$(date +%s)" --overwrite
```

### Key Resources

- S3 Backup Bucket: `eventsphere-velero-backups`
- AWS Secrets Manager: `eventsphere/*`
- Git Repository: Main branch contains production-ready IaC
- EBS Snapshots: Tagged with `Project: EventSphere`

---

## Overview

This runbook provides comprehensive procedures for recovering EventSphere from catastrophic failures. All procedures assume you have:

- AWS CLI access with admin permissions
- Access to Git repository with infrastructure code
- Access to backup S3 bucket
- kubectl installed locally

**Important**: Initiate recovery immediately upon detection of disaster. Time is critical.

---

## Disaster Scenarios

### Scenario Classification

| Scenario | Severity | Recovery Priority | Estimated RTO |
|----------|----------|-------------------|---------------|
| Complete Cluster Failure | P1 - Critical | Immediate | 2 hours |
| Regional Outage | P1 - Critical | Immediate | 4-8 hours |
| Data Corruption | P2 - High | Urgent | 1-2 hours |
| Security Breach | P1 - Critical | Immediate | 2-4 hours |
| Namespace Failure | P3 - Medium | High | 30 minutes |
| Individual Service Failure | P4 - Low | Normal | 15 minutes |

---

## Recovery Time and Point Objectives

### Current Configuration

- **RPO (Recovery Point Objective)**: 24 hours
  - Daily Velero backups at 2:00 AM UTC
  - Daily EBS snapshots at 3:00 AM UTC
  
- **RTO (Recovery Time Objective)**: 2 hours for P1 incidents
  - Cluster recreation: 45 minutes
  - Data restoration: 30 minutes
  - Service validation: 30 minutes
  - DNS propagation: 15 minutes

---

## Complete Cluster Failure Recovery

### Scenario
The entire EKS cluster is unavailable or corrupted beyond repair.

### Pre-Recovery Checklist

```bash
# Verify cluster is truly down
aws eks describe-cluster --name eventsphere-cluster --region us-east-1

# Check if it's a regional issue
aws health describe-events --region us-east-1

# Notify stakeholders
echo "DR initiated: Complete cluster failure at $(date)" | \
  aws sns publish --topic-arn <notification-topic> --message file://-
```

### Step 1: Assess the Situation

```bash
# Document current state
aws eks describe-cluster --name eventsphere-cluster --region us-east-1 > cluster-state.json

# Check node status
aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=eventsphere-cluster" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
  --output table

# Check control plane logs (if accessible)
aws logs describe-log-groups --log-group-name-prefix /aws/eks/eventsphere-cluster
```

### Step 2: Decision Point

**Can cluster be recovered?**

- **YES**: Attempt targeted recovery (see specific sections)
- **NO**: Proceed with complete rebuild

### Step 3: Preserve Evidence (if possible)

```bash
# Export cluster description
aws eks describe-cluster --name eventsphere-cluster --region us-east-1 > disaster-cluster-state.json

# Export node group info
aws eks describe-nodegroup \
  --cluster-name eventsphere-cluster \
  --nodegroup-name eventsphere-ng-1 \
  --region us-east-1 > disaster-nodegroup-state.json

# Store in S3 for investigation
aws s3 cp disaster-cluster-state.json s3://eventsphere-disaster-recovery/$(date +%Y%m%d)/
```

### Step 4: Delete Failed Cluster (if necessary)

```bash
# If cluster is corrupted and cannot be recovered
cd infrastructure/scripts
./teardown-eks.sh

# Confirm deletion
aws eks describe-cluster --name eventsphere-cluster --region us-east-1
# Should return: ResourceNotFoundException
```

### Step 5: Recreate Cluster from IaC

```bash
# Pull latest infrastructure code
cd /path/to/EventSphere
git pull origin main

# Verify IaC configuration
cat infrastructure/eksctl-cluster.yaml

# Create new cluster
cd infrastructure/scripts
chmod +x setup-eks.sh
./setup-eks.sh

# Monitor cluster creation
watch -n 10 'aws eks describe-cluster --name eventsphere-cluster --region us-east-1 --query "cluster.status"'
```

**Expected Duration**: 30-45 minutes

### Step 6: Verify Cluster Readiness

```bash
# Update kubeconfig
aws eks update-kubeconfig --name eventsphere-cluster --region us-east-1

# Verify nodes are ready
kubectl get nodes
# All nodes should show STATUS: Ready

# Verify add-ons
kubectl get pods -n kube-system

# Expected: ALB Controller, Cluster Autoscaler, CoreDNS, EBS CSI Driver, etc.
```

### Step 7: Restore Velero Backup System

```bash
# Reinstall Velero (if using automated backups)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME=eventsphere-velero-backups

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket ${BUCKET_NAME} \
  --backup-location-config region=us-east-1 \
  --snapshot-location-config region=us-east-1 \
  --sa-annotations eks.amazonaws.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/velero-backup-role \
  --use-node-agent \
  --uploader-type restic

# Verify Velero can access backups
velero backup get
```

### Step 8: Restore Application Data

```bash
# List available backups
velero backup get

# Get latest production backup
LATEST_BACKUP=$(velero backup get --output json | \
  jq -r '.items | sort_by(.status.startTimestamp) | last | .metadata.name')

echo "Restoring from backup: $LATEST_BACKUP"

# Restore production namespace
velero restore create disaster-recovery-restore-$(date +%Y%m%d-%H%M%S) \
  --from-backup ${LATEST_BACKUP} \
  --include-namespaces prod

# Monitor restore progress
velero restore describe disaster-recovery-restore-TIMESTAMP --details

# Watch pods coming up
watch -n 5 'kubectl get pods -n prod'
```

**Expected Duration**: 15-30 minutes

### Step 9: Restore MongoDB from EBS Snapshot (if needed)

```bash
# If Velero restore didn't fully recover MongoDB, restore from EBS snapshot
# See BACKUP_RESTORE.md for detailed EBS restoration procedures

# Quick steps:
# 1. Identify latest snapshot
SNAPSHOT_ID=$(aws ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=tag:Project,Values=EventSphere" "Name=tag:Component,Values=MongoDB" \
  --query 'Snapshots | sort_by(@, &StartTime) | [-1].SnapshotId' \
  --output text)

# 2. Follow EBS restore procedure in BACKUP_RESTORE.md
```

### Step 10: Reconfigure Ingress and DNS

```bash
# Apply ingress configuration
cd /path/to/EventSphere
kubectl apply -f k8s/ingress/

# Get ALB DNS name
ALB_DNS=$(kubectl get ingress eventsphere-ingress -n prod \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "ALB DNS: $ALB_DNS"

# Update Route53 (if using custom domain)
# Get hosted zone ID
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='enpm818rgroup7.work.gd.'].Id" \
  --output text | cut -d'/' -f3)

# Update DNS record
cat > route53-changes.json <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "enpm818rgroup7.work.gd",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "$ALB_DNS"}]
    }
  }]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id ${HOSTED_ZONE_ID} \
  --change-batch file://route53-changes.json
```

### Step 11: Verify All Services

```bash
# Check all deployments
kubectl get deployments -n prod

# Check all pods are running
kubectl get pods -n prod
# All pods should show STATUS: Running

# Check service endpoints
kubectl get endpoints -n prod
# All services should have endpoints

# Test service health
for service in auth-service event-service booking-service frontend; do
  echo "Testing $service..."
  kubectl run test-pod --image=curlimages/curl --rm -it --restart=Never -- \
    curl -s http://${service}.prod.svc.cluster.local:4001/health || \
    curl -s http://${service}.prod.svc.cluster.local/health
done

# Test external access
curl -I https://enpm818rgroup7.work.gd
```

### Step 12: Restore Monitoring

```bash
# Reinstall Prometheus/Grafana stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --create-namespace \
  -f monitoring/prometheus/values.yaml

# Apply alert rules
kubectl apply -f monitoring/prometheus/alert-rules.yaml

# Verify monitoring
kubectl get pods -n monitoring
```

### Step 13: Post-Recovery Validation

See [Post-Recovery Verification](#post-recovery-verification) section below.

---

## Regional Outage Recovery

### Scenario
Entire AWS region (us-east-1) is unavailable.

### Current Limitation
EventSphere is currently deployed in a single region. Multi-region deployment is planned.

### Recovery Steps (Single Region)

**Immediate Actions:**
1. Monitor AWS Health Dashboard for outage updates
2. Notify stakeholders of expected downtime
3. Prepare for recovery when region becomes available

**When Region Recovers:**
1. Follow [Complete Cluster Failure Recovery](#complete-cluster-failure-recovery) if cluster is damaged
2. If cluster survived, verify all services and data integrity

### Future: Multi-Region Failover (Planned)

Once multi-region deployment is implemented:

```bash
# 1. Update Route53 to point to secondary region
aws route53 change-resource-record-sets \
  --hosted-zone-id ${HOSTED_ZONE_ID} \
  --change-batch file://failover-to-us-west-2.json

# 2. Sync data from us-east-1 backups to us-west-2
velero restore create --from-backup ${LATEST_BACKUP} \
  --restore-volumes=true

# 3. Verify services in secondary region
kubectl --context us-west-2 get pods -n prod
```

---

## Data Corruption Recovery

### Scenario
MongoDB data is corrupted but cluster is functional.

### Detection

```bash
# Check MongoDB logs for corruption
kubectl logs -n prod mongodb-0 | grep -i "corruption\|error\|fatal"

# Try to connect
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.serverStatus()
"
```

### Recovery Steps

#### Option 1: Repair Database (Minor Corruption)

```bash
# Connect to MongoDB
kubectl exec -it mongodb-0 -n prod -- mongosh

# Switch to admin database
use admin

# Run repair
db.runCommand({repairDatabase: 1})

# Verify collections
use eventsphere
db.getCollectionNames()
```

#### Option 2: Restore from Backup (Major Corruption)

```bash
# Scale down all services
kubectl scale deployment auth-service -n prod --replicas=0
kubectl scale deployment event-service -n prod --replicas=0
kubectl scale deployment booking-service -n prod --replicas=0

# Scale down MongoDB
kubectl scale statefulset mongodb -n prod --replicas=0

# Wait for termination
kubectl wait --for=delete pod/mongodb-0 -n prod --timeout=120s

# Restore from EBS snapshot
# Follow detailed steps in BACKUP_RESTORE.md

# Quick reference:
SNAPSHOT_ID=$(aws ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=tag:Project,Values=EventSphere" "Name=tag:Component,Values=MongoDB" \
  --query 'Snapshots | sort_by(@, &StartTime) | [-2].SnapshotId' \
  --output text)  # Use -2 to get second-to-last (before corruption)

# Follow EBS restoration procedure...

# Scale up MongoDB
kubectl scale statefulset mongodb -n prod --replicas=1
kubectl wait --for=condition=ready pod/mongodb-0 -n prod --timeout=300s

# Verify data integrity
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  print('Users: ' + db.users.countDocuments());
  print('Events: ' + db.events.countDocuments());
  print('Bookings: ' + db.bookings.countDocuments());
"

# Scale up services
kubectl scale deployment auth-service -n prod --replicas=2
kubectl scale deployment event-service -n prod --replicas=2
kubectl scale deployment booking-service -n prod --replicas=2
```

**Expected Duration**: 1-2 hours

---

## Security Breach Recovery

### Scenario
Security incident requires complete environment rebuild (compromised credentials, rootkit, etc.).

### Immediate Actions

```bash
# 1. Isolate the cluster (block external access)
kubectl delete ingress eventsphere-ingress -n prod

# 2. Cordon all nodes to prevent new pod scheduling
kubectl get nodes -o name | xargs -I {} kubectl cordon {}

# 3. Document current state for forensics
kubectl get all -A > security-incident-state.txt
kubectl get events -A > security-incident-events.txt

# 4. Collect logs
for pod in $(kubectl get pods -n prod -o name); do
  kubectl logs -n prod $pod > security-logs-$(basename $pod).txt
done

# 5. Upload to secure forensics bucket
aws s3 cp security-incident-state.txt s3://eventsphere-security-forensics/$(date +%Y%m%d)/
aws s3 cp security-logs-*.txt s3://eventsphere-security-forensics/$(date +%Y%m%d)/
```

### Recovery Steps

#### 1. Rotate All Credentials

```bash
# Rotate AWS access keys
# Manual: AWS Console → IAM → Users → Security Credentials → Make inactive

# Rotate Secrets Manager secrets
# MongoDB password
aws secretsmanager put-secret-value \
  --secret-id eventsphere/mongodb \
  --secret-string '{"username":"admin","password":"NEW_SECURE_PASSWORD_HERE"}'

# JWT secret
aws secretsmanager put-secret-value \
  --secret-id eventsphere/auth-service \
  --secret-string '{"jwt-secret":"NEW_JWT_SECRET_HERE"}'

# Rotate GitHub secrets (manual via GitHub UI)
# - AWS_ACCESS_KEY_ID
# - AWS_SECRET_ACCESS_KEY
# - COSIGN_PRIVATE_KEY (regenerate with: cosign generate-key-pair)
```

#### 2. Rebuild Cluster

```bash
# Delete compromised cluster
cd infrastructure/scripts
./teardown-eks.sh

# Recreate from trusted IaC
git pull origin main  # Ensure using latest trusted code
./setup-eks.sh
```

#### 3. Scan and Deploy Clean Images

```bash
# Re-scan all container images
for image in auth-service event-service booking-service frontend; do
  echo "Scanning $image..."
  trivy image ${ECR_REGISTRY}/${image}:latest
done

# If any images compromised, rebuild from clean source
# Trigger CI/CD from clean commit
git log --oneline -10  # Find last known good commit
git checkout <clean-commit-hash>
# Push to trigger clean build

# Or manual rebuild
docker build -t ${ECR_REGISTRY}/auth-service:clean-rebuild services/auth-service/
docker push ${ECR_REGISTRY}/auth-service:clean-rebuild
```

#### 4. Deploy with New Secrets

```bash
# Restore applications (will pull new secrets)
velero restore create security-rebuild-$(date +%Y%m%d) \
  --from-backup <backup-before-breach>

# Force External Secrets sync
kubectl annotate externalsecret mongodb-secret -n prod force-sync="$(date +%s)" --overwrite
kubectl annotate externalsecret auth-service-secret -n prod force-sync="$(date +%s)" --overwrite

# Restart all pods to use new secrets
kubectl rollout restart deployment -n prod
kubectl rollout restart statefulset -n prod
```

#### 5. Enhanced Security Post-Breach

```bash
# Enable stricter network policies
kubectl apply -f k8s/security/network-policies.yaml

# Enable Pod Security Standards enforcement
kubectl label namespace prod pod-security.kubernetes.io/enforce=restricted --overwrite

# Review and update RBAC
kubectl apply -f k8s/base/rbac.yaml

# Enable audit logging (should already be enabled)
aws eks update-cluster-config \
  --name eventsphere-cluster \
  --region us-east-1 \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```

**Expected Duration**: 2-4 hours

---

## Post-Recovery Verification

### Comprehensive Validation Checklist

```bash
# 1. Cluster Health
kubectl cluster-info
kubectl get nodes
# All nodes: Ready

# 2. Namespaces and Resources
kubectl get namespaces
kubectl get all -n prod
kubectl get all -n monitoring
# All pods: Running

# 3. Storage
kubectl get pv
kubectl get pvc -n prod
# MongoDB PVC: Bound

# 4. ConfigMaps and Secrets
kubectl get configmaps -n prod
kubectl get secrets -n prod
# All secrets present

# 5. Services and Endpoints
kubectl get svc -n prod
kubectl get endpoints -n prod
# All services have endpoints

# 6. Ingress and Load Balancer
kubectl get ingress -n prod
# ALB showing valid hostname

# 7. HPA and Autoscaling
kubectl get hpa -n prod
# All HPA showing current/target metrics

# 8. Network Policies
kubectl get networkpolicies -n prod
# All policies applied

# 9. Monitoring
kubectl get pods -n monitoring
# Prometheus, Grafana running

# 10. Service Health Checks
curl -f https://enpm818rgroup7.work.gd/health || echo "Frontend health check failed"
curl -f https://api.enpm818rgroup7.work.gd/api/auth/health || echo "Auth service health check failed"
```

### Functional Testing

```bash
# Test authentication
curl -X POST https://api.enpm818rgroup7.work.gd/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"testpassword"}'

# Test event listing
curl https://api.enpm818rgroup7.work.gd/api/events

# Test database connectivity
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  print('MongoDB connection: OK');
  print('Collections: ' + db.getCollectionNames());
  print('Users count: ' + db.users.countDocuments());
  print('Events count: ' + db.events.countDocuments());
"
```

### Performance Verification

```bash
# Check resource usage
kubectl top nodes
kubectl top pods -n prod

# Check response times
for i in {1..10}; do
  curl -w "@curl-format.txt" -o /dev/null -s https://enpm818rgroup7.work.gd
done

# curl-format.txt content:
# time_namelookup: %{time_namelookup}\n
# time_connect: %{time_connect}\n
# time_appconnect: %{time_appconnect}\n
# time_pretransfer: %{time_pretransfer}\n
# time_starttransfer: %{time_starttransfer}\n
# time_total: %{time_total}\n
```

### Data Integrity Verification

```bash
# Compare record counts with pre-disaster state (if available)
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.users.countDocuments()
  db.events.countDocuments()
  db.bookings.countDocuments()
"

# Check for recent data
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.events.find().sort({createdAt: -1}).limit(5).pretty()
"

# Verify no data duplication
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.users.aggregate([
    {\$group: {_id: '\$email', count: {\$sum: 1}}},
    {\$match: {count: {gt: 1}}}
  ])
"
```

---

## Testing Disaster Recovery

### Monthly DR Test (Recommended)

```bash
# 1. Create test environment
kubectl create namespace dr-test

# 2. Deploy test resources
kubectl run test-app --image=nginx -n dr-test
kubectl expose pod test-app --port=80 -n dr-test

# 3. Create backup
velero backup create dr-test-backup --include-namespaces dr-test

# 4. Delete namespace (simulate disaster)
kubectl delete namespace dr-test

# 5. Restore
velero restore create --from-backup dr-test-backup

# 6. Verify
kubectl get all -n dr-test

# 7. Document results
echo "DR Test $(date): SUCCESS" >> dr-test-log.txt

# 8. Cleanup
kubectl delete namespace dr-test
velero backup delete dr-test-backup
```

### Quarterly Full DR Drill (Recommended)

Test complete cluster rebuild in non-production account:

1. Create test AWS account or separate VPC
2. Deploy EventSphere using IaC
3. Restore production backup to test environment
4. Validate all services
5. Document timing and issues
6. Tear down test environment

---

## Related Documentation

- [Backup and Restore Runbook](BACKUP_RESTORE.md)
- [Security Incident Response Runbook](SECURITY_INCIDENT_RESPONSE.md)
- [Deployment Guide](../../DEPLOYMENT.md)
- [Architecture Overview](../../ARCHITECTURE.md)
- [Security Documentation](../../SECURITY.md)

---

**Last Updated**: 2025-01-12  
**Version**: 1.0  
**Maintained By**: EventSphere DevOps Team  
**Next Review Date**: 2025-04-12  

**DR Test Schedule**:
- Monthly Test: First Monday of each month
- Quarterly Drill: First Monday of January, April, July, October




