# Build stage
FROM node:25.1.0-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm install --omit=dev

# Production stage
FROM node:25.1.0-alpine

WORKDIR /app

COPY --from=builder /app/node_modules ./node_modules
COPY . .

USER node

EXPOSE 4004

CMD ["node", "src/server.js"]
