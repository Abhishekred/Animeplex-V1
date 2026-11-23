// Private, authenticated, AES-256-GCM encrypted data snapshots from Supabase.
// NOTE: Data-only export, not a complete PostgreSQL pg_dump or point-in-time recovery.
const MAX_BYTES = 16 * 1024 * 1024;
const PROJECT = 'iwiujqjipotwvigvaaid';
const headers = { 'content-type': 'application/json', 'cache-control': 'no-store' };
function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers });
}
function same(a, b) {
  let delta = a.length ^ b.length;
  for (let i = 0, n = Math.max(a.length, b.length); i < n; i++) {
    delta |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return delta === 0;
}
async function aesKey(secret) {
  if (!/^[0-9a-f]{64}$/i.test(secret)) throw new Error('Invalid backup encryption key');
  const bytes = Uint8Array.from(secret.match(/.{2}/g), h => Number.parseInt(h, 16));
  return crypto.subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt', 'decrypt']);
}
async function encrypt(bytes, secret) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, await aesKey(secret), bytes));
  const stored = new Uint8Array(12 + ciphertext.length);
  stored.set(iv);
  stored.set(ciphertext, 12);
  return stored;
}
async function decrypt(bytes, secret) {
  if (bytes.length < 29) throw new Error('Truncated snapshot');
  const plaintext = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: bytes.subarray(0, 12) }, await aesKey(secret),
    bytes.subarray(12));
  return new Uint8Array(plaintext);
}
function validate(doc) {
  return doc?.version === 1 && doc?.project_ref === PROJECT &&
    typeof doc.created_at === 'string' &&
    Number.isFinite(Date.parse(doc.created_at)) &&
    doc.tables && typeof doc.tables === 'object' && !Array.isArray(doc.tables) &&
    Object.keys(doc.tables).length > 0 &&
    Object.values(doc.tables).every(Array.isArray);
}
async function readLimited(request) {
  const reader = request.body?.getReader();
  if (!reader) return null;
  const chunks = [];
  let bytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > MAX_BYTES) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (bytes === 0) return null;
  const result = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}
async function latest(env) {
  const result = await env.BACKUPS.list({ prefix: 'snapshots/', limit: 100 });
  const objects = result.objects.map(x => ({ key: x.key, size: x.size, uploaded: x.uploaded }))
    .sort((a, b) => b.key.localeCompare(a.key));
  return { latest: objects[0] || null, totalListed: objects.length,
    truncated: result.truncated };
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health' && request.method === 'GET') {
      return json({ ok: true, project: 'animeplex', bucket: Boolean(env.BACKUPS),
        authenticated: typeof env.BACKUP_TOKEN === 'string' && env.BACKUP_TOKEN.length >= 32,
        encryption: 'AES-256-GCM' });
    }
    if (!['/v1/snapshot', '/v1/status', '/v1/verify-latest'].includes(url.pathname)) {
      return json({ error: 'not found' }, 404);
    }
    const expected = typeof env.BACKUP_TOKEN === 'string' && env.BACKUP_TOKEN.length >= 32
      ? 'Bearer ' + env.BACKUP_TOKEN : '';
    const provided = request.headers.get('authorization') || '';
    if (!expected || provided.length > 256 || !same(provided, expected)) {
      return json({ error: 'unauthorized' }, 401);
    }
    if (!env.BACKUPS) return json({ error: 'backup storage missing' }, 503);
    if (url.pathname === '/v1/status' && request.method === 'GET') {
      return json({ ok: true, ...await latest(env) });
    }
    if (url.pathname === '/v1/verify-latest' && request.method === 'POST') {
      const { latest: entry } = await latest(env);
      if (!entry) return json({ error: 'no snapshot stored' }, 404);
      const saved = await env.BACKUPS.get(entry.key);
      if (!saved || saved.size > MAX_BYTES + 28) {
        return json({ error: 'snapshot unavailable or oversized' }, 503);
      }
      try {
        const bytes = new Uint8Array(await saved.arrayBuffer());
        const body = await decrypt(bytes, env.BACKUP_TOKEN);
        const doc = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(body));
        if (!validate(doc)) return json({ error: 'corrupt snapshot' }, 422);
        return json({ ok: true, format: 'encrypted-data-v1',
          key: entry.key, created_at: doc.created_at,
          tableCount: Object.keys(doc.tables).length,
          rowCount: Object.values(doc.tables).reduce((n, rows) => n + rows.length, 0) });
      } catch {
        return json({ error: 'decrypt or integrity verification failed' }, 422);
      }
    }
    if (url.pathname !== '/v1/snapshot' || request.method !== 'POST') {
      return json({ error: 'method not allowed' }, 405);
    }
    if (!request.headers.get('content-type')?.toLowerCase().startsWith('application/json')) {
      return json({ error: 'JSON only' }, 415);
    }
    const length = Number(request.headers.get('content-length') || 0);
    if (length > MAX_BYTES) return json({ error: 'too large' }, 413);
    const body = await readLimited(request);
    if (!body) return json({ error: 'empty or too large' }, 413);
    let doc;
    try { doc = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(body)); }
    catch { return json({ error: 'invalid snapshot JSON' }, 400); }
    if (!validate(doc)) return json({ error: 'invalid snapshot structure' }, 400);
    let encrypted;
    try { encrypted = await encrypt(body, env.BACKUP_TOKEN); }
    catch { return json({ error: 'encryption unavailable' }, 503); }
    const now = new Date().toISOString();
    const key = 'snapshots/' + now.slice(0, 10) + '/' +
      now.replace(/[:.]/g, '-') + '-' + crypto.randomUUID() + '.aes';
    const obj = await env.BACKUPS.put(key, encrypted, {
      httpMetadata: { contentType: 'application/octet-stream' },
      customMetadata: { project: 'animeplex', format: 'aes256gcm-json-v1' },
    });
    if (!obj || obj.size !== encrypted.byteLength) {
      return json({ error: 'storage verification failed' }, 502);
    }
    return json({ ok: true, key, bytes: obj.size, encrypted: true,
      tableCount: Object.keys(doc.tables).length }, 201);
  },
};
