# EventSphere

EventSphere is a microservice-based event management platform. The repository contains the backend services, a React frontend, and shared application code.
<img width="2557" height="1266" alt="image" src="https://github.com/user-attachments/assets/2879f378-bc57-4968-a198-7bd4bf08bcbf" />



## Features
- User authentication with JWT-based sessions
- Event browsing, search, and category filtering
- Ticket booking workflow with simulated payments
- Booking management including history and cancellations
- Administrative tooling for event creation and analytics

## Service Overview
The system is composed of the following independently running services:
- **Auth Service** (port 4001) – manages user accounts and tokens
- **Event Service** (port 4002) – handles CRUD operations for events
- **Booking Service** (port 4003) – coordinates ticket reservations
- **Frontend** (port 3000) – React single-page application that consumes the APIs above

All services communicate over HTTP and store data in MongoDB. Ensure that a MongoDB instance is running locally and that each service's `.env` file points to it.

> ℹ️ Ready-to-use `.env` files are committed with non-sensitive development defaults (local MongoDB URLs, service ports, and JWT secret). You can start the stack immediately and tailor the values later if needed.

## Project Structure
```
EventSphere/
├── frontend/                    # React frontend application
├── services/                    # Microservices
│   ├── auth-service/
│   ├── event-service/
│   └── booking-service/
├── k8s/                         # Kubernetes manifests
│   ├── base/                    # Base configurations
│   ├── mongodb/                 # MongoDB StatefulSet
│   ├── ingress/                 # ALB Ingress config
│   ├── security/                # Security policies
│   ├── hpa/                     # Horizontal Pod Autoscaling
│   └── overlays/                # Environment-specific configs
├── infrastructure/              # Infrastructure as Code
│   ├── eksctl-cluster.yaml      # EKS cluster config
│   └── scripts/                 # Setup/teardown scripts
├── monitoring/                  # Observability configs
│   ├── prometheus/              # Prometheus setup
│   ├── grafana/                 # Grafana dashboards
│   └── cloudwatch/              # CloudWatch logging
├── .github/                     # CI/CD workflows
│   └── workflows/               # GitHub Actions
│       ├── security-scan.yml    # Security scanning workflow
│       ├── build.yml            # Build and push Docker images
│       ├── deploy-test.yml      # Deploy to Staging (kind cluster)
│       └── deploy.yml           # Deploy to Production (EKS)
└── README.md
```

## Getting Started
### Prerequisites
- Node.js 25.1.0 or later
- npm (ships with Node.js)
- MongoDB running locally on the default port or accessible connection string

### Install Dependencies
Install dependencies for each service and the frontend:
```bash
cd services/auth-service; npm install
cd ../event-service; npm install
cd ../booking-service; npm install
cd ../../frontend; npm install
```

### Run the Backend Services
Each backend service exposes an npm script for development mode with automatic reloads. Run each one in a separate terminal window:
```bash
cd services/auth-service; npm run dev
cd services/event-service; npm run dev
cd services/booking-service; npm run dev
```

### Run the Frontend
```bash
cd frontend
npm start
```
The React development server will proxy API requests to the backend services when they are running on the ports listed above.

## Using EventSphere

### Account types and sign-in flow
- **Attendee accounts** are created through the public registration form available from the navbar. Newly registered users default to the `user` role and can browse events, reserve seats, and review their bookings.
- **Administrator accounts** can create, edit, and delete events. Because the public registration screen hides administrative privileges, you must explicitly set the `role` field when creating an admin profile.

### Creating an administrator
1. Start the authentication service and connect to the MongoDB instance defined in `services/auth-service/.env`.
2. Issue a POST request directly to the auth-service endpoint and include `"role": "admin"` in the payload. Example using `curl` while the auth service is running on port 4001:
   ```bash
   curl -X POST http://localhost:4001/api/auth/register \
     -H "Content-Type: application/json" \
     -d '{
       "name": "Event Manager",
       "email": "admin@example.com",
       "password": "supersecure",
       "role": "admin"
     }'
   ```
3. The response contains a JWT and the user object. Store the token (the frontend writes it to `localStorage`) and log in through the UI using the same credentials.

> ℹ️ Already registered users can also be promoted by updating the `role` field to `admin` directly in MongoDB.

### Managing events as an admin
1. Log in with an administrator account. The navbar reveals a **Manage Events** link that routes to `/admin/events`.
2. Use the **Create Event** button to open the event form. Fill in title, description, category, venue, date, time, capacity, price, organizer, and an optional image URL.
3. Submit the form to persist the event through the event-service (`POST /api/events`). A success toast appears and the events table refreshes with the new entry.
4. Use the table's **Delete** button to remove events (`DELETE /api/events/:id`).

