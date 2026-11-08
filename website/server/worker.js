import { Webhook } from 'standardwebhooks';
import { DOWNLOADS, DOWNLOAD_URL, MAX_AMOUNT_CENTS } from '../src/payments.js';
export const ORIGIN = 'https://snowy.aauburn.com';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function json(data, status = 200) {
  return Response.json(data, { status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' } });
}
export function validateCheckout(value) {
  return value && Object.keys(value).every(k => ['amountCents', 'context', 'requestId'].includes(k)) &&
    Number.isSafeInteger(value.amountCents) && value.amountCents >= 0 && value.amountCents <= MAX_AMOUNT_CENTS &&
    typeof value.context === 'string' && (value.context === 'support' || Object.hasOwn(DOWNLOADS, value.context)) &&
    typeof value.requestId === 'string' && UUID.test(value.requestId);
}
async function body(request, max) {
  if (Number(request.headers.get('content-length')) > max) throw Error('size');
  const reader = request.body?.getReader();
  if (!reader) throw Error('body');
  let size = 0; const chunks = [];
  while (true) {
    const { value, done } = await reader.read(); if (done) break;
    size += value.length; if (size > max) { await reader.cancel(); throw Error('size'); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
}
export function checkoutURL(value) {
  try { const u = new URL(value); return u.protocol === 'https:' && u.hostname === 'polar.sh' && !u.username && !u.password && !u.port && u.pathname.startsWith('/checkout/'); } catch { return false; }
}
async function polar(env, path, options = {}) {
  const response = await (env.POLAR_FETCH || fetch)('https://api.polar.sh/v1/' + path, {
    ...options, redirect: 'manual', signal: AbortSignal.timeout(12000),
    headers: { Authorization: `Bearer ${env.POLAR_ACCESS_TOKEN}`, 'Polar-Version': '2026-10', 'Content-Type': 'application/json', 'User-Agent': 'Snowy/0.9.0' },
  });
  if (!response.ok) { console.error('Polar request failed', response.status); throw Error('provider'); }
  return response.json();
}
function state(env, name) { return env.PAYMENTS.get(env.PAYMENTS.idFromName(name)); }
async function digest(value) { return [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))].map(x => x.toString(16).padStart(2,'0')).join(''); }
async function limit(request, env, action, maximum) {
  const key = await digest(request.headers.get('CF-Connecting-IP') || 'local');
  const result = await state(env, `rate:${action}:${key}`).fetch(new Request('https://internal/rate', { method:'POST', body:JSON.stringify({ maximum }) }));
  return result.ok;
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith('/api/')) return env.ASSETS.fetch(request);
    try {
      if (url.pathname === '/api/checkout') {
        if (request.method !== 'POST') return json({error:'Method not allowed.'},405);
        if (request.headers.get('origin') !== ORIGIN) return json({error:'Open Snowy to start checkout.'},403);
        if (!request.headers.get('content-type')?.startsWith('application/json')) return json({error:'JSON required.'},415);
        if (!await limit(request,env,'checkout',15)) return json({error:'Please wait a minute before trying again.'},429);
        let value; try { value = JSON.parse(await body(request,1024)); } catch { return json({error:'Invalid request.'},400); }
        if (!validateCheckout(value)) return json({error:'Choose a valid amount from $0 to $1,000.'},422);
        if (value.amountCents === 0) return json({url:DOWNLOADS[value.context] ?? DOWNLOAD_URL,free:true});
        return state(env,`checkout:${value.requestId}`).fetch(new Request('https://internal/create',{method:'POST',body:JSON.stringify(value)}));
      }
      if (url.pathname === '/api/payment') {
        if (request.method !== 'GET') return json({error:'Method not allowed.'},405);
        if (!UUID.test(url.searchParams.get('ref'))) return json({error:'Invalid checkout reference.'},400);
        if (!await limit(request,env,'status',60)) return json({error:'Please wait a minute.'},429);
        return state(env,`checkout:${url.searchParams.get('ref')}`).fetch(new Request('https://internal/status'));
      }
      if (url.pathname === '/api/webhooks/polar') {
        if (request.method !== 'POST') return json({error:'Method not allowed.'},405);
        let event; const id = request.headers.get('webhook-id');
        if (!id || id.length > 200) return json({error:'Invalid signature.'},403);
        try {
          const raw = await body(request,262144);
          event = new Webhook(env.POLAR_WEBHOOK_SECRET).verify(raw, Object.fromEntries(request.headers));
        } catch { return json({error:'Invalid signature.'},403); }
        // No fulfillment gate: Snowy is free. Only deduplicate authenticated events;
        // order state is always retrieved directly from Polar on a payment return.
        return state(env,`event:${id}`).fetch(new Request('https://internal/event',{method:'POST',body:JSON.stringify({ type: event.type })}));
      }
      return json({error:'Not found.'},404);
    } catch { return json({error:'Payments are temporarily unavailable. You can still download for $0.'},503); }
  },
};

