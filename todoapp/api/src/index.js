const express = require('express');
const { CosmosClient } = require('@azure/cosmos');
const { DefaultAzureCredential } = require('@azure/identity');
const { randomUUID } = require('crypto');

const PORT      = process.env.PORT || 8080;
const ENDPOINT  = required('COSMOS_ENDPOINT');
const DATABASE  = required('COSMOS_DATABASE');
const CONTAINER = required('COSMOS_CONTAINER');

function required(name) {
  const v = process.env[name];
  if (!v) { console.error(`missing env ${name}`); process.exit(1); }
  return v;
}

// DefaultAzureCredential picks up AZURE_CLIENT_ID + AZURE_TENANT_ID +
// AZURE_FEDERATED_TOKEN_FILE that the Azure Workload Identity webhook injects.
const credential = new DefaultAzureCredential();
const cosmos     = new CosmosClient({ endpoint: ENDPOINT, aadCredentials: credential });
const container  = cosmos.database(DATABASE).container(CONTAINER);

const app = express();
app.use(express.json({ limit: '64kb' }));

let ready = false;

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));
app.get('/readyz',  (_req, res) => ready ? res.json({ status: 'ready' }) : res.status(503).json({ status: 'starting' }));

app.get('/api/todos', async (_req, res, next) => {
  try {
    const { resources } = await container.items
      .query('SELECT c.id, c.text, c.done, c.createdAt FROM c ORDER BY c.createdAt DESC')
      .fetchAll();
    res.json(resources);
  } catch (e) { next(e); }
});

app.post('/api/todos', async (req, res, next) => {
  try {
    const text = (req.body?.text || '').trim();
    if (!text)                  return res.status(400).json({ error: 'text is required' });
    if (text.length > 280)      return res.status(400).json({ error: 'text too long (max 280)' });
    const item = { id: randomUUID(), text, done: false, createdAt: new Date().toISOString() };
    await container.items.create(item);
    res.status(201).json(item);
  } catch (e) { next(e); }
});

app.patch('/api/todos/:id', async (req, res, next) => {
  try {
    const { id } = req.params;
    const { resource: existing } = await container.item(id, id).read();
    if (!existing) return res.status(404).json({ error: 'not found' });
    const updated = { ...existing, done: !!req.body?.done };
    await container.item(id, id).replace(updated);
    res.json(updated);
  } catch (e) { next(e); }
});

app.delete('/api/todos/:id', async (req, res, next) => {
  try {
    await container.item(req.params.id, req.params.id).delete();
    res.status(204).end();
  } catch (e) {
    if (e.code === 404) return res.status(404).json({ error: 'not found' });
    next(e);
  }
});

app.use((err, _req, res, _next) => {
  console.error(err);
  res.status(500).json({ error: 'internal_error' });
});

const server = app.listen(PORT, async () => {
  try {
    // Probe Cosmos so /readyz only flips after the SDK is warm + auth has worked once.
    await container.items.query('SELECT VALUE COUNT(1) FROM c').fetchAll();
    ready = true;
    console.log(`todoapi listening on :${PORT}`);
  } catch (e) {
    console.error('cosmos probe failed:', e.message);
  }
});

const shutdown = (sig) => { ready = false; server.close(() => process.exit(0)); console.log(`got ${sig}`); };
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));
