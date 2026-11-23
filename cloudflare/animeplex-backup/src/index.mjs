// Private, token-authenticated JSON data snapshots from Supabase pg_cron/pg_net.
// This is an off-site DATA export, not a complete pg_dump/WAL disaster-recovery backup.
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
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health' && request.method === 'GET') {
      return json({ ok: true, project: 'animeplex', bucket: Boolean(env.BACKUPS),
        authenticated: typeof env.BACKUP_TOKEN === 'string' && env.BACKUP_TOKEN.length >= 32 });
    }
    if (!['/v1/snapshot', '/v1/status'].includes(url.pathname)) {
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
      const result = await env.BACKUPS.list({ prefix: 'snapshots/', limit: 100 });
      const latest = result.objects.map(x => ({ key: x.key, size: x.size, uploaded: x.uploaded }))
        .sort((a, b) => b.key.localeCompare(a.key))[0] || null;
      return json({ ok: true, latest, totalListed: result.objects.length,
        truncated: result.truncated });
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
    if (doc?.version !== 1 || doc?.project_ref !== PROJECT ||
        !Number.isFinite(Date.parse(doc.created_at)) ||
        !doc.tables || typeof doc.tables !== 'object' || Array.isArray(doc.tables) ||
        Object.keys(doc.tables).length < 1) {
      return json({ error: 'invalid snapshot structure' }, 400);
    }
    const now = new Date().toISOString();
    const key = 'snapshots/' + now.slice(0, 10) + '/' +
      now.replace(/[:.]/g, '-') + '-' + crypto.randomUUID() + '.json';
    const obj = await env.BACKUPS.put(key, body, {
      httpMetadata: { contentType: 'application/json' },
      customMetadata: { project: 'animeplex', format: 'json-data-v1' },
    });
    if (!obj || obj.size !== body.byteLength) {
      return json({ error: 'storage verification failed' }, 502);
    }
    return json({ ok: true, key, bytes: obj.size,
      tableCount: Object.keys(doc.tables).length }, 201);
  },
};
