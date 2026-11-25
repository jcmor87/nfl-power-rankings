import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { JSDOM } from 'jsdom';

const html = readFileSync(new URL('../pickem/index.html', import.meta.url), 'utf8');
let load = 0;

async function withApp(context, respond, exercise) {
  const dom = new JSDOM(html);
  const timers = new Map();
  const diagnostics = [];
  context.mock.method(globalThis, 'setInterval', (callback, interval) => {
    timers.set(interval, callback);
    return interval;
  });
  context.mock.method(globalThis, 'clearInterval', interval => timers.delete(interval));
  context.mock.method(console, 'warn', message => diagnostics.push(message));
  const priorDocument = globalThis.document;
  globalThis.document = dom.window.document;
  // Exercise Safari environments where these newer convenience APIs are absent.
  context.mock.method(AbortSignal, 'timeout', () => { throw new Error('Static timeout unavailable'); });
  Object.defineProperty(dom.window.Element.prototype, 'replaceChildren', { value: undefined });
  const requests = [];
  context.mock.method(globalThis, 'fetch', async (url, options) => {
    const path = new URL(url).pathname;
    requests.push(path);
    return respond(path, options, new URL(url).search);
  });
  try {
    const script = new URL('../pickem/app.mjs', import.meta.url);
    await import(script.href + '?test=' + (++load));
    const byId = id => dom.window.document.getElementById(id);
    byId('project').value = 'https://fixture.supabase.co';
    byId('publishable-key').value = 'sb_publishable_synthetic';
    const signIn = async (email = 'synthetic@example.com', password = 'synthetic-password') => {
      byId('email').value = email;
      byId('password').value = password;
      byId('sign-in').dispatchEvent(new dom.window.Event('submit', { cancelable: true }));
      await settle();
    };
    await exercise({ byId, signIn, timers, diagnostics, requests });
  } finally {
    globalThis.document = priorDocument;
    dom.window.close();
  }
}

const settle = () => new Promise(setImmediate);
const identity = { participant_id: 'person-2', server_time: '2026-11-25T00:00:00+00:00' };
const directory = [{ id: 'person-1', display_name: 'Synthetic A' }, { id: 'person-2', display_name: 'Synthetic B' }];
const responses = {
  '/auth/v1/token': { access_token: 'synthetic-token', expires_in: 3600 },
  '/rest/v1/rpc/pickem_identity': [identity],
  '/rest/v1/participants': directory,
  '/rest/v1/seasons': [],
  '/rest/v1/weeks': [],
};

function answer(path, replacements = {}) {
  if (path === '/auth/v1/logout') return new Response(null, { status: 204 });
  assert.ok(Object.hasOwn(responses, path), 'Unexpected request: ' + path);
  return Response.json(Object.hasOwn(replacements, path) ? replacements[path] : responses[path]);
}

function assertEmpty({ byId }, name) {
  assert.equal(byId('board').hidden, false);
  assert.equal(byId('participant-name').textContent, 'Signed in as ' + name);
  assert.equal(byId('status').textContent, '');
  assert.equal(byId('week').disabled, true);
  assert.equal(byId('results').textContent, 'No competition weeks are available.');
}

test('empty competition shows the authenticated participant and clears loading on initial load and polling', async context => {
  await withApp(context, answer, async app => {
    await app.signIn();
    assertEmpty(app, 'Synthetic B');
    await app.timers.get(30_000)();
    assertEmpty(app, 'Synthetic B');
    assert.deepEqual(app.diagnostics, []);
    assert.equal(app.requests.length, 9);
    app.byId('exit').click();
    await settle();
    assert.equal(app.byId('participant-name').textContent, '');
    assert.equal(app.timers.size, 0);
  });
});

test('postseason periods display round names and sort after regular-season weeks', async context => {
  const periods = [
    { id: 2, season_id: 1, week_number: 18, competition_phase: 'regular', status: 'complete' },
    { id: 3, season_id: 1, week_number: 1, competition_phase: 'postseason', status: 'active' },
  ];
  await withApp(context, path => {
    if (['games', 'teams', 'picks', 'weekly_results', 'season_standings']
      .some(table => path === '/rest/v1/' + table)) return Response.json([]);
    return answer(path, { '/rest/v1/weeks': periods, '/rest/v1/seasons': [{ id: 1, nfl_year: 2026 }] });
  }, async app => {
    await app.signIn();
    const select = app.byId('week');
    assert.deepEqual([...select.options].map(item => item.textContent),
      ['2026 · Wild Card', '2026 · Week 18']);
    assert.equal(select.value, '3');
    assert.deepEqual(app.diagnostics, []);
  });
});

