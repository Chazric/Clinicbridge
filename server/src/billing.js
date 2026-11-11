import crypto from 'node:crypto';

/** Per-clinician seat pricing in integer US cents. One seat = one activated clinician device. */
export const PLANS = {
  monthly: { name: 'ClinicBridge AI — clinician seat (monthly)', amount: 4900, interval: 'month' },
  annual: { name: 'ClinicBridge AI — clinician seat (annual)', amount: 49000, interval: 'year' },
};
export const TRIAL_DAYS = 14;
export const MAX_SEATS = 25;
/** Clinicians working offline stay licensed a few days past renewal. */
export const OFFLINE_GRACE_DAYS = 3;
export const TOKEN_VALID_DAYS = 30;

const DAY = 86400000;
const LIVE_SUB = new Set(['active', 'trialing', 'past_due']);
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

export class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export const normalizeKey = (k) => (typeof k === 'string' ? k.trim().toUpperCase() : '');
export const validKey = (k) => /^CB(-[A-Z2-9]{4}){4}$/.test(k);
export const validDevice = (d) => typeof d === 'string' && /^[a-f0-9]{16,64}$/.test(d);
export const accountHash = (key) => crypto.createHash('sha256').update('cb-licence:' + key).digest('hex').slice(0, 40);
const deviceTag = (d) => crypto.createHash('sha256').update('cb-device:' + d).digest('hex').slice(0, 12);

/** Licence keys are derived from the Stripe customer id, so the server stores only their hash. */
export function licenceKeyFor(customerId, signer) {
  const bytes = signer.hmac('licence:' + customerId);
  let s = '';
  for (let i = 0; i < 16; i++) s += ALPHABET[bytes[i] % ALPHABET.length];
  return 'CB-' + s.match(/.{4}/g).join('-');
}

function periodEndMs(sub) {
  const end = sub.current_period_end ?? sub.items?.data?.[0]?.current_period_end;
  return end ? end * 1000 : 0;
}

function seatsOf(sub) {
  return (sub.items?.data ?? []).reduce((n, i) => n + (i.quantity ?? 0), 0) || sub.quantity || 0;
}

/** Pure licence calculation from Stripe subscriptions, so it can be unit-tested without Stripe. */
export function computeLicence({ subs, nowMs }) {
  let seats = 0;
  let expMs = 0;
  let trialing = false;
  let plan = null;
  for (const s of subs) {
    if (!LIVE_SUB.has(s.status) || !PLANS[s.metadata?.cb_plan]) continue;
    const end = (s.status === 'trialing' && s.trial_end ? s.trial_end * 1000 : periodEndMs(s)) + OFFLINE_GRACE_DAYS * DAY;
    if (end <= nowMs) continue;
    seats += seatsOf(s);
    expMs = Math.max(expMs, end);
    if (s.status === 'trialing') trialing = true;
    if (!plan || s.metadata.cb_plan === 'annual') plan = s.metadata.cb_plan;
  }
  if (seats === 0) return { status: 'inactive', plan: null, seats: 0, expires_at: null };
  return { status: trialing ? 'trialing' : 'active', plan, seats, expires_at: new Date(expMs).toISOString() };
}