// One small object per checkout, rate bucket, or event. No names, emails, card
// data, raw webhooks, or client IPs are stored. Alarms bound retention.
export class PaymentState {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; }
  async alarm() { await this.ctx.storage.deleteAll(); }
  async fetch(request) {
    return this.ctx.blockConcurrencyWhile(async () => {
      const path = new URL(request.url).pathname;
      const storage = this.ctx.storage;
      if (path === '/rate') {
        const {maximum} = await request.json(); const now = Date.now();
        let bucket = await storage.get('bucket');
        if (!bucket || now >= bucket.until) bucket = { count:0,until:now+60000 };
        bucket.count++; await storage.put('bucket',bucket); await storage.setAlarm(bucket.until);
        return json({},bucket.count <= maximum ? 200 : 429);
      }
      if (path === '/event') {
        if (!await storage.get('seen')) { await storage.put('seen',true); await storage.setAlarm(Date.now()+7*86400000); }
        return json({received:true},202);
      }
      const previous = await storage.get('checkout');
      if (path === '/status') {
        if (!previous?.id) return json({error:'Checkout not found or expired.'},404);
        const checkout = await polar(this.env,`checkouts/${encodeURIComponent(previous.id)}`);
        if (checkout.product_id !== this.env.POLAR_PRODUCT_ID || checkout.currency !== 'usd') return json({error:'Checkout mismatch.'},409);
        return json({status:checkout.status,context:previous.context,amountCents:checkout.amount});
      }
      const value = await request.json();
      if (previous) {
        if (previous.amountCents !== value.amountCents || previous.context !== value.context) return json({error:'Choose a new checkout reference for a changed amount.'},409);
        if (previous.url) return json({url:previous.url});
        return json({error:'This checkout attempt could not finish. Reload to try again, or download for $0.'},409);
      }
      // Persist before the provider request. An ambiguous timeout never causes a
      // second provider checkout when the browser retries the same reference.
      await storage.put('checkout',{amountCents:value.amountCents,context:value.context});
      await storage.setAlarm(Date.now()+86400000);
      try {
        const build = value.context.startsWith('windows-') ? `&build=${value.context}` : '';
        const checkout = await polar(this.env,'checkouts/',{method:'POST',body:JSON.stringify({
          products:[this.env.POLAR_PRODUCT_ID],amount:value.amountCents,
          success_url:`${ORIGIN}/?payment=${value.requestId}${build}`,
          return_url:`${ORIGIN}/?payment_cancelled=1${build}`,
          metadata:{snowy_context:value.context},allow_discount_codes:false,
        })});
        if (!checkoutURL(checkout.url) || !checkout.id) throw Error('provider url');
        await storage.put('checkout',{id:checkout.id,url:checkout.url,amountCents:value.amountCents,context:value.context});
        return json({url:checkout.url});
      } catch (error) { console.error('Checkout provider error', error.name, 'provider request or response rejected'); return json({error:'Couldn’t open checkout. Reload to try again, or download for $0.'},503); }
    });
  }
}