### Booking events as an attendee
1. Register or log in from the navbar.
2. Browse events on the home page. Filters, search, and sorting options are available in the event list.
3. Open an event to view details and reserve seats. Confirming a booking updates seat availability through the booking-service and event-service coordination.
4. Access **My Bookings** from the navbar to review reservations and cancel if supported.

### Tips for operators
- Event capacity and availability are enforced by the event-service middleware, so bookings will fail gracefully when seats run out.
- All admin-only endpoints validate JWTs and roles via the auth-service. Ensure you include the `Authorization: Bearer <token>` header when calling backend APIs directly.

## Environment Configuration
Each service directory and the frontend already include a committed `.env` file configured for local development. Key variables you can tweak are:
- `MONGO_URI` – MongoDB connection string
- `JWT_SECRET` – secret for signing auth tokens (auth service)
- `PORT` – optional override for default ports listed above
- `AUTH_SERVICE_URL` / `EVENT_SERVICE_URL` – internal service discovery URLs

The frontend `.env` exposes `REACT_APP_AUTH_API_URL`, `REACT_APP_EVENT_API_URL`, and `REACT_APP_BOOKING_API_URL`. Adjust these if your backend runs on different hosts or ports.

## Testing
Each service currently includes placeholder npm test scripts. Extend these as needed and run them with `npm test` from the respective service directory.

## CI/CD Pipeline

EventSphere includes automated CI/CD workflows using GitHub Actions following industry-standard practices. The pipeline provides security scanning, automated builds, staging validation, and production deployment.

### Pipeline Flow

#### On Pull Requests (Continuous Integration)
```
Security Scan → Build → Deploy to Staging
```
- Validates code quality and security
- Builds and tests Docker images
- Tests deployment in staging environment (kind cluster)

#### On Main Branch (Continuous Deployment)
```
Security Scan → Build → Deploy to Staging → Deploy to Production
```
- Full validation pipeline
- Automatic deployment to production EKS after staging succeeds
- Production deployment only runs on main branch

### Available Workflows

1. **Security Scan** (`security-scan.yml`)
   - **Runs first** - Must pass before build workflow runs
   - Runs on every push and pull request
   - Scans filesystem, Kubernetes manifests, Dockerfiles, and infrastructure
   - Fails on critical vulnerabilities to block unsafe code
   - Results appear in GitHub Security tab
   - **Best Practice**: Catches security issues early, prevents building vulnerable images
   - **Note**: RBAC files are excluded from scanning (intentionally permissive roles for class project demonstration)

2. **Build and Push** (`build.yml`)
   - **Runs after security scan passes** - Only builds if code is secure
   - **Path filtered** - Only runs when code in `services/`, `frontend/`, or workflow files change
   - Builds Docker images for all 4 services (auth, event, booking, frontend)
   - **Dual Registry Support**:
     - **GHCR (GitHub Container Registry)**: Always pushes - required for all deployments
     - **ECR (Amazon ECR)**: Optional - pushes if `AWS_ROLE_ARN` secret is configured
     - Build never fails if ECR is unavailable (graceful degradation)
   - On PRs: Tags images as `pr-{number}`
   - On main: Tags images as `latest`
   - Runs security scans on built images (Trivy)

3. **Deploy to Staging** (`deploy-test.yml`) - **FREE, No AWS Required!**
   - **Runs automatically after successful builds**
   - Uses kind (Kubernetes in Docker) to create temporary staging cluster
   - Validates Kubernetes manifests, deploys services, runs health checks
   - Tests deployment structure and service startup
   - Automatically tears down cluster after testing
   - **Cost: $0** - Meets CI/CD deployment requirement without AWS costs
   - **Purpose**: Staging environment validation before production

4. **Deploy to Production** (`deploy.yml`) - **EKS Production Deployment**
   - **Runs automatically on main branch** after staging deployment succeeds
   - Can also be triggered manually for other environments (staging, dev)
   - Deploys to AWS EKS production cluster
   - Processes Kubernetes templates, updates image tags, applies manifests
   - Includes automatic rollback on failure
   - **Requires AWS infrastructure** (EKS cluster)
   - **Safety**: Only auto-deploys after staging validation passes

### Pipeline Flow Diagram

#### Pull Request Flow (CI)
```
┌─────────────┐
│  Code Push  │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│Security Scan│ ◄─── Must pass (blocks if fails)
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ Build & Push│ ◄─── Pushes to GHCR (always)
│             │      Optionally pushes to ECR
│ pr-{number} │      (won't fail if ECR unavailable)
└──────┬──────┘
       │
       ▼
┌─────────────┐
│Deploy Stage │ ◄─── Tests in kind cluster
│  (kind)     │      Validates deployment
└─────────────┘
```

