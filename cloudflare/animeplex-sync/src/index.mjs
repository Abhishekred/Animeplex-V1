// AnimePlex VPS-compatible Cloudflare Worker (staging).
// Supabase is the sole authority for signed-in user data and profile-lock RLS.
// Never deploy as a public data proxy without the user JWT checks below.
const TABLES = new Set([
  'history', 'profile_history', 'mylist', 'profile_mylist',
  'list_categories', 'profile_list_categories', 'mylist_categories',
  'profile_mylist_categories', 'mylist_sync_clock', 'mylist_sync_tombstones',
  'reading_history', 'profile_reading_history', 'viewer_profiles', 'backups',
]);
const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
};
const COPY_REQUEST_HEADERS = [
  'accept', 'content-type', 'prefer', 'range', 'range-unit', 'if-match',
  'if-none-match', 'x-profile-grants',
];
const COPY_RESPONSE_HEADERS = [
  'content-type', 'content-range', 'range-unit', 'preference-applied',
  'etag', 'location', 'www-authenticate',
];
const FORMAT = 'stremio-server-v1';
const MAX_CONFIG = 1024 * 1024;
const MAX_BODY = MAX_CONFIG * 2;
const MAX_GIF_RESPONSE = 2 * 1024 * 1024;
const SLUG = /^[A-Za-z0-9]+(?:-+[A-Za-z0-9]+)*$/;

