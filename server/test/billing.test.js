import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { accountHash, computeLicence, createBilling, HttpError, licenceKeyFor, validKey } from '../src/billing.js';
import { createSigner, generateKeyPair } from '../src/sign.js';
import { buildApp } from '../src/app.js';

const DAY = 86400000;
const NOW = Date.parse('2026-11-09T12:00:00Z');
const sec = (ms) => Math.floor(ms / 1000);
const DEV = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const signer = createSigner(generateKeyPair().privateKeyB64);

function iter(items) { return { async *[Symbol.asyncIterator]() { yield* items; } }; }

function fakeStripe() {
  const st = { customers: [], subs: [], created: [], sessions: {} };
  return {
    st,
    customers: {
      search: async ({ query }) => ({ data: st.customers.filter((c) => c.metadata.cb_account && query.includes(c.metadata.cb_account)) }),
      create: async (p) => { const c = { id: 'cus_T' + st.customers.length + 'abcdef', email: p.email, metadata: { ...p.metadata } }; st.customers.push(c); return c; },
      update: async (id, p) => { const c = st.customers.find((x) => x.id === id); c.metadata = { ...c.metadata, ...p.metadata }; return c; },
    },
    checkout: { sessions: {
      create: async (p) => { st.created.push(p); return { id: 'cs_test_1', url: 'https://checkout.stripe.com/c/pay/cs_test_1' }; },
      retrieve: async (id) => st.sessions[id] ?? (() => { throw Object.assign(new Error('nf'), { statusCode: 404 }); })(),
    } },
    subscriptions: { list: ({ customer }) => iter(st.subs.filter((s) => s.customer === customer)) },
    billingPortal: { sessions: { create: async () => ({ url: 'https://billing.stripe.com/p/session/x' }) } },
  };
}

const sub = (customer, extra = {}) => ({
  customer, status: 'active', current_period_end: sec(NOW + 20 * DAY),
  items: { data: [{ quantity: 2 }] }, metadata: { cb_plan: 'monthly' }, ...extra,
});

async function purchased(seats = 2, extra = {}) {
  const stripe = fakeStripe();
  const billing = createBilling({ stripe, baseUrl: 'https://cb.example', signer, now: () => NOW });
  await billing.checkout({ plan: 'monthly', seats: String(seats), email: 'admin@clinic.example' });
  const c = stripe.st.customers[0];
  stripe.st.subs.push(sub(c.id, { items: { data: [{ quantity: seats }] }, ...extra }));
  return { stripe, billing, key: licenceKeyFor(c.id, signer), c };
}

test('inactive with no live subscription; canceled and expired ignored', () => {
  assert.deepEqual(computeLicence({ subs: [], nowMs: NOW }), { status: 'inactive', plan: null, seats: 0, expires_at: null });
  const subs = [sub('c', { status: 'canceled' }), sub('c', { current_period_end: sec(NOW - 5 * DAY) })];
  assert.equal(computeLicence({ subs, nowMs: NOW }).status, 'inactive');
});

test('seats sum across live subscriptions, trial ends at trial_end plus grace', () => {
  const end = sec(NOW + 14 * DAY);
  const l = computeLicence({ subs: [sub('c'), sub('c', { status: 'trialing', trial_end: end, metadata: { cb_plan: 'annual' } })], nowMs: NOW });
  assert.equal(l.seats, 4);
  assert.equal(l.status, 'trialing');
  assert.equal(l.plan, 'annual');
  assert.equal(l.expires_at, new Date(sec(NOW + 20 * DAY) * 1000 + 3 * DAY).toISOString());
  assert.equal(computeLicence({ subs: [sub('c', { status: 'past_due' })], nowMs: NOW }).status, 'active');
  assert.equal(computeLicence({ subs: [sub('c', { metadata: { cb_plan: 'other' } })], nowMs: NOW }).status, 'inactive');
});

test('licence keys are stable, well-formed and differ per customer', () => {
  const a = licenceKeyFor('cus_A', signer);
  assert.ok(validKey(a), a);
  assert.equal(a, licenceKeyFor('cus_A', signer));
  assert.notEqual(a, licenceKeyFor('cus_B', signer));
  assert.notEqual(a, licenceKeyFor('cus_A', createSigner(generateKeyPair().privateKeyB64)));
});

