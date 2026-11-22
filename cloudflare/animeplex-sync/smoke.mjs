// Read-only compatibility smoke check. Requires a real test account JWT.
// Usage: ANIMEPLEX_SYNC_URL=https://YOUR_WORKER.workers.dev ANIMEPLEX_TEST_JWT=... node smoke.mjs
const base = process.env.ANIMEPLEX_SYNC_URL?.replace(/\/+$/, '');
const jwt = process.env.ANIMEPLEX_TEST_JWT;
if (!base || !/^https:\/\//.test(base) || !jwt) {
  console.error('Provide ANIMEPLEX_SYNC_URL (HTTPS) and ANIMEPLEX_TEST_JWT (test account only).');
  process.exit(2);
}
const auth = { authorization: 'Bearer ' + jwt };
const checks = [
  ['/health', 'GET'],
  ['/mylist?select=item_id&limit=1', 'GET'],
  ['/history?select=show_id&limit=1', 'GET'],
  ['/viewer_profiles?select=profile_id&limit=1', 'GET'],
  ['/mylist_sync_clock?select=version&limit=1', 'GET'],
  ['/rpc/profile_lock', 'POST', { p_action: 'status' }],
  ['/klipy/v1/gifs/search?q=anime', 'GET'],
  ['/stremio/v1/seal', 'POST', { configuration: { addons: [] } }],
];
let errors = 0;
for (const [path, method, body] of checks) {
  try {
    const r = await fetch(base + path, { method, headers: { ...auth, ...(body ? {'content-type':'application/json'}:{}) },
      ...(body ? { body: JSON.stringify(body) } : {}) });
    const text = await r.text();
    if (!r.ok) { errors++; console.error('FAIL ' + method + ' ' + path + ' -> ' + r.status); }
    else { console.log('OK   ' + method + ' ' + path);
      if (path.endsWith('/seal')) {
        const envelope = JSON.parse(text);
        const open = await fetch(base + '/stremio/v1/open', {
          method: 'POST', headers: { ...auth, 'content-type':'application/json' },
          body: JSON.stringify({ envelope }),
        });
        const result = await open.json();
        if (!open.ok || JSON.stringify(result.configuration) !== JSON.stringify({ addons: [] })) {
          errors++; console.error('FAIL Stremio envelope round-trip');
        } else console.log('OK   Stremio envelope round-trip');
      }
    }
  } catch (error) {
    errors++; console.error('FAIL ' + path + ': ' + String(error));
  }
}
if (errors) { console.error(errors + ' compatibility checks failed'); process.exit(1); }
console.log('Read-only staging API smoke checks passed. Writes and old VPS data migration remain unverified.');