class Problem extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}
function json(body, status = 200, extra = {}) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...JSON_HEADERS, ...extra },
  });
}
function checkConfig(env) {
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(env.SUPABASE_URL || '') ||
      !(env.SUPABASE_PUBLISHABLE_KEY || '').startsWith('sb_publishable_')) {
    throw new Problem(503, 'Sync backend configuration missing');
  }
}
function bearer(request) {
  const value = request.headers.get('authorization') || '';
  if (!/^Bearer [^\s]+$/.test(value) || value.length > 8199) {
    throw new Problem(401, 'Sign in required');
  }
  return value;
}
async function userId(request, env) {
  const auth = bearer(request);
  const upstream = await fetch(env.SUPABASE_URL + '/auth/v1/user', {
    headers: { 'apikey': env.SUPABASE_PUBLISHABLE_KEY, 'authorization': auth },
    redirect: 'manual',
  });
  if (upstream.status !== 200) {
    throw new Problem(upstream.status >= 500 ? 503 : 401,
      upstream.status >= 500 ? 'Sign-in verification unavailable' : 'Sign in required');
  }
  const data = await upstream.json();
  if (!data || typeof data.id !== 'string' ||
      !/^[0-9a-f-]{36}$/i.test(data.id) || data.is_anonymous === true) {
    throw new Problem(401, 'Sign in required');
  }
  return data.id;
}
async function limitUser(env, uid) {
  if (!env.USER_LIMITER || typeof env.USER_LIMITER.limit !== 'function') {
    throw new Problem(503, 'Rate limiter not configured');
  }
  const result = await env.USER_LIMITER.limit({ key: uid });
  if (!result.success) throw new Problem(429, 'Too many requests');
}
function apiHeaders(request, env) {
  const headers = new Headers({
    apikey: env.SUPABASE_PUBLISHABLE_KEY,
    authorization: bearer(request),
  });
  for (const key of COPY_REQUEST_HEADERS) {
    const value = request.headers.get(key);
    if (value !== null) headers.set(key, value);
  }
  return headers;
}
async function forwardRest(request, env, url, path) {
  if (!['GET', 'HEAD', 'POST', 'PATCH', 'DELETE'].includes(request.method)) {
    throw new Problem(405, 'Method not allowed');
  }
  const isRpc = path === 'rpc/profile_lock';
  if (isRpc ? request.method !== 'POST' : !TABLES.has(path)) {
    throw new Problem(404, 'Not found');
  }
  const endpoint = env.SUPABASE_URL + '/rest/v1/' + path + url.search;
  const upstream = await fetch(endpoint, {
    method: request.method,
    headers: apiHeaders(request, env),
    body: ['POST', 'PATCH'].includes(request.method) ? request.body : undefined,
    redirect: 'manual',
  });
  const headers = new Headers({ 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
  for (const name of COPY_RESPONSE_HEADERS) {
    const value = upstream.headers.get(name);
    if (value) headers.set(name, value);
  }
  return new Response(request.method === 'HEAD' ? null : upstream.body, {
    status: upstream.status, headers,
  });
}
function validSearch(value) {
  if (typeof value !== 'string' || !value.trim() || value.length > 120 ||
      /[\u0000-\u001f]/.test(value)) {
    throw new Problem(400, 'Invalid search');
  }
  return value;
}
function onlyQuery(url, key) {
  if (Array.from(url.searchParams.keys()).length !== 1 ||
      !url.searchParams.has(key)) {
    throw new Problem(400, 'Invalid request');
  }
  return url.searchParams.get(key);
}
async function klipy(request, env, url) {
  if (url.href.length > 2048) throw new Problem(400, 'Invalid request');
  const path = url.pathname;
  let target = '';
  let body = undefined;
  if (path === '/klipy/v1/gifs/search' && request.method === 'GET') {
    const q = validSearch(onlyQuery(url, 'q'));
    const args = new URLSearchParams({
      q, page: '1', per_page: '24', content_filter: 'high', format_filter: 'gif',
    });
    target = 'gifs/search?' + args.toString();
  } else if (path === '/klipy/v1/gifs/items' && request.method === 'GET') {
    const slug = onlyQuery(url, 'slugs');
    if (!SLUG.test(slug || '')) throw new Problem(400, 'Invalid GIF');
    target = 'gifs/items?' + new URLSearchParams({
      slugs: slug, format_filter: 'gif',
    }).toString();
  } else if (path.startsWith('/klipy/v1/gifs/share/') && request.method === 'POST') {
    if (url.search) throw new Problem(400, 'Invalid share');
    const slug = path.slice('/klipy/v1/gifs/share/'.length);
    if (!SLUG.test(slug)) throw new Problem(400, 'Invalid GIF');
    const data = await limitedJson(request, 1024);
    if (!data || Object.keys(data).length !== 1 || !('q' in data)) {
      throw new Problem(400, 'Invalid share');
    }
    body = JSON.stringify({ q: validSearch(data.q) });
    target = 'gifs/share/' + slug;
  } else {
    throw new Problem(404, 'Not found');
  }
  if (!env.KLIPY_API_KEY) throw new Problem(503, 'GIF service unavailable');
  const uid = await userId(request, env);
  await limitUser(env, uid);
  const upstream = await fetch('https://api.klipy.com/api/v1/' +
      encodeURIComponent(env.KLIPY_API_KEY) + '/' + target, {
    method: body ? 'POST' : 'GET',
    headers: { 'accept': 'application/json', ...(body ? { 'content-type': 'application/json' } : {}) },
    body, redirect: 'manual',
  });
  if (upstream.status === 429) throw new Problem(429, 'GIF service is busy');
  if (!upstream.ok) throw new Problem(502, 'GIF service is unavailable');
  if (Number(upstream.headers.get('content-length')) > MAX_GIF_RESPONSE) {
    throw new Problem(502, 'GIF response is too large');
  }
  const bytes = await upstream.arrayBuffer();
  if (bytes.byteLength > MAX_GIF_RESPONSE) throw new Problem(502, 'GIF response is too large');
  if (upstream.status === 204) return new Response(null, { status: 204, headers: JSON_HEADERS });
  try {
    const parsed = JSON.parse(new TextDecoder().decode(bytes));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw Error('bad json');
  } catch (_) {
    throw new Problem(502, 'Invalid GIF service response');
  }
  return new Response(bytes, { status: upstream.status, headers: JSON_HEADERS });
}
async function limitedJson(request, max) {
  const size = request.headers.get('content-length');
  if (size !== null && (!Number.isSafeInteger(+size) || +size > max || +size < 0)) {
    throw new Problem(413, 'Request is too large');
  }
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength > max) throw new Problem(413, 'Request is too large');
  try {
    const data = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    if (!data || Array.isArray(data) || typeof data !== 'object') throw Error('not an object');
    return data;
  } catch (_) {
    throw new Problem(400, 'Invalid request');
  }
}
function toBase64(bytes) {
  let bin = '';
  for (let i = 0; i < bytes.length; i += 16384) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 16384));
  }
  return btoa(bin);
}
function fromBase64(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(value) ||
      value.length % 4 !== 0) throw Error('bad base64');
  const bin = atob(value);
  return Uint8Array.from(bin, char => char.charCodeAt(0));
}
async function cipherKey(env) {
  let bytes;
  try { bytes = fromBase64(env.STREMIO_AES256_KEY); } catch (_) {}
  if (!bytes || bytes.byteLength !== 32) {
    throw new Problem(503, 'Addon sync encryption key is unavailable');
  }
  return crypto.subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt', 'decrypt']);
}
async function seal(owner, config, key) {
  const raw = new TextEncoder().encode(JSON.stringify(config));
  if (raw.byteLength > MAX_CONFIG) throw new Problem(413, 'Addon configuration is too large');
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const aad = new TextEncoder().encode(FORMAT + '|' + owner);
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({
    name: 'AES-GCM', iv: nonce, additionalData: aad, tagLength: 128,
  }, key, raw));
  return { format: FORMAT, nonce: toBase64(nonce), ciphertext: toBase64(ciphertext) };
}
async function open(owner, envelope, key) {
  try {
    if (!envelope || envelope.format !== FORMAT) throw Error('format');
    const nonce = fromBase64(envelope.nonce);
    const payload = fromBase64(envelope.ciphertext);
    if (nonce.byteLength !== 12 || payload.byteLength > MAX_CONFIG + 16) throw Error('length');
    const aad = new TextEncoder().encode(FORMAT + '|' + owner);
    const clear = await crypto.subtle.decrypt({
      name: 'AES-GCM', iv: nonce, additionalData: aad, tagLength: 128,
    }, key, payload);
    const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(clear));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw Error('shape');
    return value;
  } catch (_) {
    throw new Problem(400, 'Addon backup cannot be opened by this account');
  }
}
async function stremio(request, env, url) {
  if (request.method !== 'POST' || url.search ||
      !['/stremio/v1/seal', '/stremio/v1/open', '/stremio/v1/configuration'].includes(url.pathname)) {
    throw new Problem(404, 'Not found');
  }
  const owner = await userId(request, env);
  await limitUser(env, owner);
  const key = await cipherKey(env);
  const body = await limitedJson(request, MAX_BODY);
  if (url.pathname.endsWith('/seal')) {
    if (Object.keys(body).length !== 1 || !body.configuration ||
        typeof body.configuration !== 'object' || Array.isArray(body.configuration)) {
      throw new Problem(400, 'Invalid request');
    }
    return json(await seal(owner, body.configuration, key));
  }
  if (url.pathname.endsWith('/open')) {
    if (Object.keys(body).length !== 1 || !body.envelope) throw new Problem(400, 'Invalid request');
    return json({ configuration: await open(owner, body.envelope, key) });
  }
  let version = null;
  let payload = null;
  if (Object.keys(body).length > 0) {
    if (Object.keys(body).sort().join(',') !== 'configuration,expectedVersion' ||
        !Number.isSafeInteger(body.expectedVersion) || body.expectedVersion < 0 ||
        !body.configuration || typeof body.configuration !== 'object' ||
        Array.isArray(body.configuration)) {
      throw new Problem(400, 'Invalid request');
    }
    version = body.expectedVersion;
    payload = await seal(owner, body.configuration, key);
  }
  const upstream = await fetch(env.SUPABASE_URL + '/rest/v1/rpc/stremio_configuration', {
    method: 'POST',
    headers: {
      apikey: env.SUPABASE_PUBLISHABLE_KEY,
      authorization: bearer(request),
      'content-type': 'application/json',
    },
    body: JSON.stringify({ p_expected_version: version, p_payload: payload }),
    redirect: 'manual',
  });
  if (!upstream.ok) throw new Problem(503, 'Addon sync is temporarily unavailable');
  const data = await upstream.json();
  if (!data || !Number.isSafeInteger(Number(data.version)) || typeof data.accepted !== 'boolean') {
    throw new Problem(503, 'Addon sync is temporarily unavailable');
  }
  const configuration = data.payload ? await open(owner, data.payload, key) : null;
  return json({ version: Number(data.version), accepted: data.accepted, configuration });
}
export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      if (url.pathname === '/health' && request.method === 'GET') {
        return json({ ok: true, backend: 'animeplex-supabase',
          services: { data: true, klipy: Boolean(env.KLIPY_API_KEY),
            stremio: Boolean(env.STREMIO_AES256_KEY), rateLimit: Boolean(env.USER_LIMITER) } });
      }
      checkConfig(env);
      if (url.pathname.startsWith('/klipy/')) return await klipy(request, env, url);
      if (url.pathname.startsWith('/stremio/')) return await stremio(request, env, url);
      const path = url.pathname.slice(1);
      if (TABLES.has(path) || path === 'rpc/profile_lock') return await forwardRest(request, env, url, path);
      throw new Problem(404, 'Not found');
    } catch (error) {
      if (error instanceof Problem) {
        return json({ error: error.message }, error.status,
          error.status === 429 ? { 'retry-after': '60' } : {});
      }
      return json({ error: 'Service temporarily unavailable' }, 503);
    }
  },
};
