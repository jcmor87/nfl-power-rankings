import assert from 'node:assert/strict';
import test from 'node:test';
import { loadConnection, makeRequest, reconcileMutation, RequestFailure } from './supabase-requests.mjs';

const publicKey = 'sb_publishable_synthetic';
const serviceKey = 'sb_secret_synthetic';
const origin = 'https://fixture.supabase.co';
const endpoint = '/auth/v1/admin/users';
const ok = () => Response.json({});
const failure = code => Object.assign(new TypeError('private URL and credentials'), {
  cause: Object.assign(new Error('private network message'), { code }),
});

test('configuration trims URL and keys, tolerates a trailing slash, and rejects API paths and swapped opaque keys', () => {
  const env = { PICKEM_TEST_URL: ' ' + origin + '/', PICKEM_TEST_CONFIRM_ORIGIN: origin,
    PICKEM_TEST_PUBLIC_KEY: ' ' + publicKey, PICKEM_TEST_SERVICE_KEY: serviceKey + ' ' };
  assert.deepEqual(loadConnection(env), { origin, publicKey, serviceKey });
  assert.throws(() => loadConnection({ ...env, PICKEM_TEST_URL: origin + '/rest/v1' }), /matching Supabase project origins/);
  assert.throws(() => loadConnection({ ...env, PICKEM_TEST_PUBLIC_KEY: serviceKey,
    PICKEM_TEST_SERVICE_KEY: publicKey }), /matching prompts/);
});

test('uses apikey for opaque keys and bearer for sessions and legacy JWT keys', async () => {
  const seen = [];
  const request = makeRequest({ origin, publicKey, fetcher: async (url, init) => {
    assert.equal(url, origin + endpoint);
    assert.equal(init.redirect, 'manual');
    seen.push(init.headers);
    return ok();
  } });
  await request('publishable', endpoint);
  await request('service', endpoint, { actor: { key: serviceKey } });
  await request('session', endpoint, { actor: { key: publicKey, token: 'synthetic.session.jwt' } });
  await request('legacy', endpoint, { actor: { key: 'legacy.service.jwt' } });
  assert.deepEqual(seen, [
    { apikey: publicKey }, { apikey: serviceKey },
    { apikey: publicKey, Authorization: 'Bearer synthetic.session.jwt' },
    { apikey: 'legacy.service.jwt', Authorization: 'Bearer legacy.service.jwt' },
  ]);
});

test('transient GET failures retry twice and report a sanitized network cause', async () => {
  let calls = 0;
  const logs = [];
  const request = makeRequest({ origin, publicKey, fetcher: async () => {
    calls++;
    throw failure('ECONNRESET');
  }, pause: async () => {}, retryLog: message => logs.push(message) });
  await assert.rejects(request('read fixture', endpoint + '/private-id?secret=private-value'),
    error => error.message ===
      'GET /auth/v1/admin/users/:id · HTTP unavailable · read fixture · ECONNRESET');
  assert.equal(calls, 3);
  assert.equal(logs.length, 2);
  assert.doesNotMatch(logs.join(' '), /private|sb_publishable|https:/);
});

test('a read can recover within the retry limit, but a write receiving 503 is not replayed', async () => {
  let calls = 0;
  const request = makeRequest({ origin, publicKey, fetcher: async () =>
    ++calls === 1 ? Response.json({}, { status: 503 }) : ok(),
  pause: async () => {}, retryLog: () => {} });
  await request('read fixture', endpoint);
  assert.equal(calls, 2);
  calls = 0;
  await assert.rejects(request('write fixture', endpoint, { method: 'POST' }),
    error => error.uncertain && error.message.includes('HTTP 503'));
  assert.equal(calls, 1);
});

test('HTTP failures include the status and omit backend body and redirect destination', async () => {
  for (const status of [301, 401]) {
    let calls = 0;
    const request = makeRequest({ origin, publicKey, fetcher: async () => {
      calls++;
      return new Response(JSON.stringify({ code: serviceKey }), { status,
        headers: { Location: 'https://private.example/path' } });
    } });
    await assert.rejects(request('read protected endpoint', endpoint), error =>
      error.message.includes('HTTP ' + status) && !/private|sb_secret/.test(error.message));
    assert.equal(calls, 1);
  }
});

test('a lost mutation response is never retried and cleanup verifies the outcome by reading', async () => {
  let writes = 0, reads = 0;
  const request = makeRequest({ origin, publicKey, fetcher: async () => {
    writes++;
    throw failure('UND_ERR_SOCKET');
  } });
  await reconcileMutation(() => request('delete synthetic user', endpoint + '/fixture', { method: 'DELETE' }),
    async () => { reads++; return true; });
  assert.equal(writes, 1);
  assert.equal(reads, 1);
  await assert.rejects(reconcileMutation(
    () => request('create fixture', endpoint, { method: 'POST', body: {} }),
    async () => false), RequestFailure);
  assert.equal(writes, 2);
});