test('a disputed kickoff shows both sources and locks at the earlier deadline', async context => {
  const game = { id: 7, source: 'balldontlie', status: 'scheduled', home_team_id: 1, away_team_id: 2,
    kickoff_at: '2026-11-25T00:10:00Z', reference_kickoff_at: '2026-11-24T23:55:00Z',
    pick_deadline_at: '2026-11-24T23:55:00Z', kickoff_reconciliation: 'earlier_deadline',
    schedule_verified_until: '2026-11-25T01:00:00Z' };
  await withApp(context, path => {
    if (path === '/rest/v1/games') return Response.json([game]);
    if (['teams', 'picks', 'weekly_results', 'season_standings'].some(table => path === '/rest/v1/' + table)) {
      return Response.json([]);
    }
    return answer(path, { '/rest/v1/weeks': [{ id: 1, season_id: 1, week_number: 12, status: 'active' }],
      '/rest/v1/seasons': [{ id: 1, nfl_year: 2026 }] });
  }, async app => {
    await app.signIn();
    const rendered = app.byId('games').textContent;
    assert.match(rendered, /BALLDONTLIE kickoff/);
    assert.match(rendered, /nflverse kickoff/);
    assert.match(rendered, /Conservative pick deadline/);
    assert.match(rendered, /Picks locked/);
    assert.ok([...app.byId('games').querySelectorAll('button')].every(button => button.disabled));
    assert.deepEqual(app.diagnostics, []);
  });
});

test('unexpected successful response shape reports a safe operation and error category', async context => {
  let invalid = true;
  await withApp(context, path => invalid && path === '/rest/v1/weeks' ?
    Response.json({ unexpected: 'synthetic-sensitive-body' }) : answer(path), async app => {
    await app.signIn();
    assert.match(app.byId('status').textContent, /weeks.*UnexpectedResponse/);
    assert.match(app.diagnostics.join(' '), /weeks.*UnexpectedResponse/);
    assert.doesNotMatch(app.diagnostics.join(' '), /synthetic-sensitive-body|synthetic-token|sb_publishable/);
    invalid = false;
    await app.timers.get(30_000)();
    assertEmpty(app, 'Synthetic B');
  });
});

test('a rendering exception is attributed to the render operation without logging its message', async context => {
  await withApp(context, answer, async app => {
    const target = app.byId('results');
    context.mock.method(target, 'append', () => { throw new TypeError('synthetic-private-render-error'); });
    await app.signIn();
    assert.match(app.diagnostics.join(' '), /render-board.*TypeError/);
    assert.doesNotMatch(app.diagnostics.join(' '), /synthetic-private-render-error/);
  });
});

test('an empty identity response continues to deny access', async context => {
  await withApp(context, path => answer(path, { '/rest/v1/rpc/pickem_identity': [] }), async app => {
    await app.signIn();
    assert.equal(app.byId('board').hidden, true);
    assert.match(app.byId('status').textContent, /does not have Pick’em access/);
    assert.equal(app.requests.length, 2);
  });
});

const local = process.env.PICKEM_FRONTEND_LOCAL_ORIGIN;
test('live local Auth and REST sign in both participants against an empty competition', { skip: !local }, async context => {
  assert.match(local, /^http:\/\/127\.0\.0\.1:\d+$/);
  const realFetch = globalThis.fetch;
  let lastResponse;
  await withApp(context, async (path, options, search) => {
    const response = await realFetch(local + path + search, options);
    assert.ok(response.ok, path + ' returned HTTP ' + response.status);
    lastResponse = path;
    return response;
  }, async app => {
    for (const [number, name] of [[1, 'Synthetic A'], [2, 'Synthetic B']]) {
      await app.signIn('synthetic-' + number + '@example.com', 'Local-fixture-password-' + number + '!');
      for (let i = 0; i < 100 && !app.timers.size; i++) await new Promise(resolve => setTimeout(resolve, 20));
      assert.ok(lastResponse);
      assertEmpty(app, name);
      app.byId('exit').click();
      await settle();
    }
    assert.deepEqual(app.diagnostics, []);
  });
});
