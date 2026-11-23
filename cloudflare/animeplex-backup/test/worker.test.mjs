import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.mjs';

const objects = new Map();
const env = {
  BACKUP_TOKEN: 'a'.repeat(64),
  BACKUPS: {
    async put(key, bytes) {
      objects.set(key, bytes);
      return { size: bytes.byteLength };
    },
    async list() {
      return { objects: [...objects.entries()].map(([key, data]) =>
        ({key, size:data.byteLength, uploaded:new Date()})), truncated: false };
    },
  },
};
const base = 'https://example.test';
const headers = { authorization: 'Bearer ' + env.BACKUP_TOKEN,
  'content-type': 'application/json' };

test('health reports bound backup storage and credential without leaking it', async () => {
  const r = await worker.fetch(new Request(base + '/health'), env);
  assert.equal(r.status, 200);
  const s = await r.json();
  assert.equal(s.bucket, true);
  assert.equal(s.authenticated, true);
  assert.ok(!JSON.stringify(s).includes(env.BACKUP_TOKEN));
});

test('backup routes fail closed without bearer token', async () => {
  const status = await worker.fetch(new Request(base + '/v1/status'), env);
  assert.equal(status.status, 401);
  const denied = await worker.fetch(new Request(base + '/v1/snapshot',
    { method: 'POST', body: '{}' }), env);
  assert.equal(denied.status, 401);
});

test('rejects wrong project or incomplete data', async () => {
  const r = await worker.fetch(new Request(base + '/v1/snapshot',
    { method: 'POST', headers,
      body: JSON.stringify({version:1,project_ref:'wrong',created_at:new Date().toISOString(),tables:{'public.mylist':[]}}) }), env);
  assert.equal(r.status, 400);
});

test('stores private snapshot and allows authorized status only', async () => {
  const doc = {version:1,project_ref:'iwiujqjipotwvigvaaid',
    created_at:new Date().toISOString(), tables:{'public.mylist':[{title:'test'}]}};
  const r = await worker.fetch(new Request(base + '/v1/snapshot',
    { method: 'POST', headers, body: JSON.stringify(doc) }), env);
  assert.equal(r.status, 201);
  const data = await r.json();
  assert.equal(data.ok, true);
  assert.equal(data.tableCount, 1);
  assert.ok(data.key.startsWith('snapshots/'));
  const stat = await worker.fetch(new Request(base + '/v1/status',
    { headers:{authorization:headers.authorization} }),env);
  assert.equal(stat.status,200);
  assert.equal((await stat.json()).latest.key,data.key);
});
