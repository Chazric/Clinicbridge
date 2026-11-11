import express from 'express';
import { HttpError, MAX_SEATS, PLANS, TRIAL_DAYS } from './billing.js';
import { cancelPage, donePage, errorPage, managePage, pricingPage } from './pages.js';

export function buildApp({ billing, log = console, rateLimit = 30, rateWindowMs = 60_000 }) {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 1);
  app.use((_req, res, next) => {
    res.set('X-Content-Type-Options', 'nosniff');
    res.set('Referrer-Policy', 'no-referrer');
    res.set('X-Frame-Options', 'DENY');
    next();
  });
  app.use(express.json({ limit: '4kb' }));

  const hits = new Map();
  app.use('/v1/billing', (req, res, next) => {
    if (req.method !== 'POST') return next();
    const now = Date.now();
    const key = req.ip ?? 'unknown';
    const h = hits.get(key);
    if (!h || now - h.start > rateWindowMs) hits.set(key, { start: now, n: 1 });
    else if (++h.n > rateLimit) return res.status(429).json({ error: 'too many requests' });
    if (hits.size > 10000) for (const [k, v] of hits) if (now - v.start > rateWindowMs) hits.delete(k);
    next();
  });

  const wrap = (fn) => async (req, res, next) => { try { res.json(await fn(req.body ?? {})); } catch (e) { next(e); } };

  app.get('/healthz', (_req, res) => res.json({ ok: true }));
  app.get('/', (_req, res) => res.type('html').send(pricingPage()));
  app.get('/manage', (_req, res) => res.type('html').send(managePage()));
  app.get('/v1/billing/config', (_req, res) => res.json({ plans: PLANS, trial_days: TRIAL_DAYS, max_seats: MAX_SEATS }));
  app.post('/v1/billing/checkout', wrap((b) => billing.checkout(b)));
  app.post('/v1/billing/activate', wrap((b) => billing.activate(b)));
  app.post('/v1/billing/deactivate', wrap((b) => billing.deactivate(b)));
  app.post('/v1/billing/portal', wrap((b) => billing.portal(b)));
  app.get('/billing/done', async (req, res) => {
    res.set('Cache-Control', 'no-store');
    try {
      const { key, email } = await billing.keyForSession(req.query.session_id);
      res.type('html').send(donePage(key, email));
    } catch (e) {
      if (!(e instanceof HttpError)) log.error('done page error', e?.message ?? e);
      res.status(e instanceof HttpError ? e.status : 500).type('html').send(errorPage(e instanceof HttpError ? e.message : 'billing service error'));
    }
  });
  app.get('/billing/cancel', (_req, res) => res.type('html').send(cancelPage()));

  app.use((err, _req, res, _next) => {
    if (err instanceof HttpError) return res.status(err.status).json({ error: err.message });
    if (err?.type === 'entity.parse.failed') return res.status(400).json({ error: 'invalid JSON' });
    log.error('billing error', err?.type ?? '', err?.code ?? '', err?.message ?? err);
    res.status(err?.type === 'StripePermissionError' ? 502 : 500).json({ error: 'billing service error' });
  });
  return app;
}
