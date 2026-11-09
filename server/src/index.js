import Stripe from 'stripe';
import { buildApp } from './app.js';
import { createBilling } from './billing.js';
import { createSigner } from './sign.js';

const env = process.env;
for (const k of ['STRIPE_SECRET_KEY', 'PUBLIC_BASE_URL', 'LICENCE_SIGNING_KEY']) {
  if (!env[k]) { console.error(`Missing required environment variable ${k}`); process.exit(1); }
}
const stripe = new Stripe(env.STRIPE_SECRET_KEY, { appInfo: { name: 'ClinicBridge Billing', version: '1.0.0' } });
const signer = createSigner(env.LICENCE_SIGNING_KEY);
const billing = createBilling({ stripe, baseUrl: env.PUBLIC_BASE_URL.replace(/\/$/, ''), signer });
const port = Number(env.PORT ?? 8787);
const live = /^(sk|rk)_live/.test(env.STRIPE_SECRET_KEY);
buildApp({ billing }).listen(port, () => console.log(`ClinicBridge billing on :${port} (${live ? 'LIVE' : 'test'} mode, licence key ${signer.publicKeyHex.slice(0, 8)}…)`));
