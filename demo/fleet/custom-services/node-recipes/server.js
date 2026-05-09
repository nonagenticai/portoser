// Tiny Express app — a "recipe sharing" service for the fleet demo.
// Picked to be visually distinctive in screenshots: returns JSON, a small
// HTML index, and Prometheus-format metrics.
const express = require('express');

const app = express();
const PORT = process.env.PORT || 3000;
const STARTED_AT = Date.now();

const recipes = [
  { id: 1, name: 'Sourdough loaf', minutes: 1440, host: process.env.HOSTNAME },
  { id: 2, name: 'Ramen broth',   minutes:  720, host: process.env.HOSTNAME },
  { id: 3, name: 'Pesto rosso',   minutes:   15, host: process.env.HOSTNAME },
  { id: 4, name: 'Cold-brew',     minutes:  720, host: process.env.HOSTNAME },
];

let requestsTotal = 0;
app.use((_req, _res, next) => { requestsTotal += 1; next(); });

app.get('/', (_req, res) => {
  res.type('html').send(`<!doctype html>
<title>node-recipes</title>
<h1>node-recipes</h1>
<p>Demo Node/Express service running on the portoser fleet.</p>
<ul>${recipes.map(r => `<li><b>${r.name}</b> — ${r.minutes} min</li>`).join('')}</ul>
<p><a href="/api/recipes">/api/recipes</a> · <a href="/health">/health</a> · <a href="/metrics">/metrics</a></p>`);
});

app.get('/api/recipes', (_req, res) => res.json(recipes));

app.get('/health', (_req, res) => res.json({ status: 'ok', uptime_s: Math.floor((Date.now() - STARTED_AT) / 1000) }));

app.get('/metrics', (_req, res) => {
  res.type('text/plain').send(
    `# HELP node_recipes_requests_total Requests served\n` +
    `# TYPE node_recipes_requests_total counter\n` +
    `node_recipes_requests_total ${requestsTotal}\n` +
    `# HELP node_recipes_uptime_seconds Process uptime\n` +
    `# TYPE node_recipes_uptime_seconds gauge\n` +
    `node_recipes_uptime_seconds ${Math.floor((Date.now() - STARTED_AT) / 1000)}\n`,
  );
});

app.listen(PORT, '0.0.0.0', () => console.log(`node-recipes listening on :${PORT}`));