export function createBilling({ stripe, baseUrl, signer, now = () => Date.now() }) {
  async function findCustomer(key) {
    const r = await stripe.customers.search({ query: `metadata['cb_account']:'${accountHash(key)}'`, limit: 1 });
    const c = r.data[0];
    return c && !c.deleted ? c : null;
  }

  async function licenceFor(customer) {
    const subs = [];
    for await (const s of stripe.subscriptions.list({ customer: customer.id, status: 'all', limit: 100 })) subs.push(s);
    return computeLicence({ subs, nowMs: now() });
  }

  function signed(key, device, lic, devicesUsed) {
    const payload = {
      v: 1,
      account: accountHash(key),
      device,
      ...lic,
      devices_used: devicesUsed,
      issued_at: new Date(now()).toISOString(),
      valid_until: new Date(now() + TOKEN_VALID_DAYS * DAY).toISOString(),
    };
    const token = Buffer.from(JSON.stringify(payload)).toString('base64url');
    return { licence: payload, token, sig: signer.sign(token) };
  }

  function requireInput(key, device) {
    if (!validKey(key)) throw new HttpError(400, 'invalid licence key');
    if (device !== undefined && !validDevice(device)) throw new HttpError(400, 'invalid device id');
  }

  const devicesOf = (c) => (c.metadata?.cb_devices ? c.metadata.cb_devices.split(',').filter(Boolean) : []);

  return {
    async checkout({ plan, seats, email }) {
      const p = PLANS[plan];
      if (!p) throw new HttpError(400, 'unknown plan');
      const n = Number.parseInt(seats, 10);
      if (!Number.isInteger(n) || n < 1 || n > MAX_SEATS) throw new HttpError(400, `seats must be 1-${MAX_SEATS}`);
      const mail = typeof email === 'string' && /^[^\s@]{1,64}@[^\s@]{1,190}$/.test(email.trim()) ? email.trim() : undefined;
      if (!mail) throw new HttpError(400, 'a valid email is required');
      const c = await stripe.customers.create({ email: mail, metadata: { cb_product: 'clinicbridge' } });
      await stripe.customers.update(c.id, { metadata: { cb_account: accountHash(licenceKeyFor(c.id, signer)), cb_devices: '' } });
      const meta = { cb_plan: plan, cb_product: 'clinicbridge' };
      const s = await stripe.checkout.sessions.create({
        mode: 'subscription',
        customer: c.id,
        line_items: [{
          quantity: n,
          adjustable_quantity: { enabled: true, minimum: 1, maximum: MAX_SEATS },
          price_data: { currency: 'usd', unit_amount: p.amount, product_data: { name: p.name }, recurring: { interval: p.interval } },
        }],
        metadata: meta,
        subscription_data: { metadata: meta, trial_period_days: TRIAL_DAYS },
        allow_promotion_codes: true,
        billing_address_collection: 'required',
        success_url: `${baseUrl}/billing/done?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${baseUrl}/billing/cancel`,
      });
      return { url: s.url };
    },

    /** Licence key for a completed Checkout Session; shown once on the success page. */
    async keyForSession(sessionId) {
      if (typeof sessionId !== 'string' || !/^cs_[A-Za-z0-9_]{8,200}$/.test(sessionId)) throw new HttpError(400, 'invalid session');
      const s = await stripe.checkout.sessions.retrieve(sessionId);
      if (s.status !== 'complete' || typeof s.customer !== 'string') throw new HttpError(409, 'checkout not complete');
      return { key: licenceKeyFor(s.customer, signer), email: s.customer_details?.email ?? null };
    },

    async activate({ licence_key, device_id }) {
      const key = normalizeKey(licence_key);
      requireInput(key, device_id);
      const c = await findCustomer(key);
      if (!c) throw new HttpError(404, 'licence key not found');
      const lic = await licenceFor(c);
      const tag = deviceTag(device_id);
      let devices = devicesOf(c);
      if (lic.status !== 'inactive' && !devices.includes(tag)) {
        if (devices.length >= lic.seats) throw new HttpError(409, `all ${lic.seats} seat(s) are in use; remove the licence from another device or add seats`);
        devices = [...devices, tag];
        await stripe.customers.update(c.id, { metadata: { cb_devices: devices.join(',') } });
      }
      return signed(key, device_id, lic, devices.length);
    },

    async deactivate({ licence_key, device_id }) {
      const key = normalizeKey(licence_key);
      requireInput(key, device_id);
      const c = await findCustomer(key);
      if (!c) throw new HttpError(404, 'licence key not found');
      const tag = deviceTag(device_id);
      const devices = devicesOf(c).filter((d) => d !== tag);
      await stripe.customers.update(c.id, { metadata: { cb_devices: devices.join(',') } });
      return { ok: true, devices_used: devices.length };
    },

    async portal({ licence_key }) {
      const key = normalizeKey(licence_key);
      requireInput(key);
      const c = await findCustomer(key);
      if (!c) throw new HttpError(404, 'licence key not found');
      const s = await stripe.billingPortal.sessions.create({ customer: c.id, return_url: `${baseUrl}/` });
      return { url: s.url };
    },
  };
}
