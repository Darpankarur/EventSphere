# EventSphere Security Incident Response Runbook

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Incident Classification](#incident-classification)
3. [Initial Response Procedures](#initial-response-procedures)
4. [Evidence Collection](#evidence-collection)
5. [Containment Procedures](#containment-procedures)
6. [Investigation Steps](#investigation-steps)
7. [Specific Incident Scenarios](#specific-incident-scenarios)
8. [Remediation Actions](#remediation-actions)
9. [Post-Incident Analysis](#post-incident-analysis)
10. [Related Documentation](#related-documentation)

---

## Quick Reference

### Emergency Contacts

- **Security Team**: security@enpm818rgroup7.work.gd
- **DevOps On-Call**: Pager/Slack @devops-oncall
- **AWS Support**: Enterprise Support via Console
- **Management Escalation**: management@enpm818rgroup7.work.gd

### Critical First Actions

```bash
# 1. ISOLATE: Block external access immediately
kubectl delete ingress eventsphere-ingress -n prod

# 2. PRESERVE: Snapshot current state
kubectl get all -A > incident-$(date +%Y%m%d-%H%M%S)-state.txt
kubectl get events -A >> incident-$(date +%Y%m%d-%H%M%S)-events.txt

# 3. ALERT: Notify security team
aws sns publish --topic-arn <security-topic-arn> \
  --subject "SECURITY INCIDENT: EventSphere" \
  --message "Incident detected at $(date). Cluster isolated."

# 4. INVESTIGATE: Check GuardDuty findings
aws guardduty list-findings --detector-id <detector-id> --region us-east-1
```

### Security Tools Quick Access

```bash
# GuardDuty
aws guardduty list-detectors
aws guardduty list-findings --detector-id <id>

# Security Hub
aws securityhub get-findings --filters '{"ProductName":[{"Value":"GuardDuty","Comparison":"EQUALS"}]}'

# CloudWatch Logs
aws logs tail /aws/eks/eventsphere-cluster/cluster --follow

# Pod forensics
kubectl get pods -n prod -o wide
kubectl logs -n prod <suspicious-pod> --previous
```

---

## Incident Classification

### Severity Levels

| Severity | Description | Response Time | Examples |
|----------|-------------|---------------|----------|
| **P1 - Critical** | Active attack or data breach | Immediate (< 15 min) | Ransomware, data exfiltration, root access |
| **P2 - High** | Potential security compromise | < 1 hour | Suspicious pod behavior, unauthorized access attempts |
| **P3 - Medium** | Security policy violation | < 4 hours | Vulnerable image, misconfiguration |
| **P4 - Low** | Security information | < 24 hours | Failed login attempts, outdated certificate |

### Incident Types

1. **Compromised Pod**: Container showing malicious behavior
2. **Unauthorized Access**: Failed/successful unauthorized kubectl or API access
3. **Data Breach**: Unauthorized access to sensitive data
4. **Malware Detection**: Malicious code in container or node
5. **DDoS Attack**: Overwhelming traffic to services
6. **Vulnerable Image**: Critical CVE discovered in running image
7. **Credential Exposure**: API keys or secrets leaked
8. **Insider Threat**: Suspicious activity from authorized user

---

## Initial Response Procedures

### Step 1: Verify the Incident (5 minutes)

```bash
# Check GuardDuty findings
aws guardduty list-findings \
  --detector-id $(aws guardduty list-detectors --query 'DetectorIds[0]' --output text) \
  --finding-criteria '{"Criterion":{"severity":{"Gte":7}}}' \
  --region us-east-1

# Get finding details
aws guardduty get-findings \
  --detector-id <detector-id> \
  --finding-ids <finding-id> \
  --region us-east-1

# Check Security Hub
aws securityhub get-findings \
  --filters '{"SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"}],"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}]}' \
  --region us-east-1

# Check recent pod creations
kubectl get events -n prod --sort-by='.lastTimestamp' | grep -i "pod\|create\|delete"

# Check for suspicious processes
kubectl get pods -n prod -o wide
```

### Step 2: Classify Severity (2 minutes)

Use the classification matrix above to determine severity level.

### Step 3: Initiate Response (3 minutes)

```bash
# Create incident ticket
INCIDENT_ID="INC-$(date +%Y%m%d-%H%M%S)"
mkdir -p /tmp/${INCIDENT_ID}
cd /tmp/${INCIDENT_ID}

# Document initial findings
cat > initial-report.txt <<EOF
Incident ID: ${INCIDENT_ID}
Date/Time: $(date)
Severity: [P1/P2/P3/P4]
Type: [Compromised Pod/Unauthorized Access/etc]
Reporter: $(whoami)
Initial Observations:
- 
- 
EOF

# Notify stakeholders (adjust based on severity)
# P1/P2: Immediate notification
# P3/P4: Email notification
```

---

## Evidence Collection

### Critical: Preserve Before Modifying

```bash
# Set incident ID
INCIDENT_ID="INC-$(date +%Y%m%d-%H%M%S)"
EVIDENCE_DIR="/tmp/${INCIDENT_ID}/evidence"
mkdir -p ${EVIDENCE_DIR}
cd ${EVIDENCE_DIR}

# 1. Cluster state
kubectl get all -A > cluster-state.txt
kubectl get nodes -o wide > nodes.txt
kubectl get pods -A -o wide > all-pods.txt
kubectl get events -A --sort-by='.lastTimestamp' > all-events.txt

# 2. Security resources
kubectl get networkpolicies -A -o yaml > network-policies.yaml
kubectl get secrets -A > secrets-list.txt  # Don't export values!
kubectl get serviceaccounts -A > service-accounts.txt
kubectl describe clusterrole > cluster-roles.txt
kubectl describe clusterrolebinding > cluster-role-bindings.txt

# 3. Pod-specific evidence (if specific pod suspected)
SUSPICIOUS_POD="<pod-name>"
SUSPICIOUS_NS="prod"

kubectl get pod ${SUSPICIOUS_POD} -n ${SUSPICIOUS_NS} -o yaml > pod-${SUSPICIOUS_POD}.yaml
kubectl logs ${SUSPICIOUS_POD} -n ${SUSPICIOUS_NS} > logs-${SUSPICIOUS_POD}.txt
kubectl logs ${SUSPICIOUS_POD} -n ${SUSPICIOUS_NS} --previous > logs-${SUSPICIOUS_POD}-previous.txt
kubectl describe pod ${SUSPICIOUS_POD} -n ${SUSPICIOUS_NS} > describe-${SUSPICIOUS_POD}.txt

# 4. Node information (if node suspected)
SUSPICIOUS_NODE="<node-name>"
kubectl describe node ${SUSPICIOUS_NODE} > node-${SUSPICIOUS_NODE}.txt
kubectl get pods -A --field-selector spec.nodeName=${SUSPICIOUS_NODE} > pods-on-${SUSPICIOUS_NODE}.txt

# 5. AWS CloudWatch logs
aws logs filter-log-events \
  --log-group-name /aws/eks/eventsphere-cluster/cluster \
  --start-time $(date -d '1 hour ago' +%s)000 \
  --filter-pattern "error ERROR" \
  > cloudwatch-errors.txt

# 6. GuardDuty findings
aws guardduty list-findings \
  --detector-id $(aws guardduty list-detectors --query 'DetectorIds[0]' --output text) \
  --finding-criteria '{"Criterion":{"updatedAt":{"Gte":'$(date -d '24 hours ago' +%s)000'}}}' \
  --region us-east-1 > guardduty-findings.txt

# 7. Security Hub findings
aws securityhub get-findings \
  --filters '{"UpdatedAt":[{"DateRange":{"Value":1,"Unit":"DAYS"}}]}' \
  --region us-east-1 > securityhub-findings.json

# 8. ALB access logs (if enabled)
aws s3 sync s3://eventsphere-alb-logs/AWSLogs/ ./alb-logs/ \
  --exclude "*" \
  --include "*$(date +%Y/%m/%d)*"

# 9. Create tarball of evidence
cd /tmp/${INCIDENT_ID}
tar -czf evidence.tar.gz evidence/

# 10. Upload to secure S3 bucket
aws s3 cp evidence.tar.gz s3://eventsphere-security-incidents/${INCIDENT_ID}/ \
  --sse AES256

# 11. Calculate hash for integrity
sha256sum evidence.tar.gz > evidence.tar.gz.sha256

echo "Evidence collected and stored at: s3://eventsphere-security-incidents/${INCIDENT_ID}/"
```

---

## Containment Procedures

### Level 1: Isolate External Access

```bash
# Remove ingress (blocks all external traffic)
kubectl delete ingress eventsphere-ingress -n prod

# Verify ALB is no longer routing
kubectl get ingress -n prod
# Should show: No resources found

# Alternative: Modify security group to block traffic
ALB_SG=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-prod')].SecurityGroups[0]" \
  --output text)

# Remove inbound rules
aws ec2 revoke-security-group-ingress \
  --group-id ${ALB_SG} \
  --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0}]'
```

### Level 2: Isolate Specific Pod

```bash
# Apply strict network policy to isolate pod
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-suspicious-pod
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: <suspicious-app>
  policyTypes:
  - Ingress
  - Egress
  # No ingress/egress rules = deny all
EOF

# Verify pod is isolated
kubectl describe networkpolicy isolate-suspicious-pod -n prod

# Alternative: Delete pod if not needed for forensics
kubectl delete pod <suspicious-pod> -n prod --force --grace-period=0
```

### Level 3: Cordon Node

```bash
# Prevent new pods from scheduling on node
kubectl cordon <node-name>

# Verify node is cordoned
kubectl get nodes
# Should show: SchedulingDisabled

# If node is compromised, drain it
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Terminate node instance
INSTANCE_ID=$(kubectl get node <node-name> -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)
aws ec2 terminate-instances --instance-ids ${INSTANCE_ID}
```

### Level 4: Namespace Isolation

```bash
# Isolate entire namespace
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-namespace
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# Verify isolation
kubectl get networkpolicy -n prod
```

### Level 5: Credential Rotation (if compromise suspected)

```bash
# Rotate MongoDB password
NEW_MONGO_PASSWORD=$(openssl rand -base64 32)
aws secretsmanager put-secret-value \
  --secret-id eventsphere/mongodb \
  --secret-string "{\"username\":\"admin\",\"password\":\"${NEW_MONGO_PASSWORD}\",\"connection-string\":\"mongodb://admin:${NEW_MONGO_PASSWORD}@mongodb.prod.svc.cluster.local:27017/eventsphere?authSource=admin\"}"

# Force External Secrets sync
kubectl annotate externalsecret mongodb-secret -n prod force-sync="$(date +%s)" --overwrite

# Restart MongoDB and services
kubectl rollout restart statefulset mongodb -n prod
kubectl rollout restart deployment -n prod

# Rotate JWT secret
NEW_JWT_SECRET=$(openssl rand -hex 64)
aws secretsmanager put-secret-value \
  --secret-id eventsphere/auth-service \
  --secret-string "{\"jwt-secret\":\"${NEW_JWT_SECRET}\"}"

kubectl annotate externalsecret auth-service-secret -n prod force-sync="$(date +%s)" --overwrite
kubectl rollout restart deployment auth-service -n prod
```

---

## Investigation Steps

### 1. GuardDuty Analysis

```bash
# List all findings
DETECTOR_ID=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)

aws guardduty list-findings \
  --detector-id ${DETECTOR_ID} \
  --finding-criteria '{"Criterion":{"severity":{"Gte":4},"updatedAt":{"Gte":'$(date -d '7 days ago' +%s)000'}}}' \
  --region us-east-1 \
  --output json > guardduty-findings-list.json

# Get detailed findings
FINDING_IDS=$(cat guardduty-findings-list.json | jq -r '.FindingIds[]')

for finding_id in ${FINDING_IDS}; do
  aws guardduty get-findings \
    --detector-id ${DETECTOR_ID} \
    --finding-ids ${finding_id} \
    --region us-east-1 >> guardduty-details.json
done

# Analyze findings
cat guardduty-details.json | jq '.Findings[] | {
  type: .Type,
  severity: .Severity,
  title: .Title,
  description: .Description,
  resource: .Resource.ResourceType
}'
```

### 2. Pod Analysis

```bash
# Check pod with most restarts
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail -n 10

# Check pods not matching expected image
kubectl get pods -n prod -o json | jq -r '.items[] | select(.spec.containers[0].image | contains("latest") or contains("eventsphere-") | not) | .metadata.name'

# Check privileged pods
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.containers[].securityContext.privileged == true) | "\(.metadata.namespace)/\(.metadata.name)"'

# Check pods with host network
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.hostNetwork == true) | "\(.metadata.namespace)/\(.metadata.name)"'

# Check pods accessing host filesystem
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.volumes[]?.hostPath != null) | "\(.metadata.namespace)/\(.metadata.name)"'
```

### 3. Network Traffic Analysis

```bash
# Check pod network connections (requires network tools in pod)
kubectl exec -it <pod-name> -n prod -- netstat -tunapl

# Check service endpoints
kubectl get endpoints -A

# Analyze network policies
kubectl get networkpolicies -A
kubectl describe networkpolicy -A | grep -A 10 "Spec:"

# Check for unauthorized services
kubectl get svc -A | grep -v "ClusterIP\|LoadBalancer\|NodePort"
```

### 4. RBAC Analysis

```bash
# Check service accounts with cluster-admin
kubectl get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name == "cluster-admin") | .metadata.name'

# Check who can exec into pods
kubectl auth can-i create pods/exec --as system:serviceaccount:prod:default

# List all service accounts in prod
kubectl get serviceaccounts -n prod

# Check permissions for suspicious service account
kubectl describe clusterrolebinding | grep -A 5 <suspicious-sa>
```

### 5. CloudWatch Logs Investigation

```bash
# Search for suspicious API calls
aws logs filter-log-events \
  --log-group-name /aws/eks/eventsphere-cluster/cluster \
  --filter-pattern "exec delete secret" \
  --start-time $(date -d '24 hours ago' +%s)000

# Search for failed authentication
aws logs filter-log-events \
  --log-group-name /aws/eks/eventsphere-cluster/cluster \
  --filter-pattern "Forbidden Unauthorized" \
  --start-time $(date -d '24 hours ago' +%s)000

# Search for privilege escalation attempts
aws logs filter-log-events \
  --log-group-name /aws/eks/eventsphere-cluster/cluster \
  --filter-pattern "escalate privilege" \
  --start-time $(date -d '24 hours ago' +%s)000
```

### 6. Image Analysis

```bash
# Scan suspicious image
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
SUSPICIOUS_IMAGE="<image-name>:<tag>"

# Pull image
docker pull ${ECR_REGISTRY}/${SUSPICIOUS_IMAGE}

# Scan with Trivy
trivy image ${ECR_REGISTRY}/${SUSPICIOUS_IMAGE} \
  --severity CRITICAL,HIGH \
  --format json > image-scan-results.json

# Check image history
docker history ${ECR_REGISTRY}/${SUSPICIOUS_IMAGE}

# Verify image signature
cosign verify --key cosign.pub ${ECR_REGISTRY}/${SUSPICIOUS_IMAGE}
```

---

## Specific Incident Scenarios

### Scenario 1: Compromised Pod

**Indicators**:
- Unusual network connections
- Unexpected processes
- High CPU/memory usage
- GuardDuty alert

**Response**:

```bash
# 1. Isolate pod
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-compromised-pod
  namespace: prod
spec:
  podSelector:
    matchLabels:
      pod-name: <compromised-pod>
  policyTypes:
  - Ingress
  - Egress
EOF

# 2. Collect forensic data
kubectl logs <compromised-pod> -n prod --all-containers > compromised-pod-logs.txt
kubectl exec <compromised-pod> -n prod -- ps aux > compromised-pod-processes.txt
kubectl exec <compromised-pod> -n prod -- netstat -tunapl > compromised-pod-connections.txt

# 3. Create pod snapshot (if needed for deep forensics)
kubectl debug <compromised-pod> -n prod --copy-to=forensic-copy --share-processes

# 4. Terminate compromised pod
kubectl delete pod <compromised-pod> -n prod

# 5. Verify replacement pod is clean
NEW_POD=$(kubectl get pods -n prod -l app=<app-name> --sort-by=.metadata.creationTimestamp | tail -1 | awk '{print $1}')
kubectl logs ${NEW_POD} -n prod | grep -i "suspicious\|malware\|crypto"

# 6. Investigate root cause
# - Was image compromised?
# - Was privilege escalation used?
# - Were secrets accessed?
```

### Scenario 2: Unauthorized Access Attempts

**Indicators**:
- Multiple failed login attempts
- kubectl commands from unknown IPs
- GuardDuty "UnauthorizedAPICall" findings

**Response**:

```bash
# 1. Review CloudWatch audit logs
aws logs filter-log-events \
  --log-group-name /aws/eks/eventsphere-cluster/cluster \
  --filter-pattern "Forbidden" \
  --start-time $(date -d '48 hours ago' +%s)000 | \
  jq '.events[].message' > unauthorized-attempts.txt

# 2. Identify source IPs
cat unauthorized-attempts.txt | grep -oP '\d+\.\d+\.\d+\.\d+' | sort | uniq -c | sort -rn

# 3. Block malicious IPs at ALB level
cat > waf-ip-set.json <<EOF
{
  "IPSetDescriptors": [
    {"Type": "IPV4", "Value": "<malicious-ip>/32"}
  ]
}
EOF

# Create WAF IP set (if WAF enabled)
aws wafv2 create-ip-set \
  --name EventSphere-BlockedIPs \
  --scope REGIONAL \
  --ip-address-version IPV4 \
  --addresses <malicious-ip>/32 \
  --region us-east-1

# 4. Review IAM users and access keys
aws iam list-users | jq '.Users[] | {UserName, CreateDate}'
aws iam list-access-keys --user-name <suspicious-user>

# 5. Disable compromised credentials
aws iam update-access-key \
  --access-key-id <compromised-key> \
  --status Inactive \
  --user-name <user>

# 6. Force password reset
aws iam update-login-profile \
  --user-name <user> \
  --password-reset-required
```

### Scenario 3: DDoS Attack

**Indicators**:
- Abnormally high traffic
- ALB showing 5xx errors
- Services unresponsive
- High pod CPU/memory

**Response**:

```bash
# 1. Check current traffic
kubectl top pods -n prod
kubectl get hpa -n prod

# 2. Check ALB metrics
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-prod')].LoadBalancerArn" \
  --output text)

aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=${ALB_ARN##*/} \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum

# 3. Enable WAF (if not already enabled)
# Manual: AWS Console → WAF → Create Web ACL → Associate with ALB

# 4. Implement rate limiting at ingress
kubectl annotate ingress eventsphere-ingress -n prod \
  alb.ingress.kubernetes.io/wafv2-acl-arn=<waf-acl-arn>

# 5. Scale up services temporarily
kubectl scale deployment auth-service -n prod --replicas=10
kubectl scale deployment event-service -n prod --replicas=10
kubectl scale deployment booking-service -n prod --replicas=10

# 6. Enable AWS Shield (if not enabled)
aws shield create-protection \
  --name EventSphere-ALB-Protection \
  --resource-arn ${ALB_ARN}

# 7. Monitor and adjust
watch -n 10 'kubectl top pods -n prod'
```

### Scenario 4: Vulnerable Image Detected

**Indicators**:
- Trivy scan shows CRITICAL CVE
- ECR scan finds vulnerabilities
- Security Hub finding

**Response**:

```bash
# 1. Identify affected images
aws ecr describe-images \
  --repository-name auth-service \
  --query 'imageDetails[*].[imageTags[0],imageScanStatus.status,imageScanFindingsSummary.findingSeverityCounts.CRITICAL]' \
  --output table

# 2. Get vulnerability details
aws ecr describe-image-scan-findings \
  --repository-name auth-service \
  --image-id imageTag=latest \
  --query 'imageScanFindings.findings[?severity==`CRITICAL`]' \
  --output json > critical-vulns.json

# 3. Check if vulnerability is exploitable in our context
cat critical-vulns.json | jq '.[] | {name, description, uri}'

# 4. Immediate mitigation if actively exploited
# Delete pods running vulnerable image
kubectl delete pods -n prod -l app=auth-service

# Temporarily use previous known-good image
kubectl set image deployment/auth-service -n prod \
  auth-service=${ECR_REGISTRY}/auth-service:<previous-tag>

# 5. Trigger rebuild with patched base image
# Update Dockerfile with patched base image
# Trigger CI/CD rebuild

# 6. Verify new image is clean
trivy image ${ECR_REGISTRY}/auth-service:new-tag --severity CRITICAL

# 7. Deploy patched version
kubectl set image deployment/auth-service -n prod \
  auth-service=${ECR_REGISTRY}/auth-service:new-tag

# 8. Document in security log
```

### Scenario 5: Data Exfiltration Detected

**Indicators**:
- GuardDuty "Exfiltration" finding
- Unusual outbound traffic
- Large data transfer from MongoDB

**Response**:

```bash
# 1. IMMEDIATE: Block all outbound traffic
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-egress
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53  # Allow only DNS
EOF

# 2. Identify source pod
aws guardduty get-findings \
  --detector-id ${DETECTOR_ID} \
  --finding-ids <finding-id> \
  --query 'Findings[0].Resource.KubernetesDetails' \
  --output json

# 3. Isolate source pod
kubectl delete pod <source-pod> -n prod

# 4. Check MongoDB audit logs (if enabled)
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.system.profile.find({ts: {\$gte: new Date(Date.now() - 3600000)}}).sort({ts: -1}).pretty()
"

# 5. Check what data was accessed
# Review application logs
kubectl logs <source-pod> -n prod --previous | grep -i "query\|find\|select"

# 6. Identify destination
aws guardduty get-findings \
  --detector-id ${DETECTOR_ID} \
  --finding-ids <finding-id> \
  --query 'Findings[0].Service.Action.NetworkConnectionAction.RemoteIpDetails' \
  --output json

# 7. Notify legal/compliance team
# Potential data breach - follow data breach protocol

# 8. Rotate all credentials (data may include secrets)
# See containment Level 5 procedure above

# 9. Review access logs to determine scope
aws s3 ls s3://eventsphere-access-logs/ --recursive | grep $(date +%Y/%m/%d)
```

---

## Remediation Actions

### 1. Patch Vulnerabilities

```bash
# Update base images in Dockerfiles
cd /path/to/EventSphere
find services -name Dockerfile -exec sed -i 's/node:18-alpine/node:18.19-alpine/g' {} \;

# Rebuild all images
for service in auth-service event-service booking-service; do
  docker build -t ${ECR_REGISTRY}/${service}:patched services/${service}/
  docker push ${ECR_REGISTRY}/${service}:patched
done

# Deploy patched images
kubectl set image deployment/auth-service -n prod auth-service=${ECR_REGISTRY}/auth-service:patched
kubectl set image deployment/event-service -n prod event-service=${ECR_REGISTRY}/event-service:patched
kubectl set image deployment/booking-service -n prod booking-service=${ECR_REGISTRY}/booking-service:patched
```

### 2. Harden Security Policies

```bash
# Enforce Pod Security Standards
kubectl label namespace prod pod-security.kubernetes.io/enforce=restricted --overwrite
kubectl label namespace prod pod-security.kubernetes.io/audit=restricted --overwrite
kubectl label namespace prod pod-security.kubernetes.io/warn=restricted --overwrite

# Apply stricter network policies
kubectl apply -f k8s/security/network-policies.yaml

# Enable audit logging (if not already)
aws eks update-cluster-config \
  --name eventsphere-cluster \
  --region us-east-1 \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```

### 3. Implement Additional Monitoring

```bash
# Enable GuardDuty EKS Protection (if not enabled)
aws guardduty update-detector \
  --detector-id ${DETECTOR_ID} \
  --enable \
  --features '[{"Name":"EKS_AUDIT_LOGS","Status":"ENABLED"}]'

# Create additional CloudWatch alarms
aws cloudwatch put-metric-alarm \
  --alarm-name eventsphere-unauthorized-api-calls \
  --alarm-description "Alert on unauthorized API calls" \
  --metric-name UnauthorizedAPICallCount \
  --namespace AWS/GuardDuty \
  --statistic Sum \
  --period 300 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1
```

### 4. Update Incident Response Plan

Based on lessons learned, update this runbook and train team members.

---

## Post-Incident Analysis

### 1. Incident Report Template

```markdown
# Security Incident Report

**Incident ID**: INC-YYYYMMDD-HHMMSS
**Date**: YYYY-MM-DD
**Severity**: P1/P2/P3/P4
**Status**: Resolved/Investigating

## Summary
[Brief description of incident]

## Timeline
- HH:MM: Incident detected
- HH:MM: Containment initiated
- HH:MM: Root cause identified
- HH:MM: Remediation completed
- HH:MM: Incident resolved

## Impact
- Services affected:
- Data affected:
- Users affected:
- Downtime:

## Root Cause
[Detailed analysis of what caused the incident]

## Response Actions Taken
1. 
2. 
3. 

## Evidence
- Location: s3://eventsphere-security-incidents/INC-YYYYMMDD-HHMMSS/
- Hash: [SHA256]

## Lessons Learned
### What Went Well
-

### What Could Be Improved
-

## Action Items
- [ ] Update security policies
- [ ] Patch vulnerabilities
- [ ] Update monitoring
- [ ] Team training
- [ ] Documentation updates

## Sign-Off
- Security Team: [Name] [Date]
- DevOps Lead: [Name] [Date]
- Management: [Name] [Date]
```

### 2. Conduct Post-Mortem

```bash
# Schedule post-mortem meeting within 48 hours
# Invitees:
# - Security team
# - DevOps team
# - Development team
# - Management (for P1/P2)

# Topics to cover:
# 1. Incident timeline
# 2. Detection efficiency
# 3. Response effectiveness
# 4. Tools and automation gaps
# 5. Training needs
# 6. Policy updates needed
```

### 3. Implement Improvements

```bash
# Track action items from post-mortem
# Update security documentation
# Schedule training sessions
# Implement additional controls
# Test improvements
```

---

## Related Documentation

- [Disaster Recovery Runbook](DISASTER_RECOVERY.md)
- [Backup and Restore Runbook](BACKUP_RESTORE.md)
- [Security Documentation](../../SECURITY.md)
- [Alert Runbook](../../monitoring/alertmanager/runbook.md)
- [AWS GuardDuty Documentation](https://docs.aws.amazon.com/guardduty/)
- [Kubernetes Security Best Practices](https://kubernetes.io/docs/concepts/security/)

---

**Last Updated**: 2025-01-12  
**Version**: 1.0  
**Maintained By**: EventSphere Security Team  
**Next Review Date**: 2025-02-12

**Emergency Hotline**: security@enpm818rgroup7.work.gd  
**Escalation Path**: Security Team → DevOps Lead → CTO




