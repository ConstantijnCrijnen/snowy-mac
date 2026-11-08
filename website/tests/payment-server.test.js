import test from 'node:test';
import assert from 'node:assert/strict';
import {Webhook} from 'standardwebhooks';
import worker,{PaymentState,ORIGIN,validateCheckout,checkoutURL} from '../server/worker.js';
import {DOWNLOADS} from '../src/payments.js';
const ref='d15b0f1b-a942-4d07-88c0-7731e6b5bdbc';
const secret='whsec_'+Buffer.from('snowy-testing-secret-32-bytes-long').toString('base64');
function environment() {
  const checkouts=[]; const objects=new Map();
  const env={POLAR_ACCESS_TOKEN:'test',POLAR_WEBHOOK_SECRET:secret,POLAR_PRODUCT_ID:'snowy-product',ASSETS:{fetch:()=>new Response('asset')},
    POLAR_FETCH:async(url,options)=>{
      assert.equal(options.redirect,'manual');
      if (options.method === 'POST') {
        checkouts.push(JSON.parse(options.body));
        return Response.json({id:'checkout-id',url:'https://polar.sh/checkout/test'});
      }
      return Response.json({product_id:'snowy-product',currency:'usd',status:'succeeded',amount:200});
    }};
  env.PAYMENTS={idFromName:x=>x,get(name){if(!objects.has(name)){
    const data=new Map();let queue=Promise.resolve();
    const ctx={storage:{get:async k=>data.get(k),put:async(k,v)=>data.set(k,v),setAlarm:async()=>{},deleteAll:async()=>data.clear()},blockConcurrencyWhile(fn){const p=queue.then(fn);queue=p.catch(()=>{});return p;}};
    objects.set(name,new PaymentState(ctx,env));
  }return objects.get(name);}};
  return {env,checkouts,created:()=>checkouts.length};
}
function request(value,origin=ORIGIN){return new Request(ORIGIN+'/api/checkout',{method:'POST',headers:{origin,'Content-Type':'application/json'},body:JSON.stringify(value)});}
const valid={amountCents:200,context:'download',requestId:ref};
test('server rejects tampered amounts, products, redirects and request identifiers',async()=>{
 for (const changes of [
   {amountCents: -1}, {amountCents: 1.1}, {amountCents: 100001},
   {product: 'evil'}, {return_url: 'https://evil.test'},
   {context: 'other'}, {context: 'constructor'}, {context: ['windows-x64']},
   {requestId: 'x'}, {requestId: [ref]},
 ]) {
   assert.equal(validateCheckout({...valid, ...changes}), false);
 }
 assert.equal(checkoutURL('https://polar.sh.evil.test/checkout/1'),false);
 assert.equal(checkoutURL('https://name@polar.sh/checkout/1'),false);
 const {env}=environment();assert.equal((await worker.fetch(request(valid,'https://evil.test'),env)).status,403);
 assert.equal((await worker.fetch(request({...valid,padding:'x'.repeat(2000)}),env)).status,400);
});
test('zero bypasses Polar, duplicate concurrent requests reuse exactly one checkout',async()=>{
 const {env,created,checkouts}=environment();
 const free=await worker.fetch(request({...valid,amountCents:0}),env);assert.equal((await free.json()).free,true);assert.equal(created(),0);
 const responses=await Promise.all([worker.fetch(request(valid),env),worker.fetch(request(valid),env)]);
 for(const r of responses)assert.equal((await r.json()).url,'https://polar.sh/checkout/test');
 assert.equal(created(),1);
 assert.equal(checkouts[0].success_url, `${ORIGIN}/?payment=${ref}`);
 assert.equal(checkouts[0].return_url, `${ORIGIN}/?payment_cancelled=1`);
 assert.equal((await worker.fetch(request({...valid,amountCents:300}),env)).status,409);
});
test('Windows checkout preserves the selected installer through free, paid and cancelled flows', async () => {
  for (const context of ['windows-x64', 'windows-arm64']) {
    const {env, checkouts} = environment();
    const value = {...valid, context};
    const free = await worker.fetch(request({...value, amountCents: 0}), env);
    assert.deepEqual(await free.json(), {url: DOWNLOADS[context], free: true});
    assert.equal(checkouts.length, 0);

    const paid = await worker.fetch(request(value), env);
    assert.equal(paid.status, 200);
    assert.equal(checkouts.length, 1);
    assert.equal(checkouts[0].success_url, `${ORIGIN}/?payment=${ref}&build=${context}`);
    assert.equal(checkouts[0].return_url, `${ORIGIN}/?payment_cancelled=1&build=${context}`);
    assert.equal(checkouts[0].metadata.snowy_context, context);

    const status = await worker.fetch(new Request(`${ORIGIN}/api/payment?ref=${ref}`), env);
    assert.deepEqual(await status.json(), {status: 'succeeded', context, amountCents: 200});
    const differentBuild = context === 'windows-x64' ? 'windows-arm64' : 'windows-x64';
    const conflict = await worker.fetch(request({...value, context: differentBuild}), env);
    assert.equal(conflict.status, 409);
    assert.equal(checkouts.length, 1);
  }
});
test('provider ambiguity cannot create a second checkout on retry',async()=>{
 const {env}=environment();let calls=0;env.POLAR_FETCH=async()=>{calls++;throw Error('timeout');};
 assert.equal((await worker.fetch(request(valid),env)).status,503);
 assert.equal((await worker.fetch(request(valid),env)).status,409);assert.equal(calls,1);
});
test('rate limit persists outside one request and does not call Polar on abuse',async()=>{
 const {env}=environment();for(let i=0;i<15;i++)await worker.fetch(request({...valid,amountCents:0}),env);
 assert.equal((await worker.fetch(request(valid),env)).status,429);
});
test('only server-retrieved succeeded state confirms payment, mismatch and unknown refs fail',async()=>{
 const {env}=environment();const req=()=>new Request(ORIGIN+'/api/payment?ref='+ref);
 assert.equal((await worker.fetch(req(),env)).status,404);
 await worker.fetch(request(valid),env);assert.equal((await(await worker.fetch(req(),env)).json()).status,'succeeded');
 env.POLAR_FETCH=async()=>Response.json({product_id:'other',currency:'usd',status:'succeeded'});
 assert.equal((await worker.fetch(req(),env)).status,409);
});
test('webhook validates untouched payload, replay timestamp, signature and duplicates',async()=>{
 const {env}=environment();const raw=JSON.stringify({type:'order.paid',data:{id:'test-order'}});const now=new Date();const id='test-event';
 function signed(payload=raw,date=now){return new Request(ORIGIN+'/api/webhooks/polar',{method:'POST',headers:{'webhook-id':id,'webhook-timestamp':String(Math.floor(date.getTime()/1000)),'webhook-signature':new Webhook(secret).sign(id,date,raw)},body:payload});}
 assert.equal((await worker.fetch(signed(),env)).status,202);assert.equal((await worker.fetch(signed(),env)).status,202);
 assert.equal((await worker.fetch(signed(raw+' '),env)).status,403);
 assert.equal((await worker.fetch(signed(raw,new Date(Date.now()-600000)),env)).status,403);
 assert.equal((await worker.fetch(new Request(ORIGIN+'/api/webhooks/polar',{method:'POST',body:raw}),env)).status,403);
});
