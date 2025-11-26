# EventSphere Architecture

## Overview

EventSphere is a cloud-native microservices application deployed on AWS EKS (Elastic Kubernetes Service). The system is designed for high availability, scalability, and security, following best practices for containerized microservices architecture.

## System Architecture

### High-Level Architecture

```
                    ┌─────────────────┐
                    │   Internet      │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │   AWS ALB       │
                    │  (HTTPS/TLS)    │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  Ingress        │
                    │  Controller    │
                    └────────┬────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                     │
┌───────▼────────┐  ┌────────▼────────┐  ┌────────▼────────┐
│   Frontend     │  │  Auth Service   │  │ Event Service   │
│   (React)      │  │  (Port 4001)    │  │  (Port 4002)    │
└────────────────┘  └─────────────────┘  └─────────────────┘
        │                    │                     │
        │                    ├─────────────────────┤
        │                    │                     │
        │            ┌───────▼────────┐            │
        │            │ Booking Service │            │
        │            │  (Port 4003)    │            │
        │            └───────┬─────────┘            │
        │                    │                     │
        └────────────────────┼─────────────────────┘
                             │
                    ┌────────▼────────┐
                    │    MongoDB      │
                    │  (StatefulSet)  │
                    └─────────────────┘
```

## Infrastructure Components

### AWS EKS Cluster

- **Cluster Name**: `eventsphere-cluster`
- **Kubernetes Version**: 1.34
- **Region**: us-east-1
- **Availability Zones**: us-east-1a, us-east-1b, us-east-1c

### VPC Configuration

- **CIDR**: 10.0.0.0/16
- **Subnets**: 
  - Public subnets in each AZ for ALB
  - Private subnets in each AZ for worker nodes
- **NAT Gateway**: Highly Available (one per AZ)

### Node Groups

1. **eventsphere-ng-1**
   - Instance Type: t3.medium
   - Desired Capacity: 2
   - Min Size: 2, Max Size: 5
   - Availability Zones: us-east-1a, us-east-1b

2. **eventsphere-ng-2**
   - Instance Type: t3.medium
   - Desired Capacity: 1
   - Min Size: 1, Max Size: 3
   - Availability Zones: us-east-1b, us-east-1c

### Storage

- **EBS CSI Driver**: For persistent volumes (MongoDB)
- **EFS CSI Driver**: Available for shared storage if needed
- **Storage Classes**: 
  - `mongodb-ebs`: GP3 encrypted volumes with retention policy

## Microservices

### 1. Frontend Service
- **Technology**: React with Nginx
- **Port**: 80
- **Replicas**: 2 (HPA: 2-8)
- **Purpose**: User interface for event management

### 2. Auth Service
- **Technology**: Node.js/Express
- **Port**: 4001
- **Replicas**: 2 (HPA: 2-10)
- **Purpose**: User authentication and authorization (JWT)

### 3. Event Service
- **Technology**: Node.js/Express
- **Port**: 4002
- **Replicas**: 2 (HPA: 2-10)
- **Purpose**: Event CRUD operations

### 4. Booking Service
- **Technology**: Node.js/Express
- **Port**: 4003
- **Replicas**: 2 (HPA: 2-10)
- **Purpose**: Ticket booking and reservation management

### 5. MongoDB
- **Technology**: MongoDB 7.0
- **Port**: 27017
- **Replicas**: 1 (StatefulSet)
- **Storage**: 20Gi EBS volume (encrypted)
- **Purpose**: Persistent data storage

## Networking

### Service Communication

- **Internal**: Services communicate via ClusterIP services using DNS names
  - Format: `<service-name>.<namespace>.svc.cluster.local`
- **External**: Access via AWS ALB Ingress Controller
  - Frontend: `https://enpm818rgroup7.work.gd`
  - APIs: `https://api.enpm818rgroup7.work.gd/api/*`

### Network Policies

Network policies enforce least-privilege communication:
- Frontend can only communicate with backend services
- Backend services can only communicate with MongoDB and required services
- MongoDB only accepts connections from backend services

## Load Balancing

### AWS Application Load Balancer (ALB)

- **Type**: Internet-facing
- **Scheme**: HTTPS (port 443) with HTTP redirect
- **SSL Certificate**: AWS Certificate Manager (ACM)
- **Health Checks**: Configured for all services
- **Path-based Routing**: 
  - `/` → Frontend
  - `/api/auth/*` → Auth Service
  - `/api/events/*` → Event Service
  - `/api/bookings/*` → Booking Service

## Scaling

### Horizontal Pod Autoscaling (HPA)

All services have HPA configured based on:
- CPU utilization (target: 70%)
- Memory utilization (target: 80%)
- Min replicas: 2
- Max replicas: 5-10 (service-dependent)

### Cluster Autoscaler

- Automatically scales node groups based on pod scheduling requirements
- Min nodes: 3, Max nodes: 8

## Observability

### Prometheus

- **Purpose**: Metrics collection and storage
- **Retention**: 30 days
- **Storage**: 50Gi persistent volume
- **Replicas**: 2 (high availability)

### Grafana

