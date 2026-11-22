import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.mjs';

const user = '00000000-0000-4000-8000-000000000001';
const token = 'test-user-jwt';
const key = btoa(String.fromCharCode(...Array(32).fill(7)));
const env = {
  SUPABASE_URL: 'https://iwiujqjipotwvigvaaid.supabase.co',
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test_public',
  KLIPY_API_KEY: 'testing-klipy-key',
  STREMIO_AES256_KEY: key,
  USER_LIMITER: { async limit({ key }) { assert.equal(key, user); return { success: true }; } },
};
function call(path, method = 'GET', body, headers = {}) {
  return worker.fetch(new Request('https://staging.example' + path, {
    method, headers: { authorization: 'Bearer ' + token,
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  }), env);
}
function authUser() {
  return new Response(JSON.stringify({ id: user, email: 'test@example.com' }), {
    status: 200, headers: { 'content-type': 'application/json' },
  });
}
async function withFetch(mock, fn) {
  const orig = globalThis.fetch;
  globalThis.fetch = mock;
  try { return await fn(); } finally { globalThis.fetch = orig; }
}

test('health lists configured services without exposing credentials', async () => {
  const response = await call('/health');
  assert.equal(response.status, 200);
  const text = await response.text();
  assert.match(text, /animeplex-supabase/);
  assert.doesNotMatch(text, /testing-klipy-key/);
});

test('anonymous data and forbidden paths fail closed', async () => {
  await withFetch(async () => { throw Error('should not fetch'); }, async () => {
    const noToken = await worker.fetch(new Request('https://staging.example/mylist'), env);
    assert.equal(noToken.status, 401);
    assert.equal((await call('/auth/v1/admin')).status, 404);
    assert.equal((await call('/profiles')).status, 404);
    assert.equal((await call('/rpc/stremio_configuration', 'POST', {})).status, 404);
    assert.equal((await call('/mylist', 'PUT', {})).status, 405);
  });
});

test('PostgREST data proxy preserves auth, profile grants and response metadata', async () => {
  await withFetch(async (url, options) => {
    assert.equal(new URL(url).pathname, '/rest/v1/profile_mylist');
    assert.equal(new URL(url).searchParams.get('user_key'), 'eq.test');
    assert.equal(options.headers.get('authorization'), 'Bearer ' + token);
    assert.equal(options.headers.get('apikey'), env.SUPABASE_PUBLISHABLE_KEY);
    assert.equal(options.headers.get('x-profile-grants'), '{"default":"grant-token"}');
    assert.equal(options.headers.get('range'), '0-9');
    return new Response('[{"item_id":"x"}]', {
      status: 206, headers: { 'content-type': 'application/json', 'content-range': '0-0/1' },
    });
  }, async () => {
    const response = await call('/profile_mylist?user_key=eq.test', 'GET', undefined,
      { 'x-profile-grants': '{"default":"grant-token"}', range: '0-9' });
    assert.equal(response.status, 206);
    assert.equal(response.headers.get('content-range'), '0-0/1');
    assert.equal((await response.json())[0].item_id, 'x');
  });
});

test('profile PIN RPC forwards only approved path', async () => {
  await withFetch(async (url, options) => {
    assert.equal(new URL(url).pathname, '/rest/v1/rpc/profile_lock');
    assert.equal(options.method, 'POST');
    assert.equal(JSON.parse(await new Response(options.body).text()).p_action, 'status');
    return new Response('{"ok":true,"locked":false}', { status: 200 });
  }, async () => {
    const response = await call('/rpc/profile_lock', 'POST', { p_action: 'status' });
    assert.equal((await response.json()).ok, true);
  });
});

test('KLIPY search validates query, verifies user, and limits upstream', async () => {
  await withFetch(async (url, options) => {
    if (String(url).endsWith('/auth/v1/user')) return authUser();
    assert.ok(String(url).startsWith('https://api.klipy.com/api/v1/testing-klipy-key/gifs/search?'));
    assert.equal(new URL(url).searchParams.get('format_filter'), 'gif');
    assert.equal(new URL(url).searchParams.get('content_filter'), 'high');
    assert.equal(options.method, 'GET');
    return new Response('{"result":true,"data":{"data":[]}}', { status: 200 });
  }, async () => {
    const bad = await call('/klipy/v1/gifs/search?q=x&q=y');
    assert.equal(bad.status, 400);
    const good = await call('/klipy/v1/gifs/search?q=cat');
    assert.equal(good.status, 200);
    assert.equal((await good.json()).result, true);
  });
});

test('Stremio AES-GCM round trip binds ciphertext to account id', async () => {
  await withFetch(async (url) => {
    assert.ok(String(url).endsWith('/auth/v1/user'));
    return authUser();
  }, async () => {
    const raw = { addons: [{ transportUrl: 'https://example.com/manifest.json' }] };
    const sealed = await call('/stremio/v1/seal', 'POST', { configuration: raw });
    assert.equal(sealed.status, 200);
    const envelope = await sealed.json();
    assert.equal(envelope.format, 'stremio-server-v1');
    assert.ok(!JSON.stringify(envelope).includes('manifest.json'));
    const opened = await call('/stremio/v1/open', 'POST', { envelope });
    assert.equal(opened.status, 200);
    assert.deepEqual((await opened.json()).configuration, raw);
    const tampered = { ...envelope, ciphertext: envelope.ciphertext.replace(/^./, 'B') };
    const denied = await call('/stremio/v1/open', 'POST', { envelope: tampered });
    assert.equal(denied.status, 400);
  });
});

test('Stremio versioned sync preserves Supabase CAS result', async () => {
  await withFetch(async (url, options) => {
    if (String(url).endsWith('/auth/v1/user')) return authUser();
    assert.equal(new URL(url).pathname, '/rest/v1/rpc/stremio_configuration');
    const body = JSON.parse(options.body);
    assert.equal(body.p_expected_version, 1);
    assert.equal(body.p_payload.format, 'stremio-server-v1');
    return new Response(JSON.stringify({
      version: 2, accepted: true, payload: body.p_payload,
    }), { status: 200 });
  }, async () => {
    const result = await call('/stremio/v1/configuration', 'POST',
      { expectedVersion: 1, configuration: { addons: [] } });
    assert.equal(result.status, 200);
    const data = await result.json();
    assert.equal(data.version, 2);
    assert.equal(data.accepted, true);
    assert.deepEqual(data.configuration, { addons: [] });
  });
});

test('KLIPY fails closed without rate limiter', async () => {
  const withoutLimiter = { ...env, USER_LIMITER: null };
  await withFetch(async (url) => authUser(), async () => {
    const res = await worker.fetch(new Request('https://staging.example/klipy/v1/gifs/search?q=cat',
      { headers: { authorization: 'Bearer ' + token } }), withoutLimiter);
    assert.equal(res.status, 503);
  });
});
