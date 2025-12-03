# EventSphere Maintenance Runbook

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Maintenance Schedule](#maintenance-schedule)
3. [EKS Cluster Maintenance](#eks-cluster-maintenance)
4. [Certificate Management](#certificate-management)
5. [Secret Rotation](#secret-rotation)
6. [Image Updates](#image-updates)
7. [Database Maintenance](#database-maintenance)
8. [Monitoring Maintenance](#monitoring-maintenance)
9. [Backup Verification](#backup-verification)
10. [Related Documentation](#related-documentation)

---

## Quick Reference

### Maintenance Windows

- **Production**: First Saturday of each month, 02:00-06:00 UTC
- **Staging**: Every Tuesday, 14:00-16:00 UTC
- **Development**: Continuous (no maintenance window)

### Pre-Maintenance Checklist

```bash
# 1. Create backup
velero backup create pre-maintenance-$(date +%Y%m%d) --include-namespaces prod

# 2. Verify cluster health
kubectl get nodes
kubectl get pods -n prod

# 3. Check resource usage
kubectl top nodes
kubectl top pods -n prod

# 4. Notify stakeholders
echo "Maintenance starting at $(date)" | \
  aws sns publish --topic-arn <maintenance-topic-arn> --message file://-
```

### Post-Maintenance Verification

```bash
# 1. Verify all pods running
kubectl get pods -n prod

# 2. Test services
curl -f https://enpm818rgroup7.work.gd/health
curl -f https://api.enpm818rgroup7.work.gd/api/auth/health

# 3. Check logs for errors
kubectl logs -n prod -l app=auth-service --tail=50 | grep -i error

# 4. Notify completion
echo "Maintenance completed at $(date)" | \
  aws sns publish --topic-arn <maintenance-topic-arn> --message file://-
```

---

## Maintenance Schedule

### Daily Tasks (Automated)

- **Backups**: Daily Velero backup at 02:00 UTC
- **EBS Snapshots**: Daily at 03:00 UTC
- **Log Rotation**: Automatic via Fluent Bit
- **Metrics Collection**: Continuous via Prometheus

### Weekly Tasks

- [ ] Review GuardDuty findings
- [ ] Review Security Hub findings
- [ ] Check EKS cluster health
- [ ] Review application logs for errors
- [ ] Verify backup success
- [ ] Check disk space on nodes
- [ ] Review HPA scaling events

### Monthly Tasks

- [ ] EKS cluster upgrades (if available)
- [ ] Certificate rotation check
- [ ] Review and update alert rules
- [ ] Database optimization
- [ ] Security scan review
- [ ] Cost optimization review
- [ ] Update runbooks with lessons learned

### Quarterly Tasks

- [ ] Disaster recovery drill
- [ ] Full security audit
- [ ] Dependency updates (major versions)
- [ ] Capacity planning review
- [ ] Update architecture documentation
- [ ] Team training on new features

---

## EKS Cluster Maintenance

### 1. EKS Control Plane Upgrade

**Frequency**: As new versions released (typically quarterly)  
**Maintenance Window**: Required  
**Estimated Duration**: 1-2 hours

#### Pre-Upgrade Checklist

```bash
# 1. Check current version
kubectl version --short
aws eks describe-cluster --name eventsphere-cluster --region us-east-1 \
  --query 'cluster.version' --output text

# 2. Check addon compatibility
# Review: https://docs.aws.amazon.com/eks/latest/userguide/managing-add-ons.html

# 3. Review upgrade documentation
# https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html

# 4. Test upgrade in staging first!

# 5. Create backup
velero backup create pre-upgrade-$(date +%Y%m%d) --include-namespaces prod

# 6. Notify team
```

#### Upgrade Procedure

```bash
# 1. Upgrade control plane
CURRENT_VERSION=$(aws eks describe-cluster --name eventsphere-cluster --region us-east-1 \
  --query 'cluster.version' --output text)
NEXT_VERSION="1.29"  # Check AWS docs for next version

aws eks update-cluster-version \
  --name eventsphere-cluster \
  --region us-east-1 \
  --kubernetes-version ${NEXT_VERSION}

# 2. Monitor upgrade progress
watch -n 30 'aws eks describe-update \
  --name eventsphere-cluster \
  --region us-east-1 \
  --update-id <update-id> \
  --query "update.status"'

# Wait for status: Successful

# 3. Update kubeconfig
aws eks update-kubeconfig --name eventsphere-cluster --region us-east-1

# 4. Verify control plane
kubectl version
kubectl get nodes
```

#### Upgrade Add-ons

```bash
# 1. Update CoreDNS
aws eks update-addon \
  --cluster-name eventsphere-cluster \
  --addon-name coredns \
  --addon-version <latest-compatible-version> \
  --region us-east-1

# 2. Update kube-proxy
aws eks update-addon \
  --cluster-name eventsphere-cluster \
  --addon-name kube-proxy \
  --addon-version <latest-compatible-version> \
  --region us-east-1

# 3. Update VPC CNI
aws eks update-addon \
  --cluster-name eventsphere-cluster \
  --addon-name vpc-cni \
  --addon-version <latest-compatible-version> \
  --region us-east-1

# 4. Update EBS CSI Driver
aws eks update-addon \
  --cluster-name eventsphere-cluster \
  --addon-name aws-ebs-csi-driver \
  --addon-version <latest-compatible-version> \
  --region us-east-1

# 5. Verify add-ons
aws eks list-addons --cluster-name eventsphere-cluster --region us-east-1
```

#### Upgrade Node Groups

```bash
# 1. Check current node AMI version
aws eks describe-nodegroup \
  --cluster-name eventsphere-cluster \
  --nodegroup-name eventsphere-ng-1 \
  --region us-east-1 \
  --query 'nodegroup.version'

# 2. Update node group (rolling update)
aws eks update-nodegroup-version \
  --cluster-name eventsphere-cluster \
  --nodegroup-name eventsphere-ng-1 \
  --region us-east-1

# 3. Monitor node group update
watch -n 30 'kubectl get nodes'

# 4. Repeat for all node groups
aws eks update-nodegroup-version \
  --cluster-name eventsphere-cluster \
  --nodegroup-name eventsphere-ng-2 \
  --region us-east-1
```

#### Post-Upgrade Verification

```bash
# 1. Verify cluster version
kubectl version

# 2. Verify nodes
kubectl get nodes
# All nodes should show new version and Ready status

# 3. Verify pods
kubectl get pods -A
# All pods should be Running

# 4. Run health check
./health-check.sh  # See TROUBLESHOOTING.md

# 5. Test application functionality
curl -f https://enpm818rgroup7.work.gd
curl -f https://api.enpm818rgroup7.work.gd/api/events

# 6. Monitor for 24 hours
# Watch metrics and logs for anomalies
```

---

### 2. Update ALB Controller

**Frequency**: As needed (quarterly check)  
**Estimated Duration**: 15 minutes

```bash
# 1. Check current version
kubectl get deployment aws-load-balancer-controller -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# 2. Check latest version
# https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases

# 3. Update via Helm
helm repo update
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eventsphere-cluster

# 4. Verify
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

---

### 3. Update Cluster Autoscaler

**Frequency**: After EKS version upgrade  
**Estimated Duration**: 10 minutes

```bash
# 1. Check Kubernetes version
KUBE_VERSION=$(kubectl version --short | grep Server | awk '{print $3}')

# 2. Update autoscaler image to match K8s version
# Image: k8s.gcr.io/autoscaling/cluster-autoscaler:v1.28.x

kubectl set image deployment cluster-autoscaler -n kube-system \
  cluster-autoscaler=k8s.gcr.io/autoscaling/cluster-autoscaler:v${KUBE_VERSION}

# 3. Verify
kubectl get pods -n kube-system -l app=cluster-autoscaler
kubectl logs -n kube-system -l app=cluster-autoscaler | tail -20
```

---

## Certificate Management

### 1. ACM Certificate Renewal

**Frequency**: Check monthly (AWS auto-renews)  
**Estimated Duration**: 5 minutes

```bash
# 1. List certificates
aws acm list-certificates --region us-east-1

# 2. Check expiration
aws acm describe-certificate \
  --certificate-arn <certificate-arn> \
  --region us-east-1 \
  --query 'Certificate.{Domain:DomainName,Status:Status,Expiration:NotAfter}'

# 3. Verify auto-renewal status
aws acm describe-certificate \
  --certificate-arn <certificate-arn> \
  --region us-east-1 \
  --query 'Certificate.RenewalSummary'

# If not auto-renewing, request new certificate and update ingress
```

### 2. Cosign Key Rotation

**Frequency**: Annually or on compromise  
**Estimated Duration**: 30 minutes

```bash
# 1. Generate new key pair
cosign generate-key-pair

# Output:
# - cosign.key (private key)
# - cosign.pub (public key)

# 2. Backup old keys (for historical verification)
aws s3 cp cosign.key s3://eventsphere-secure-backups/cosign-keys/$(date +%Y%m%d)-old.key --sse AES256
aws s3 cp cosign.pub s3://eventsphere-secure-backups/cosign-keys/$(date +%Y%m%d)-old.pub --sse AES256

# 3. Update GitHub Secrets
# Manual: GitHub → Settings → Secrets → Actions
# Update:
# - COSIGN_PRIVATE_KEY (contents of cosign.key)
# - COSIGN_PUBLIC_KEY (contents of cosign.pub)
# - COSIGN_PASSWORD (if changed)

# 4. Re-sign critical images
for image in auth-service event-service booking-service frontend; do
  echo "Signing $image:latest..."
  cosign sign --key cosign.key ${ECR_REGISTRY}/${image}:latest
done

# 5. Test signature verification
cosign verify --key cosign.pub ${ECR_REGISTRY}/auth-service:latest

# 6. Secure delete old keys locally
shred -u cosign.key.old cosign.pub.old

# 7. Document rotation in security log
```

---

## Secret Rotation

### 1. MongoDB Password Rotation

**Frequency**: Quarterly or on compromise  
**Estimated Duration**: 30 minutes  
**Maintenance Window**: Recommended (brief downtime)

```bash
# 1. Generate new password
NEW_PASSWORD=$(openssl rand -base64 32)

# 2. Update password in MongoDB
kubectl exec -it mongodb-0 -n prod -- mongosh admin --eval "
  db.changeUserPassword('admin', '${NEW_PASSWORD}')
"

# 3. Update AWS Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id eventsphere/mongodb \
  --secret-string "{
    \"username\":\"admin\",
    \"password\":\"${NEW_PASSWORD}\",
    \"connection-string\":\"mongodb://admin:${NEW_PASSWORD}@mongodb.prod.svc.cluster.local:27017/eventsphere?authSource=admin\"
  }"

# 4. Force External Secrets sync
kubectl annotate externalsecret mongodb-secret -n prod \
  force-sync="$(date +%s)" --overwrite

# 5. Restart all services to pick up new credentials
kubectl rollout restart deployment -n prod
kubectl rollout restart statefulset mongodb -n prod

# 6. Verify services are healthy
kubectl get pods -n prod
kubectl logs -n prod -l app=auth-service --tail=20 | grep -i "connected to database"

# 7. Test application functionality
curl -X POST https://api.enpm818rgroup7.work.gd/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"testpass"}'
```

### 2. JWT Secret Rotation

**Frequency**: Quarterly  
**Estimated Duration**: 15 minutes  
**Impact**: All users will be logged out

```bash
# 1. Generate new JWT secret
NEW_JWT_SECRET=$(openssl rand -hex 64)

# 2. Update AWS Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id eventsphere/auth-service \
  --secret-string "{\"jwt-secret\":\"${NEW_JWT_SECRET}\"}"

# 3. Force External Secrets sync
kubectl annotate externalsecret auth-service-secret -n prod \
  force-sync="$(date +%s)" --overwrite

# 4. Restart auth service
kubectl rollout restart deployment auth-service -n prod

# 5. Verify
kubectl logs -n prod -l app=auth-service --tail=20

# 6. Notify users of required re-login
# Update status page or send notification
```

### 3. AWS Access Key Rotation

**Frequency**: Every 90 days  
**Estimated Duration**: 20 minutes

```bash
# 1. Create new access key
aws iam create-access-key --user-name eventsphere-ci

# Output contains new AccessKeyId and SecretAccessKey

# 2. Update GitHub Secrets
# Manual: GitHub → Settings → Secrets → Actions
# Update:
# - AWS_ACCESS_KEY_ID
# - AWS_SECRET_ACCESS_KEY

# 3. Test new credentials
# Trigger a CI/CD workflow or test manually:
export AWS_ACCESS_KEY_ID=<new-key-id>
export AWS_SECRET_ACCESS_KEY=<new-secret-key>
aws sts get-caller-identity

# 4. Deactivate old access key (keep for 24h for rollback)
aws iam update-access-key \
  --access-key-id <old-key-id> \
  --status Inactive \
  --user-name eventsphere-ci

# 5. After 24h, delete old key
aws iam delete-access-key \
  --access-key-id <old-key-id> \
  --user-name eventsphere-ci

# 6. Document rotation
```

---

## Image Updates

### 1. Base Image Updates

**Frequency**: Monthly  
**Estimated Duration**: 2 hours (build + deploy)

```bash
# 1. Update Dockerfiles with latest base images
cd /path/to/EventSphere

# Update node base image
find services -name Dockerfile -exec sed -i 's/node:18-alpine/node:18.19-alpine/g' {} \;

# Update nginx base image
sed -i 's/nginx:alpine/nginx:1.25-alpine/g' frontend/Dockerfile

# 2. Scan updated images locally
docker build -t auth-service:test services/auth-service/
trivy image auth-service:test --severity CRITICAL,HIGH

# 3. Commit changes
git add services/*/Dockerfile frontend/Dockerfile
git commit -m "chore: update base images to latest patches"
git push origin main

# 4. CI/CD will build and deploy automatically
# Monitor deployment
gh workflow view deploy.yml

# 5. Verify in production
kubectl get pods -n prod -o wide
kubectl describe pod <new-pod> -n prod | grep "Image:"
```

### 2. Dependency Updates

**Frequency**: Monthly (minor), Quarterly (major)  
**Estimated Duration**: Varies

```bash
# 1. Check for outdated dependencies
cd services/auth-service
npm outdated

# 2. Update dependencies
# Minor/patch updates (safer)
npm update

# Major updates (test thoroughly)
npm install <package>@latest

# 3. Run tests
npm test

# 4. Update other services
cd ../event-service && npm update && npm test
cd ../booking-service && npm update && npm test

# 5. Update frontend
cd ../../frontend
npm outdated
npm update
npm test

# 6. Commit and deploy
git add */package*.json
git commit -m "chore: update dependencies"
git push origin main
```

---

## Database Maintenance

### 1. MongoDB Index Optimization

**Frequency**: Monthly  
**Estimated Duration**: 30 minutes

```bash
# 1. Connect to MongoDB
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere

# 2. Analyze slow queries
db.setProfilingLevel(1, {slowms: 100});
db.system.profile.find().sort({ts: -1}).limit(10).pretty();

# 3. Check existing indexes
db.users.getIndexes();
db.events.getIndexes();
db.bookings.getIndexes();

# 4. Add missing indexes based on query patterns
db.events.createIndex({category: 1, date: 1});
db.events.createIndex({date: 1, status: 1});
db.bookings.createIndex({userId: 1, eventId: 1});

# 5. Remove unused indexes
db.events.dropIndex("old_unused_index");

# 6. Check index usage
db.events.aggregate([{$indexStats: {}}]);

# 7. Document index changes
```

### 2. MongoDB Compaction

**Frequency**: Quarterly or when disk usage high  
**Estimated Duration**: 1-2 hours  
**Maintenance Window**: Required

```bash
# 1. Check database size
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.stats(1024*1024);  // Size in MB
"

# 2. Create backup before compaction
velero backup create pre-compaction-$(date +%Y%m%d) --include-namespaces prod

# 3. Compact database
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.runCommand({compact: 'users'});
  db.runCommand({compact: 'events'});
  db.runCommand({compact: 'bookings'});
"

# 4. Verify compaction
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.stats(1024*1024);
"

# 5. Monitor performance
kubectl top pod mongodb-0 -n prod
```

### 3. MongoDB Statistics Collection

**Frequency**: Weekly  
**Estimated Duration**: 5 minutes

```bash
# Collect database statistics
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  print('=== Database Statistics ===');
  print('Date: ' + new Date());
  print('');
  
  print('Collection Counts:');
  print('  Users: ' + db.users.countDocuments());
  print('  Events: ' + db.events.countDocuments());
  print('  Bookings: ' + db.bookings.countDocuments());
  print('');
  
  print('Database Size:');
  printjson(db.stats(1024*1024));
  print('');
  
  print('Index Sizes:');
  db.getCollectionNames().forEach(function(col) {
    print('  ' + col + ':');
    db[col].getIndexes().forEach(function(idx) {
      print('    - ' + idx.name);
    });
  });
" > mongodb-stats-$(date +%Y%m%d).txt

# Upload to S3 for historical tracking
aws s3 cp mongodb-stats-$(date +%Y%m%d).txt \
  s3://eventsphere-database-stats/
```

---

## Monitoring Maintenance

### 1. Prometheus Data Retention

**Frequency**: Check monthly  
**Estimated Duration**: 10 minutes

```bash
# 1. Check current retention
kubectl get prometheus -n monitoring -o yaml | grep retention

# 2. Check storage usage
kubectl exec -it prometheus-prometheus-kube-prometheus-prometheus-0 -n monitoring -- \
  df -h /prometheus

# 3. Adjust retention if needed
kubectl patch prometheus prometheus-kube-prometheus-prometheus -n monitoring \
  --type='merge' -p '{"spec":{"retention":"30d","retentionSize":"50GB"}}'

# 4. Delete old data if necessary
kubectl exec -it prometheus-prometheus-kube-prometheus-prometheus-0 -n monitoring -- \
  promtool tsdb delete --start=0 --end=<timestamp> /prometheus
```

### 2. Grafana Dashboard Updates

**Frequency**: As needed  
**Estimated Duration**: 30 minutes

```bash
# 1. Export existing dashboards
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Use Grafana UI to export dashboards as JSON
# Or use API:
GRAFANA_PASSWORD=$(kubectl get secret prometheus-grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 -d)

curl -u admin:${GRAFANA_PASSWORD} \
  http://localhost:3000/api/dashboards/db/eventsphere-overview | \
  jq '.dashboard' > grafana-dashboard-backup.json

# 2. Update dashboards
# Import new/updated dashboards via UI or API

# 3. Test dashboards
# Verify all panels display data correctly

# 4. Commit dashboard JSONs to Git
cp grafana-dashboard-backup.json monitoring/grafana/dashboards/
git add monitoring/grafana/dashboards/
git commit -m "chore: update Grafana dashboards"
git push
```

### 3. Alert Rule Tuning

**Frequency**: Monthly  
**Estimated Duration**: 30 minutes

```bash
# 1. Review alert history
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Open http://localhost:9090/alerts

# 2. Check for noisy alerts
kubectl get prometheusrules -n monitoring
kubectl describe prometheusrule eventsphere-alerts -n monitoring

# 3. Update alert thresholds
kubectl edit prometheusrule eventsphere-alerts -n monitoring

# 4. Test alerts
# Trigger test condition and verify alert fires

# 5. Update runbook if alert procedures changed
# See monitoring/alertmanager/runbook.md

# 6. Commit changes
git add monitoring/prometheus/alert-rules.yaml
git commit -m "chore: tune alert thresholds based on metrics"
git push
```

### 4. CloudWatch Logs Cleanup

**Frequency**: Monthly  
**Estimated Duration**: 10 minutes

```bash
# 1. List log groups
aws logs describe-log-groups --query 'logGroups[*].[logGroupName,storedBytes]' --output table

# 2. Check retention settings
aws logs describe-log-groups \
  --log-group-name-prefix /aws/eks/eventsphere \
  --query 'logGroups[*].[logGroupName,retentionInDays]'

# 3. Update retention if needed
aws logs put-retention-policy \
  --log-group-name /aws/eks/eventsphere-cluster/cluster \
  --retention-in-days 7

# 4. Delete old log streams if needed
aws logs describe-log-streams \
  --log-group-name /aws/eks/eventsphere-cluster/cluster \
  --order-by LastEventTime \
  --max-items 100 | \
  jq -r '.logStreams[] | select(.lastEventTimestamp < '$(($(date +%s)*1000 - 30*24*60*60*1000))') | .logStreamName' | \
  xargs -I {} aws logs delete-log-stream \
    --log-group-name /aws/eks/eventsphere-cluster/cluster \
    --log-stream-name {}
```

---

## Backup Verification

### Monthly Backup Test

**Frequency**: Monthly  
**Estimated Duration**: 1 hour

```bash
# 1. List recent backups
velero backup get

# 2. Verify backup exists and is complete
LATEST_BACKUP=$(velero backup get --output json | \
  jq -r '.items | sort_by(.status.startTimestamp) | last | .metadata.name')

velero backup describe ${LATEST_BACKUP} --details

# 3. Test restore to separate namespace
kubectl create namespace restore-test

velero restore create monthly-test-$(date +%Y%m%d) \
  --from-backup ${LATEST_BACKUP} \
  --namespace-mappings prod:restore-test

# 4. Monitor restore
velero restore describe monthly-test-$(date +%Y%m%d) --details

# 5. Verify restored resources
kubectl get all -n restore-test

# 6. Test restored application
kubectl port-forward -n restore-test svc/frontend 8080:80
# Open browser to http://localhost:8080

# 7. Verify database data
kubectl exec -it mongodb-0 -n restore-test -- mongosh eventsphere --eval "
  db.users.countDocuments();
  db.events.countDocuments();
  db.bookings.countDocuments();
"

# 8. Cleanup
kubectl delete namespace restore-test

# 9. Document results
cat > backup-test-$(date +%Y%m%d).txt <<EOF
Backup Test Report
Date: $(date)
Backup: ${LATEST_BACKUP}
Status: SUCCESS/FAILURE
Issues: [List any issues]
Recommendations: [Any improvements needed]
EOF

aws s3 cp backup-test-$(date +%Y%m%d).txt s3://eventsphere-maintenance-reports/
```

---

## Related Documentation

- [Backup and Restore Runbook](BACKUP_RESTORE.md)
- [Disaster Recovery Runbook](DISASTER_RECOVERY.md)
- [Security Incident Response](SECURITY_INCIDENT_RESPONSE.md)
- [Deployment and Rollback](DEPLOYMENT_ROLLBACK.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [EKS Version Updates](https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html)
- [Kubernetes Upgrade Guide](https://kubernetes.io/docs/tasks/administer-cluster/cluster-upgrade/)

---

**Last Updated**: 2025-01-12  
**Version**: 1.0  
**Maintained By**: EventSphere DevOps Team

**Next Scheduled Maintenance**: First Saturday of each month, 02:00-06:00 UTC  
**Contact**: devops@enpm818rgroup7.work.gd