test('checkout creates a 14-day trial subscription with seat quantity and stores only the key hash', async () => {
  const stripe = fakeStripe();
  const billing = createBilling({ stripe, baseUrl: 'https://cb.example', signer, now: () => NOW });
  const r = await billing.checkout({ plan: 'annual', seats: 3, email: 'a@b.co' });
  assert.match(r.url, /^https:\/\/checkout\.stripe\.com\//);
  const p = stripe.st.created[0];
  assert.equal(p.mode, 'subscription');
  assert.equal(p.line_items[0].quantity, 3);
  assert.equal(p.line_items[0].price_data.unit_amount, 49000);
  assert.equal(p.line_items[0].price_data.recurring.interval, 'year');
  assert.equal(p.subscription_data.trial_period_days, 14);
  assert.equal(p.subscription_data.metadata.cb_plan, 'annual');
  const c = stripe.st.customers[0];
  assert.equal(c.metadata.cb_account, accountHash(licenceKeyFor(c.id, signer)));
  assert.ok(!JSON.stringify(c.metadata).includes(licenceKeyFor(c.id, signer)));
  for (const bad of [{ plan: 'x', seats: 1, email: 'a@b.co' }, { plan: 'monthly', seats: 0, email: 'a@b.co' }, { plan: 'monthly', seats: 26, email: 'a@b.co' }, { plan: 'monthly', seats: 1, email: 'nope' }]) {
    await assert.rejects(billing.checkout(bad), HttpError);
  }
});

test('activation signs a verifiable licence and enforces seats', async () => {
  const { billing, key, c } = await purchased(2);
  const r = await billing.activate({ licence_key: key.toLowerCase(), device_id: DEV });
  assert.equal(r.licence.status, 'active');
  assert.equal(r.licence.seats, 2);
  assert.equal(r.licence.devices_used, 1);
  assert.equal(r.licence.device, DEV);
  const pub = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(signer.publicKeyHex, 'hex')]), format: 'der', type: 'spki' });
  assert.ok(crypto.verify(null, Buffer.from(r.token), pub, Buffer.from(r.sig, 'base64url')));
  assert.deepEqual(JSON.parse(Buffer.from(r.token, 'base64url').toString()), r.licence);
  await billing.activate({ licence_key: key, device_id: DEV });
  assert.equal(c.metadata.cb_devices.split(',').length, 1, 're-activation does not use another seat');
  await billing.activate({ licence_key: key, device_id: 'b'.repeat(32) });
  await assert.rejects(billing.activate({ licence_key: key, device_id: 'c'.repeat(32) }), (e) => e.status === 409);
  await billing.deactivate({ licence_key: key, device_id: DEV });
  assert.equal((await billing.activate({ licence_key: key, device_id: 'c'.repeat(32) })).licence.devices_used, 2);
});

test('inactive licence is signed as inactive and consumes no seat; unknown keys 404', async () => {
  const { billing, key, c } = await purchased(1, { status: 'canceled' });
  const r = await billing.activate({ licence_key: key, device_id: DEV });
  assert.equal(r.licence.status, 'inactive');
  assert.equal(c.metadata.cb_devices, '');
  await assert.rejects(billing.activate({ licence_key: 'CB-AAAA-BBBB-CCCC-DDDD', device_id: DEV }), (e) => e.status === 404);
  await assert.rejects(billing.activate({ licence_key: 'nope', device_id: DEV }), (e) => e.status === 400);
  await assert.rejects(billing.activate({ licence_key: key, device_id: 'XYZ' }), (e) => e.status === 400);
});

test('success page key only for completed sessions', async () => {
  const { stripe, billing, key, c } = await purchased(1);
  stripe.st.sessions.cs_test_done1 = { status: 'complete', customer: c.id, customer_details: { email: 'admin@clinic.example' } };
  stripe.st.sessions.cs_test_open1 = { status: 'open', customer: c.id };
  assert.equal((await billing.keyForSession('cs_test_done1')).key, key);
  await assert.rejects(billing.keyForSession('cs_test_open1'), (e) => e.status === 409);
  await assert.rejects(billing.keyForSession('../etc'), (e) => e.status === 400);
});

test('http routes: pricing page, activation, errors and rate limit', async () => {
  const { billing, key } = await purchased(1);
  const app = buildApp({ billing, log: { error() {} }, rateLimit: 3 });
  const srv = app.listen(0);
  const base = `http://127.0.0.1:${srv.address().port}`;
  try {
    const home = await (await fetch(base + '/')).text();
    assert.match(home, /\$49/);
    assert.match(home, /\$490/);
    assert.match(home, /14-day free trial/);
    const post = (path, body) => fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const ok = await post('/v1/billing/activate', { licence_key: key, device_id: DEV });
    assert.equal(ok.status, 200);
    assert.equal((await ok.json()).licence.status, 'active');
    assert.equal((await post('/v1/billing/activate', { licence_key: 'bad', device_id: DEV })).status, 400);
    assert.equal((await post('/v1/billing/activate', {})).status, 400);
    assert.equal((await post('/v1/billing/activate', {})).status, 429);
    assert.equal((await fetch(base + '/billing/done?session_id=bad')).status, 400);
  } finally { srv.close(); }
});
