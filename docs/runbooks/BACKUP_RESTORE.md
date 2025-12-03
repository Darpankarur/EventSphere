# EventSphere Backup and Restore Runbook

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Overview](#overview)
3. [Velero Automated Backups](#velero-automated-backups)
4. [Manual EBS Snapshot Procedures](#manual-ebs-snapshot-procedures)
5. [Secrets Backup and Recovery](#secrets-backup-and-recovery)
6. [Backup Verification](#backup-verification)
7. [Restore Procedures](#restore-procedures)
8. [Troubleshooting](#troubleshooting)
9. [Related Documentation](#related-documentation)

---

## Quick Reference

### Emergency Restore Commands

```bash
# Quick restore from Velero backup
velero restore create --from-backup <backup-name>

# Quick restore MongoDB from EBS snapshot
aws ec2 create-volume --snapshot-id snap-xxxxx --availability-zone us-east-1a
```

### Backup Status Check

```bash
# Check Velero backups
velero backup get

# Check EBS snapshots
aws ec2 describe-snapshots --owner-ids self --filters "Name=tag:Project,Values=EventSphere"
```

---

## Overview

EventSphere uses a multi-layered backup strategy:

- **Velero**: Automated cluster-wide and namespace backups (daily/weekly)
- **EBS Snapshots**: Manual and scheduled snapshots of MongoDB persistent volumes
- **AWS Secrets Manager**: Automatic backup of all secrets

**RPO (Recovery Point Objective)**: 24 hours  
**RTO (Recovery Time Objective)**: 2 hours

---

## Velero Automated Backups

### Prerequisites

- AWS CLI configured with appropriate permissions
- kubectl access to EKS cluster
- Helm 3.x installed

### 1. Install Velero

#### 1.1 Create S3 Bucket for Backups

```bash
AWS_REGION=us-east-1
BUCKET_NAME=eventsphere-velero-backups
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create S3 bucket
aws s3 mb s3://${BUCKET_NAME} --region ${AWS_REGION}

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket ${BUCKET_NAME} \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket ${BUCKET_NAME} \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Add lifecycle policy (delete backups after 90 days)
aws s3api put-bucket-lifecycle-configuration \
  --bucket ${BUCKET_NAME} \
  --lifecycle-configuration '{
    "Rules": [{
      "Id": "DeleteOldBackups",
      "Status": "Enabled",
      "Prefix": "",
      "Expiration": {"Days": 90}
    }]
  }'
```

#### 1.2 Create IAM Policy for Velero

```bash
cat > velero-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeVolumes",
                "ec2:DescribeSnapshots",
                "ec2:CreateTags",
                "ec2:CreateVolume",
                "ec2:CreateSnapshot",
                "ec2:DeleteSnapshot"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:PutObject",
                "s3:AbortMultipartUpload",
                "s3:ListMultipartUploadParts"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}"
            ]
        }
    ]
}
EOF

# Create IAM policy
aws iam create-policy \
  --policy-name VeleroBackupPolicy \
  --policy-document file://velero-policy.json
```

#### 1.3 Create IAM Role for Velero Service Account

```bash
# Get OIDC provider
OIDC_PROVIDER=$(aws eks describe-cluster --name eventsphere-cluster --region us-east-1 \
  --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")

# Create trust policy
cat > velero-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:velero:velero",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# Create IAM role
aws iam create-role \
  --role-name velero-backup-role \
  --assume-role-policy-document file://velero-trust-policy.json

# Attach policy to role
aws iam attach-role-policy \
  --role-name velero-backup-role \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/VeleroBackupPolicy
```

#### 1.4 Install Velero CLI

```bash
# Linux
wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz
tar -xvf velero-v1.12.0-linux-amd64.tar.gz
sudo mv velero-v1.12.0-linux-amd64/velero /usr/local/bin/

# macOS
brew install velero

# Verify installation
velero version --client-only
```

#### 1.5 Install Velero in EKS Cluster

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket ${BUCKET_NAME} \
  --backup-location-config region=${AWS_REGION} \
  --snapshot-location-config region=${AWS_REGION} \
  --sa-annotations eks.amazonaws.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/velero-backup-role \
  --use-node-agent \
  --uploader-type restic

# Verify installation
kubectl get pods -n velero
```

**Expected Output:**
```
NAME                      READY   STATUS    RESTARTS   AGE
velero-xxxxx              1/1     Running   0          1m
node-agent-xxxxx          1/1     Running   0          1m
```

### 2. Configure Backup Schedules

#### 2.1 Daily MongoDB Backup

```bash
# Create daily backup of prod namespace (includes MongoDB)
velero schedule create daily-prod-backup \
  --schedule="0 2 * * *" \
  --include-namespaces prod \
  --ttl 168h0m0s \
  --labels backup-type=daily

# Verify schedule
velero schedule get
```

#### 2.2 Weekly Full Cluster Backup

```bash
# Create weekly full cluster backup
velero schedule create weekly-full-backup \
  --schedule="0 3 * * 0" \
  --ttl 720h0m0s \
  --labels backup-type=weekly

# Verify schedule
velero schedule get
```

#### 2.3 Pre-Deployment Backup

```bash
# Manual backup before deployments
velero backup create pre-deployment-$(date +%Y%m%d-%H%M%S) \
  --include-namespaces prod \
  --labels backup-type=pre-deployment

# Wait for backup to complete
velero backup describe pre-deployment-TIMESTAMP --details
```

### 3. Velero Backup Verification

```bash
# List all backups
velero backup get

# Check specific backup status
velero backup describe <backup-name> --details

# Check backup logs
velero backup logs <backup-name>

# Verify backup in S3
aws s3 ls s3://${BUCKET_NAME}/backups/ --recursive
```

### 4. Velero Restore Procedures

#### 4.1 Restore Full Namespace

```bash
# List available backups
velero backup get

# Restore from backup
velero restore create --from-backup <backup-name>

# Monitor restore progress
velero restore describe <restore-name> --details

# Check restore logs
velero restore logs <restore-name>
```

#### 4.2 Restore Specific Resources

```bash
# Restore only MongoDB StatefulSet
velero restore create mongodb-restore \
  --from-backup <backup-name> \
  --include-resources statefulsets \
  --selector app=mongodb

# Restore only secrets
velero restore create secrets-restore \
  --from-backup <backup-name> \
  --include-resources secrets \
  --include-namespaces prod
```

#### 4.3 Restore to Different Namespace

```bash
# Restore prod to staging
velero restore create prod-to-staging \
  --from-backup <backup-name> \
  --namespace-mappings prod:staging
```

### 5. Test Backup and Restore (Non-Production)

```bash
# Create test namespace
kubectl create namespace backup-test

# Deploy test application
kubectl run test-app --image=nginx -n backup-test

# Create backup
velero backup create test-backup --include-namespaces backup-test

# Delete namespace
kubectl delete namespace backup-test

# Restore from backup
velero restore create --from-backup test-backup

# Verify restoration
kubectl get all -n backup-test

# Cleanup
kubectl delete namespace backup-test
velero backup delete test-backup
```

---

## Manual EBS Snapshot Procedures

### 1. Identify MongoDB Volumes

```bash
# Get MongoDB PVC
kubectl get pvc -n prod -l app=mongodb

# Get volume ID from PVC
PV_NAME=$(kubectl get pvc mongodb-data-mongodb-0 -n prod -o jsonpath='{.spec.volumeName}')
VOLUME_ID=$(kubectl get pv $PV_NAME -o jsonpath='{.spec.awsElasticBlockStore.volumeID}' | cut -d'/' -f4)

echo "MongoDB Volume ID: $VOLUME_ID"
```

### 2. Create Manual Snapshot via AWS CLI

```bash
# Create snapshot
SNAPSHOT_ID=$(aws ec2 create-snapshot \
  --volume-id ${VOLUME_ID} \
  --description "EventSphere MongoDB backup - $(date +%Y-%m-%d)" \
  --tag-specifications "ResourceType=snapshot,Tags=[
    {Key=Project,Value=EventSphere},
    {Key=Environment,Value=Production},
    {Key=Component,Value=MongoDB},
    {Key=BackupType,Value=Manual},
    {Key=CreatedDate,Value=$(date +%Y-%m-%d)}
  ]" \
  --query 'SnapshotId' \
  --output text)

echo "Created snapshot: $SNAPSHOT_ID"

# Wait for snapshot to complete
aws ec2 wait snapshot-completed --snapshot-ids $SNAPSHOT_ID

# Verify snapshot
aws ec2 describe-snapshots --snapshot-ids $SNAPSHOT_ID
```

### 3. Create Snapshot via AWS Console

1. Navigate to **EC2 Console** → **Elastic Block Store** → **Volumes**
2. Find the volume with tag `Project: EventSphere` and `Component: MongoDB`
3. Select the volume → **Actions** → **Create Snapshot**
4. Add description: `EventSphere MongoDB - YYYY-MM-DD`
5. Add tags:
   - `Project: EventSphere`
   - `Environment: Production`
   - `Component: MongoDB`
   - `BackupType: Manual`
6. Click **Create Snapshot**
7. Monitor progress in **Snapshots** section

### 4. Schedule Automated EBS Snapshots with AWS Backup

```bash
# Create backup vault
aws backup create-backup-vault \
  --backup-vault-name EventSphereVault \
  --backup-vault-tags Project=EventSphere

# Create IAM role for AWS Backup (if not exists)
cat > aws-backup-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "backup.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name AWSBackupDefaultServiceRole \
  --assume-role-policy-document file://aws-backup-trust-policy.json

aws iam attach-role-policy \
  --role-name AWSBackupDefaultServiceRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup

# Create backup plan
cat > backup-plan.json <<EOF
{
  "BackupPlanName": "EventSphere-Daily-MongoDB",
  "Rules": [
    {
      "RuleName": "DailyBackup",
      "TargetBackupVaultName": "EventSphereVault",
      "ScheduleExpression": "cron(0 3 * * ? *)",
      "StartWindowMinutes": 60,
      "CompletionWindowMinutes": 120,
      "Lifecycle": {
        "DeleteAfterDays": 30
      },
      "RecoveryPointTags": {
        "Project": "EventSphere",
        "BackupType": "Automated"
      }
    }
  ]
}
EOF

BACKUP_PLAN_ID=$(aws backup create-backup-plan \
  --backup-plan file://backup-plan.json \
  --query 'BackupPlanId' \
  --output text)

# Create backup selection
cat > backup-selection.json <<EOF
{
  "SelectionName": "MongoDB-EBS-Volumes",
  "IamRoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/AWSBackupDefaultServiceRole",
  "Resources": [
    "arn:aws:ec2:${AWS_REGION}:${AWS_ACCOUNT_ID}:volume/${VOLUME_ID}"
  ],
  "ListOfTags": [
    {
      "ConditionType": "STRINGEQUALS",
      "ConditionKey": "Project",
      "ConditionValue": "EventSphere"
    }
  ]
}
EOF

aws backup create-backup-selection \
  --backup-plan-id ${BACKUP_PLAN_ID} \
  --backup-selection file://backup-selection.json
```

### 5. Restore from EBS Snapshot

#### 5.1 Create Volume from Snapshot

```bash
# List available snapshots
aws ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=tag:Project,Values=EventSphere" "Name=tag:Component,Values=MongoDB" \
  --query 'Snapshots[*].[SnapshotId,StartTime,Description]' \
  --output table

# Get availability zone of current MongoDB pod
AZ=$(kubectl get pod mongodb-0 -n prod -o jsonpath='{.spec.nodeName}' | \
  xargs -I {} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')

# Create new volume from snapshot
NEW_VOLUME_ID=$(aws ec2 create-volume \
  --snapshot-id ${SNAPSHOT_ID} \
  --availability-zone ${AZ} \
  --volume-type gp3 \
  --encrypted \
  --tag-specifications "ResourceType=volume,Tags=[
    {Key=Project,Value=EventSphere},
    {Key=Component,Value=MongoDB},
    {Key=RestoredFrom,Value=${SNAPSHOT_ID}}
  ]" \
  --query 'VolumeId' \
  --output text)

echo "Created volume: $NEW_VOLUME_ID"

# Wait for volume to be available
aws ec2 wait volume-available --volume-ids $NEW_VOLUME_ID
```

#### 5.2 Update Kubernetes PV

```bash
# Scale down MongoDB StatefulSet
kubectl scale statefulset mongodb -n prod --replicas=0

# Wait for pod to terminate
kubectl wait --for=delete pod/mongodb-0 -n prod --timeout=60s

# Get the PV name
PV_NAME=$(kubectl get pvc mongodb-data-mongodb-0 -n prod -o jsonpath='{.spec.volumeName}')

# Delete PVC (but not PV - set reclaim policy first)
kubectl patch pv ${PV_NAME} -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl delete pvc mongodb-data-mongodb-0 -n prod

# Update PV with new volume ID
kubectl patch pv ${PV_NAME} --type='json' -p="[
  {
    \"op\": \"replace\",
    \"path\": \"/spec/awsElasticBlockStore/volumeID\",
    \"value\": \"aws://${AZ}/${NEW_VOLUME_ID}\"
  }
]"

# Remove claimRef from PV
kubectl patch pv ${PV_NAME} --type='json' -p='[{"op": "remove", "path": "/spec/claimRef"}]'

# Recreate PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mongodb-data-mongodb-0
  namespace: prod
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: mongodb-ebs
  volumeName: ${PV_NAME}
EOF

# Scale up MongoDB StatefulSet
kubectl scale statefulset mongodb -n prod --replicas=1

# Wait for pod to be ready
kubectl wait --for=condition=ready pod/mongodb-0 -n prod --timeout=300s
```

#### 5.3 Verify Data Integrity

```bash
# Check MongoDB pod status
kubectl get pod mongodb-0 -n prod

# Test MongoDB connection
kubectl exec -it mongodb-0 -n prod -- mongosh --eval "
  db.adminCommand('ping')
"

# Check collections
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  db.getCollectionNames()
"

# Verify data counts
kubectl exec -it mongodb-0 -n prod -- mongosh eventsphere --eval "
  print('Users: ' + db.users.countDocuments());
  print('Events: ' + db.events.countDocuments());
  print('Bookings: ' + db.bookings.countDocuments());
"
```

---

## Secrets Backup and Recovery

### 1. AWS Secrets Manager Automatic Backups

AWS Secrets Manager automatically backs up secrets. No manual configuration needed.

### 2. Manual Secrets Export (for disaster recovery)

```bash
# Export MongoDB credentials
aws secretsmanager get-secret-value \
  --secret-id eventsphere/mongodb \
  --query SecretString \
  --output text > mongodb-secret-backup.json

# Export JWT secret
aws secretsmanager get-secret-value \
  --secret-id eventsphere/auth-service \
  --query SecretString \
  --output text > auth-secret-backup.json


# Store these files securely (encrypted storage, not in Git!)
# Recommended: Upload to encrypted S3 bucket with restricted access
aws s3 cp mongodb-secret-backup.json s3://eventsphere-secure-backups/ --sse AES256
aws s3 cp auth-secret-backup.json s3://eventsphere-secure-backups/ --sse AES256

# Clean up local copies
shred -u mongodb-secret-backup.json auth-secret-backup.json
```

### 3. Secrets Recovery

```bash
# Restore secrets to AWS Secrets Manager (if deleted)
aws secretsmanager create-secret \
  --name eventsphere/mongodb \
  --secret-string file://mongodb-secret-backup.json

aws secretsmanager create-secret \
  --name eventsphere/auth-service \
  --secret-string file://auth-secret-backup.json


# Trigger External Secrets Operator to sync
kubectl annotate externalsecret mongodb-secret -n prod \
  force-sync="$(date +%s)" --overwrite
```

---

## Backup Verification

### 1. Verify Velero Backups

```bash
# Check backup status
velero backup get

# Verify backup contents
velero backup describe <backup-name> --details

# Check for errors
velero backup logs <backup-name> | grep -i error

# Verify in S3
aws s3 ls s3://${BUCKET_NAME}/backups/<backup-name>/
```

### 2. Verify EBS Snapshots

```bash
# List recent snapshots
aws ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=tag:Project,Values=EventSphere" \
  --query 'Snapshots | sort_by(@, &StartTime) | [-5:].[SnapshotId,StartTime,State,Progress]' \
  --output table

# Verify snapshot completion
aws ec2 describe-snapshots \
  --snapshot-ids ${SNAPSHOT_ID} \
  --query 'Snapshots[0].[State,Progress]' \
  --output table
```

### 3. Test Restore (Recommended Monthly)

```bash
# Create test namespace
kubectl create namespace restore-test

# Restore latest backup to test namespace
LATEST_BACKUP=$(velero backup get --output json | jq -r '.items | sort_by(.status.startTimestamp) | last | .metadata.name')

velero restore create test-restore-$(date +%Y%m%d) \
  --from-backup ${LATEST_BACKUP} \
  --namespace-mappings prod:restore-test

# Verify restoration
kubectl get all -n restore-test

# Cleanup
kubectl delete namespace restore-test
```

---

## Troubleshooting

### Velero Backup Fails

**Problem**: Backup shows "PartiallyFailed" status

**Solution**:
```bash
# Check backup logs
velero backup logs <backup-name>

# Common issues:
# 1. Insufficient IAM permissions
aws iam get-role --role-name velero-backup-role

# 2. S3 bucket access issues
aws s3 ls s3://${BUCKET_NAME}/

# 3. Volume snapshot issues
kubectl get volumesnapshotclass
kubectl get volumesnapshot -A

# 4. Check Velero pod logs
kubectl logs -n velero deployment/velero
```

### EBS Snapshot Creation Fails

**Problem**: Snapshot stuck in "pending" state

**Solution**:
```bash
# Check snapshot status
aws ec2 describe-snapshots --snapshot-ids ${SNAPSHOT_ID}

# Check volume status
aws ec2 describe-volumes --volume-ids ${VOLUME_ID}

# If snapshot is stuck (>24 hours), delete and retry
aws ec2 delete-snapshot --snapshot-id ${SNAPSHOT_ID}

# Create new snapshot
aws ec2 create-snapshot --volume-id ${VOLUME_ID} --description "Retry backup"
```

### Restore Fails with "PV already bound"

**Problem**: Cannot restore PVC because PV is already claimed

**Solution**:
```bash
# Delete existing PVC
kubectl delete pvc <pvc-name> -n prod

# Delete PV (if safe to do so)
kubectl delete pv <pv-name>

# Retry restore
velero restore create --from-backup <backup-name>
```

### MongoDB Data Corruption After Restore

**Problem**: MongoDB reports data corruption

**Solution**:
```bash
# Connect to MongoDB
kubectl exec -it mongodb-0 -n prod -- mongosh

# Run repair
use admin
db.runCommand({repairDatabase: 1})

# If repair fails, restore from older backup
# Scale down MongoDB
kubectl scale statefulset mongodb -n prod --replicas=0

# Restore from previous snapshot (see EBS restore steps above)
```

---

## Related Documentation

- [Disaster Recovery Runbook](DISASTER_RECOVERY.md)
- [Deployment Guide](../../DEPLOYMENT.md)
- [Architecture Overview](../../ARCHITECTURE.md)
- [Velero Documentation](https://velero.io/docs/)
- [AWS Backup Documentation](https://docs.aws.amazon.com/aws-backup/)
- [EBS Snapshot Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EBSSnapshots.html)

---

**Last Updated**: 2025-01-12  
**Version**: 1.0  
**Maintained By**: EventSphere DevOps Team




