/**
 * Prometheus Metrics Middleware for Express
 * Exposes HTTP request metrics for latency and error rate monitoring
 */
const client = require('prom-client');

// Create a Registry to register the metrics
const register = new client.Registry();

// Add default labels
register.setDefaultLabels({
    service: 'booking-service'
});

// Collect default metrics (CPU, memory, etc.)
client.collectDefaultMetrics({ register });

// HTTP Request Duration Histogram
const httpRequestDuration = new client.Histogram({
    name: 'http_request_duration_seconds',
    help: 'Duration of HTTP requests in seconds',
    labelNames: ['method', 'route', 'status'],
    buckets: [0.001, 0.005, 0.015, 0.05, 0.1, 0.2, 0.5, 1, 2, 5]
});
register.registerMetric(httpRequestDuration);

// HTTP Request Counter
const httpRequestsTotal = new client.Counter({
    name: 'http_requests_total',
    help: 'Total number of HTTP requests',
    labelNames: ['method', 'route', 'status']
});
register.registerMetric(httpRequestsTotal);

/**
 * Middleware to track request metrics
 */
const metricsMiddleware = (req, res, next) => {
    const start = process.hrtime.bigint();

    res.on('finish', () => {
        const end = process.hrtime.bigint();
        const durationInSeconds = Number(end - start) / 1e9;

        // Normalize route to avoid high cardinality
        const route = req.route?.path || req.path || 'unknown';
        const normalizedRoute = route.replace(/\/[a-f0-9]{24}/gi, '/:id');

        const labels = {
            method: req.method,
            route: normalizedRoute,
            status: res.statusCode.toString()
        };

        httpRequestDuration.observe(labels, durationInSeconds);
        httpRequestsTotal.inc(labels);
    });

    next();
};

/**
 * Handler for /metrics endpoint
 */
const metricsHandler = async (req, res) => {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
};

module.exports = {
    metricsMiddleware,
    metricsHandler,
    register
};
