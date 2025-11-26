# Multi-stage build for optimized production image
FROM node:18-alpine AS build

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm install

# Copy source code
COPY . .

# Build the application
RUN npm run build

# Production stage with Nginx
FROM nginx:alpine AS production

# Update libxml2 to fix security vulnerabilities (CVE-2025-49794, CVE-2025-49796)
# Only upgrade libxml2 specifically to minimize risk of breaking changes
RUN apk update && apk upgrade libxml2 && rm -rf /var/cache/apk/*

# Create non-root user (nginx user already exists in nginx:alpine)
# nginx:alpine runs as nginx user by default, but we'll ensure proper permissions

# Copy built files from build stage
COPY --from=build --chown=nginx:nginx /app/build /usr/share/nginx/html

# Remove default nginx config if it exists, then copy our config
RUN rm -f /etc/nginx/conf.d/default.conf

# Copy nginx configuration
COPY --chown=nginx:nginx nginx.conf /etc/nginx/conf.d/default.conf

# Create health check script
RUN echo '#!/bin/sh' > /usr/local/bin/healthcheck.sh && \
    echo 'wget --quiet --tries=1 --spider http://localhost/ || exit 1' >> /usr/local/bin/healthcheck.sh && \
    chmod +x /usr/local/bin/healthcheck.sh && \
    chown nginx:nginx /usr/local/bin/healthcheck.sh

# Note: nginx needs to run as root to bind to port 80
# In Kubernetes, we can use non-root with securityContext, but for Docker we keep root
# Expose port
EXPOSE 80

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://localhost/ || exit 1

# Start nginx
CMD ["nginx", "-g", "daemon off;"]