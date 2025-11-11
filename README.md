# EventSphere

EventSphere is a Campus Event Management is a microservice-based event management platform that can now be developed and run entirely with local tooling. The repository contains the backend services, a React frontend, and shared application code.
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
campus-event-management/
├── frontend/
├── services/
│   ├── auth-service/
│   ├── booking-service/
│   └── event-service/
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

## Contributing
With the infrastructure and container tooling removed, contributions can focus purely on application code. Please open an issue or submit a pull request describing any fixes or enhancements.