- **Purpose**: Metrics visualization and dashboards
- **Storage**: 10Gi persistent volume
- **Dashboards**: 
  - EventSphere Overview
  - Kubernetes Cluster Metrics

### CloudWatch

- **Purpose**: Log aggregation
- **Log Group**: `/aws/eks/eventsphere-cluster`
- **Agent**: Fluent Bit (DaemonSet)
- **Retention**: 7 days

### Alertmanager

- **Purpose**: Alert routing and notification
- **Receivers**: Default, Critical, Warning
- **Integration**: SNS for notifications

## Security

### Pod Security

- **Standards**: Restricted baseline enforced
- **Non-root**: All containers run as non-root users
- **Read-only**: Frontend uses read-only root filesystem
- **Capabilities**: All unnecessary capabilities dropped

### Secrets Management

- **External Secrets Operator**: Integrates with AWS Secrets Manager
- **Secrets Stored**:
  - MongoDB credentials
  - JWT secret
  - SNS Topic ARNs

### Network Security

- **Network Policies**: Enforce service isolation
- **Security Groups**: Least-privilege access
- **TLS**: All external traffic encrypted

### AWS Security Services

- **GuardDuty**: Threat detection enabled
- **Security Hub**: Security findings aggregation
- **EKS Control Plane Logging**: All components enabled
- **Image Scanning**: ECR automatic scanning

## CI/CD Pipeline

### GitHub Actions Workflows

**Execution Order:** Security Scan → Build → Deploy Test

1. **Security Scan Workflow** (`security-scan.yml`) - **Runs First**
   - Runs on every push and pull request to main branch
   - Filesystem scans with Trivy (scans source code)
   - Kubernetes manifest and Dockerfile scans with Trivy
   - Infrastructure scans with Checkov (CloudFormation, Terraform, Kubernetes)
   - Fails on critical vulnerabilities (fail-fast principle)
   - Uploads results to GitHub Security tab
   - **Must pass before build workflow runs**
   - **Note**: RBAC files (`k8s/base/rbac.yaml`) are excluded from scanning
     - These roles are intentionally permissive for class project demonstration
     - They demonstrate RBAC concepts (admin, developer, operator roles)
     - In production, these should follow principle of least privilege

2. **Build Workflow** (`build.yml`) - **Runs After Security Scan**
   - Builds Docker images for all services (auth, event, booking, frontend)
   - Runs Trivy security scans on all built images
   - Pushes to GitHub Container Registry (GHCR) - free, no AWS required
   - Path filtered - only runs when relevant code changes (services/, frontend/, workflow files)
   - Runs automatically after security scan passes

3. **Test Deployment Workflow** (`deploy-test.yml`) - **Primary CI/CD Deployment**
   - Automatically runs after successful builds
   - Uses kind (Kubernetes in Docker) to create temporary cluster
   - Pulls images from GHCR and loads into kind cluster
   - Processes Kubernetes templates
   - Deploys all services to kind cluster
   - Validates deployments and runs health checks
   - Automatically tears down cluster after testing
   - **Cost: $0** - No AWS required

4. **Production Deploy Workflow** (`deploy.yml` - Manual Only)
   - Manual trigger only (not in automatic pipeline)
   - For production EKS deployment demonstration
   - Processes Kubernetes templates with AWS-specific variables
   - Supports both GHCR and ECR image registries
   - Deploys to EKS cluster
   - Updates image tags and applies manifests
   - Waits for deployments to be ready
   - Automatic rollback on failure
   - **Requires AWS infrastructure** (EKS cluster)

## Data Flow

### User Registration Flow

1. User submits registration → Frontend
2. Frontend → Auth Service (`POST /api/auth/register`)
3. Auth Service validates and creates user in MongoDB
4. Auth Service returns JWT token
5. Frontend stores token and redirects user

### Event Booking Flow

1. User selects event → Frontend
2. Frontend → Booking Service (`POST /api/bookings`)
3. Booking Service validates with Auth Service (JWT)
4. Booking Service checks availability with Event Service
5. Booking Service creates booking in MongoDB
6. Booking Service updates event capacity via Event Service
7. Booking confirmation is returned to user

## Disaster Recovery

### Backup Strategy

- **MongoDB**: EBS snapshots (automated via Velero or manual)
- **Secrets**: Stored in AWS Secrets Manager (automatically backed up)
- **Configuration**: Version controlled in Git

### Recovery Procedures

1. Restore MongoDB from EBS snapshot
2. Restore secrets from AWS Secrets Manager
3. Redeploy applications from Git
4. Verify service health and connectivity

## Cost Optimization

- **Node Types**: t3.medium (cost-effective)
- **Auto-scaling**: Reduces costs during low traffic
- **Storage**: GP3 volumes (cheaper than GP2)
- **Log Retention**: 7 days (CloudWatch), 30 days (Prometheus)

## Future Enhancements

- Service Mesh (Istio or AWS App Mesh) for mTLS
- Multi-region deployment for disaster recovery
- Redis cache for session management
- CDN for frontend static assets
- Database read replicas for improved performance




