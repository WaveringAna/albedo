// Deterministic, fake-only Codex token exchange. No real auth endpoint requests.
const originalFetch=globalThis.fetch;
const jwt=payload=>'fixture.'+Buffer.from(JSON.stringify(payload)).toString('base64url')+'.signature';
globalThis.fetch=(url,options)=>{
  if (String(url)==='https://auth.openai.com/oauth/token' && process.env.ALBEDO_VISUAL_AUTH_ERROR==='1') return Promise.resolve(new Response(JSON.stringify({error:'fixture rejected authorization code'}),{status:401,headers:{'content-type':'application/json'}}));
  if (String(url)==='https://auth.openai.com/oauth/token') return Promise.resolve(new Response(JSON.stringify({access_token:jwt({'https://api.openai.com/auth':{chatgpt_account_id:'fixture-account'}}),refresh_token:'fixture-refresh',expires_in:3600}),{status:200,headers:{'content-type':'application/json'}}));
  const target=new URL(url instanceof Request ? url.url : String(url));
  if (['file:','data:'].includes(target.protocol)) return originalFetch(url,options);
  if (!['127.0.0.1','localhost'].includes(target.hostname)) throw new Error(`visual fixture blocked external fetch: ${target.hostname}`);
  return originalFetch(url,options);
};
