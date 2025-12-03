# Notification Service

The notification service handles email notifications for EventSphere using AWS SNS (Simple Notification Service).

## Features

- Welcome email notifications for new user registrations
- Booking confirmation emails for successful event bookings
- AWS SNS integration for reliable email delivery
- Non-blocking notification sending (doesn't fail parent operations)

## API Endpoints

### POST /api/notifications/welcome
Send welcome email to new user.

**Request Body:**
```json
{
  "email": "user@example.com",
  "userName": "John Doe"
}
```

**Response:**
```json
{
  "message": "Welcome email sent successfully",
  "email": "user@example.com"
}
```

### POST /api/notifications/booking-confirmation
Send booking confirmation email.

**Request Body:**
```json
{
  "email": "user@example.com",
  "userName": "John Doe",
  "eventDetails": {
    "title": "Tech Conference 2024",
    "date": "2024-12-15",
    "time": "10:00 AM",
    "venue": "Convention Center",
    "category": "Technology"
  },
  "bookingDetails": {
    "bookingId": "BK123456",
    "quantity": 2,
    "totalAmount": 100,
    "bookingDate": "2024-12-01T10:00:00Z"
  }
}
```

**Response:**
```json
{
  "message": "Booking confirmation email sent successfully",
  "email": "user@example.com",
  "bookingId": "BK123456"
}
```

### GET /health
Health check endpoint.

**Response:**
```json
{
  "status": "healthy",
  "service": "notification-service"
}
```

## Environment Variables

- `PORT` - Service port (default: 4004)
- `NODE_ENV` - Environment (development/production)
- `AWS_REGION` - AWS region for SNS (default: us-east-1)
- `SNS_TOPIC_ARN` - ARN of the SNS topic for notifications
- `AUTH_SERVICE_URL` - URL of auth service (for future auth integration)

## Local Development

1. Install dependencies:
```bash
npm install
```

2. Set up environment variables in `.env`:
```bash
PORT=4004
NODE_ENV=development
AWS_REGION=us-east-1
SNS_TOPIC_ARN=arn:aws:sns:us-east-1:123456789012:eventsphere-notifications
AUTH_SERVICE_URL=http://localhost:4001
```

3. Configure AWS credentials:
```bash
aws configure
```

4. Run in development mode:
```bash
npm run dev
```

5. Run in production mode:
```bash
npm start
```

## AWS SNS Setup

### Prerequisites
- AWS account with SNS access
- AWS CLI configured
- IAM permissions for SNS:Publish

### Setup Steps

1. Run the SNS setup script:
```bash
cd infrastructure/scripts
chmod +x setup-sns.sh
./setup-sns.sh
```

This script will:
- Create SNS topic `eventsphere-notifications`
- Prompt for email subscriptions
- Create IAM policy for notification service
- Store SNS Topic ARN in AWS Secrets Manager

2. Confirm email subscriptions:
- Check your email inbox for AWS SNS confirmation emails
- Click the confirmation link in each email

3. For Kubernetes deployment:
- The SNS Topic ARN is automatically injected via External Secrets Operator
- IAM role is attached to the service account for SNS access

## Integration with Other Services

### Auth Service
The auth-service calls the notification service after successful user registration:

```javascript
axios.post(`${NOTIFICATION_SERVICE_URL}/api/notifications/welcome`, {
  email: user.email,
  userName: user.name
}).catch(err => {
  console.error('Failed to send welcome email:', err.message);
});
```

### Booking Service
The booking-service calls the notification service after successful booking:

```javascript
axios.post(`${NOTIFICATION_SERVICE_URL}/api/notifications/booking-confirmation`, {
  email: req.user.email,
  userName: req.user.name,
  eventDetails: { ... },
  bookingDetails: { ... }
}).catch(err => {
  console.error('Failed to send booking confirmation email:', err.message);
});
```

## Docker

Build image:
```bash
docker build -t notification-service:latest .
```

Run container:
```bash
docker run -p 4004:4004 \
  -e AWS_REGION=us-east-1 \
  -e SNS_TOPIC_ARN=arn:aws:sns:... \
  notification-service:latest
```

## Kubernetes Deployment

The service is deployed with:
- 2 replicas (min) with HPA up to 10 replicas
- Service account with IAM role for SNS access
- Secret containing SNS Topic ARN from AWS Secrets Manager
- Health checks (liveness and readiness probes)

Deploy:
```bash
kubectl apply -f k8s/generated/base/notification-service-deployment.yaml
kubectl apply -f k8s/base/notification-service-service.yaml
kubectl apply -f k8s/hpa/notification-service-hpa.yaml
```

## Monitoring

Check service health:
```bash
curl http://localhost:4004/health
```

View logs:
```bash
# Local
npm run dev

# Kubernetes
kubectl logs -n prod -l app=notification-service -f
```

## Troubleshooting

### Email not received
1. Check SNS subscription is confirmed
2. Check spam/junk folder
3. Verify SNS Topic ARN is correct
4. Check AWS CloudWatch logs for SNS publish errors

### IAM permission errors
1. Verify IAM role has SNS:Publish permission
2. Check service account annotation with role ARN
3. Verify IRSA (IAM Roles for Service Accounts) is configured

### Service not starting
1. Check SNS_TOPIC_ARN environment variable is set
2. Verify AWS credentials are configured (local) or IAM role is attached (K8s)
3. Check service logs for errors

## Security

- Service uses IAM roles for AWS access (no hardcoded credentials)
- SNS Topic ARN stored in AWS Secrets Manager
- Email addresses are not logged or stored
- Non-root user in Docker container
- Read-only root filesystem (where possible)
- Least-privilege IAM policy (only SNS:Publish on specific topic)