#### Main Branch Flow (CD)
```
┌─────────────┐
│Merge to Main│
└──────┬──────┘
       │
       ▼
┌─────────────┐
│Security Scan│
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ Build & Push│ ◄─── Pushes to GHCR + ECR (if configured)
│             │
│   latest    │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│Deploy Stage │ ◄─── Final validation
│  (kind)     │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│Deploy Prod  │ ◄─── AUTO-DEPLOYS to EKS!
│   (EKS)     │      Only if staging succeeds
└─────────────┘
```

### Image Registry Strategy

- **GHCR (GitHub Container Registry)**: 
  - ✅ Always used - required for all deployments
  - ✅ Free - no AWS costs
  - ✅ Works for staging and production
  
- **ECR (Amazon ECR)**: 
  - ⚙️ Optional - only if `AWS_ROLE_ARN` secret is configured
  - ⚙️ Won't fail build if unavailable
  - ⚙️ Useful for production deployments preferring ECR
  - ⚙️ Requires AWS infrastructure setup

### Quick Start - CI/CD

**On Pull Requests:**
```bash
# Create a PR - the following runs automatically:
# 1. Security Scan → validates code security
# 2. Build → builds and pushes images to GHCR (tagged as pr-{number})
#           Optionally pushes to ECR if configured
# 3. Deploy to Staging → tests deployment in kind cluster
# All checks must pass before PR can be merged
```

**On Main Branch (Automatic Production Deployment):**
```bash
# Merge PR to main - the following runs automatically:
# 1. Security Scan → validates code security
# 2. Build → builds and pushes images to GHCR + ECR (tagged as latest)
# 3. Deploy to Staging → final validation in kind cluster
# 4. Deploy to Production → automatic deployment to EKS (if staging succeeds)
```

**Manual Production Deployment:**
```bash
# For other environments or manual triggers:
# Actions tab → "Deploy to Production (EKS)" → Run workflow
# Select environment: prod, staging, or dev
# Requires: AWS infrastructure (EKS cluster) to be provisioned first
```

**View Your Images:**
- Go to GitHub repo → **Packages** (right sidebar)

## Cloud Deployment (AWS EKS)

EventSphere is designed for production deployment on AWS EKS with full observability, security, and CI/CD integration.

### Quick Start - EKS Deployment

1. **Prerequisites**: AWS CLI, eksctl, kubectl, helm
2. **Create Cluster**: See [DEPLOYMENT.md](DEPLOYMENT.md) for detailed instructions
   ```bash
   cd infrastructure/scripts
   ./setup-eks.sh
   ```
3. **Deploy Services**: Follow the deployment guide in [DEPLOYMENT.md](DEPLOYMENT.md)

### Key Features

- **Infrastructure**: EKS cluster with 3+ nodes across 2+ availability zones
- **Load Balancing**: AWS ALB with HTTPS/TLS termination
- **Auto-scaling**: HPA for pods, Cluster Autoscaler for nodes
- **Monitoring**: Prometheus, Grafana, and CloudWatch integration
- **Security**: GuardDuty, Security Hub, Network Policies, Pod Security Standards
- **CI/CD**: GitHub Actions workflows for security scanning, automated builds (GHCR), and EKS deployments
- **Secrets Management**: External Secrets Operator with AWS Secrets Manager

### Documentation

- **[ARCHITECTURE.md](ARCHITECTURE.md)**: System architecture and design
- **[DEPLOYMENT.md](DEPLOYMENT.md)**: Step-by-step deployment guide
- **[SECURITY.md](SECURITY.md)**: Security measures and compliance
- **[CONTRIBUTING.md](CONTRIBUTING.md)**: Contribution guidelines

### Operational Runbooks

Comprehensive runbooks for operational procedures:

- **[Backup and Restore](docs/runbooks/BACKUP_RESTORE.md)**: Velero and manual EBS backup/restore procedures
- **[Disaster Recovery](docs/runbooks/DISASTER_RECOVERY.md)**: Complete cluster recovery procedures
- **[Security Incident Response](docs/runbooks/SECURITY_INCIDENT_RESPONSE.md)**: Incident classification and response
- **[Deployment and Rollback](docs/runbooks/DEPLOYMENT_ROLLBACK.md)**: Deployment strategies and rollback procedures
- **[Troubleshooting](docs/runbooks/TROUBLESHOOTING.md)**: Common issues and diagnostic procedures
- **[Maintenance](docs/runbooks/MAINTENANCE.md)**: Regular maintenance tasks and schedules
- **[Alert Handling](monitoring/alertmanager/runbook.md)**: Prometheus alert response procedures

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. For security issues, please email security@enpm818rgroup7.work.gd instead of creating a public issue.
