import { MAX_SEATS, PLANS, TRIAL_DAYS } from './billing.js';

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const usd = (cents) => '$' + (cents / 100).toLocaleString('en-US', { maximumFractionDigits: 0 });
const SUPPORT = 'redreishilife+clinicbridge@gmail.com';

const page = (title, body) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><style>
body{margin:0;background:#0b2545;color:#e2e8f0;font:16px/1.5 system-ui,sans-serif}main{max-width:640px;margin:0 auto;padding:32px 20px}
h1{font-size:26px;margin:0 0 8px}h2{font-size:18px}.card{background:#13315c;border-radius:14px;padding:20px;margin:16px 0}
.plans{display:flex;gap:12px;flex-wrap:wrap}.plan{flex:1;min-width:220px;border:2px solid #1f4e79;border-radius:12px;padding:14px;cursor:pointer}
.plan input{margin-right:8px}.price{font-size:28px;font-weight:700;color:#5eead4}label{display:block;margin:12px 0 4px}
input[type=email],input[type=number],input[type=text]{width:100%;box-sizing:border-box;padding:12px;border-radius:10px;border:0;font-size:16px}
button{margin-top:16px;width:100%;padding:14px;border:0;border-radius:12px;background:#14b8a6;color:#04223a;font-weight:700;font-size:16px;cursor:pointer}
.key{font:700 24px ui-monospace,monospace;letter-spacing:2px;background:#04223a;padding:16px;border-radius:10px;text-align:center;color:#5eead4;user-select:all}
small,.muted{color:#94a3b8}a{color:#5eead4}.err{color:#fca5a5}</style></head><body><main>${body}
<p class="muted"><small>RED REISHI LLC · <a href="mailto:${SUPPORT}">${SUPPORT}</a> · <a href="https://chazric.github.io/Clinicbridge/privacy.html">Privacy</a><br>
Billing is handled by Stripe. No patient information is ever sent to this site.</small></p></main></body></html>`;

export const pricingPage = () => page('ClinicBridge AI — clinician licences', `
<h1>ClinicBridge AI licences</h1><p>Interpreter safety, Clinical Truth Ledger and accountable handoff for your clinicians.
The synthetic demo in the app is always free; a licence lets a clinician record real encounters.</p>
<form class="card" id="f"><h2>Choose a plan</h2><div class="plans">
<label class="plan"><input type="radio" name="plan" value="monthly" checked><span class="price">${usd(PLANS.monthly.amount)}</span> per clinician / month</label>
<label class="plan"><input type="radio" name="plan" value="annual"><span class="price">${usd(PLANS.annual.amount)}</span> per clinician / year<br><small>2 months free</small></label></div>
<label for="seats">Clinicians (1 seat = 1 clinician device, up to ${MAX_SEATS})</label><input id="seats" name="seats" type="number" min="1" max="${MAX_SEATS}" value="1" required>
<label for="email">Billing email</label><input id="email" name="email" type="email" required autocomplete="email">
<button type="submit">Start ${TRIAL_DAYS}-day free trial</button><p id="e" class="err"></p>
<small>You won't be charged until the ${TRIAL_DAYS}-day trial ends. Cancel anytime from "Manage subscription".</small></form>
<div class="card"><h2>Hospitals and health systems</h2><p>More than ${MAX_SEATS} clinicians, EHR integration, SSO or a BAA/DPA: <a href="mailto:${SUPPORT}?subject=ClinicBridge%20enterprise">contact us for enterprise pricing</a>.</p></div>
<p><a href="/manage">Manage an existing subscription</a></p>
<script>document.getElementById('f').onsubmit=async function(ev){ev.preventDefault();var e=document.getElementById('e');e.textContent='';
var b=ev.target.querySelector('button');b.disabled=true;try{var fd=new FormData(ev.target);
var r=await fetch('/v1/billing/checkout',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({plan:fd.get('plan'),seats:fd.get('seats'),email:fd.get('email')})});
var j=await r.json();if(!r.ok)throw new Error(j.error||'Checkout failed');location.href=j.url}catch(x){e.textContent=x.message;b.disabled=false}};</script>`);

export const donePage = (key, email) => page('Your ClinicBridge licence key', `
<h1>Your trial has started</h1><p>Save this licence key now${email ? ` (receipt goes to ${esc(email)})` : ''}. Give it to each clinician on your plan.</p>
<div class="key">${esc(key)}</div>
<div class="card"><h2>Activate on each device</h2><ol><li>Open ClinicBridge AI and unlock it.</li><li>Settings → <b>Licence</b> → <b>Enter licence key</b>.</li><li>Paste the key. Each device uses one seat.</li></ol>
<p class="muted">Lost the key? Email support from your billing address.</p></div>`);

export const cancelPage = () => page('Checkout canceled', '<h1>Checkout canceled</h1><p>No payment was taken.</p><p><a href="/">Back to plans</a></p>');

export const managePage = () => page('Manage subscription', `
<h1>Manage subscription</h1><p>Change seats, update the card, download invoices or cancel.</p>
<form class="card" id="m"><label for="k">Licence key</label><input id="k" type="text" placeholder="CB-XXXX-XXXX-XXXX-XXXX" required autocomplete="off">
<button type="submit">Open billing portal</button><p id="e" class="err"></p></form>
<script>document.getElementById('m').onsubmit=async function(ev){ev.preventDefault();var e=document.getElementById('e');e.textContent='';
try{var r=await fetch('/v1/billing/portal',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({licence_key:document.getElementById('k').value})});
var j=await r.json();if(!r.ok)throw new Error(j.error||'Not found');location.href=j.url}catch(x){e.textContent=x.message}};</script>`);

export const errorPage = (msg) => page('ClinicBridge billing', `<h1>Something went wrong</h1><p>${esc(msg)}</p><p><a href="/">Back to plans</a></p>`);
