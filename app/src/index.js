const express = require('express');

const app = express();
const port = process.env.PORT || 8080;

let ready = false;

app.get('/', (_req, res) => {
  res.json({
    app: 'myapp',
    version: process.env.APP_VERSION || 'dev',
    node: process.version,
  });
});

app.get('/healthz', (_req, res) => {
  res.status(200).json({ status: 'ok' });
});

app.get('/readyz', (_req, res) => {
  if (!ready) return res.status(503).json({ status: 'starting' });
  res.status(200).json({ status: 'ready' });
});

const server = app.listen(port, () => {
  ready = true;
  console.log(`myapp listening on :${port}`);
});

const shutdown = (signal) => {
  console.log(`received ${signal}, shutting down`);
  ready = false;
  server.close(() => process.exit(0));
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
