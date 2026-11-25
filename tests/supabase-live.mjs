#!/usr/bin/env node
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';

import { loadConnection, makeRequest, reconcileMutation, RequestFailure } from './supabase-requests.mjs';

const existingAccounts = process.argv.includes('--hosted-existing');
const preflightOnly = process.argv.includes('--preflight');
const administeredAccounts = [1, 2].map(i => ({
  email: process.env['PICKEM_TEST_EMAIL_' + i],
  password: process.env['PICKEM_TEST_PASSWORD_' + i],
}));
const namespace = 'synthetic-' + randomUUID();
const fixtureTables = ['seasons', 'weeks', 'teams', 'games', 'picks',
  'weekly_results', 'season_standings', 'email_log', 'job_runs', 'audit_log'];
const cleanup = [];
let request, admin, anonymous, baseline;
let stage = 'configuration';

function beginStage(name) {
  stage = name;
  console.log('STAGE ' + name);
}

function report(error) {
  console.error('FAIL ' + stage + ' · ' +
    (error instanceof RequestFailure ? error.message :
      stage === 'configuration' ? 'Check the project origin, key types and Node.js version.' :
        'Assertion or verification failed. Inspect the stage above.'));
}

const selectors = {
  seasons: ['nfl_year'], weeks: ['season_id', 'week_number'], teams: ['abbreviation', 'name'],
  games: ['source', 'source_game_id'], participants: ['auth_user_id', 'display_name'],
};

function scopedPath(table, filter) {
  return table + '?' + new URLSearchParams(Object.entries(filter).map(([key, value]) => [key, 'eq.' + value]));
}

async function insert(table, row) {
  const filter = Object.fromEntries(selectors[table].map(key => [key, row[key]]));
  const path = scopedPath(table, filter);
  assert.equal((await read(admin, path)).length, 0);
  // Register the exact fixture selector before sending the POST. The server
  // can commit even when the client never receives the response.
  const undo = () => removeFixture(table, filter);
  cleanup.push(undo);
  let result;
  try {
    result = await request('Create ' + table, '/rest/v1/' + table, {
      actor: admin, method: 'POST', body: row, prefer: 'return=representation', status: 201,
    });
  } catch (error) {
    if (error instanceof RequestFailure && !error.uncertain) cleanup.pop();
    throw error;
  }
  assert.equal(result.value.length, 1);
  const [record] = result.value;
  filter.id = record.id;
  return record;
}

async function removeFixture(table, filter) {
  const path = scopedPath(table, filter);
  if ((await read(admin, path)).length === 0) return;
  await reconcileMutation(
    () => request('Cleanup ' + table, '/rest/v1/' + path, { actor: admin, method: 'DELETE', status: 204 }),
    async () => (await read(admin, path)).length === 0,
  );
}

async function listUsers() {
  const { value } = await request('List Auth accounts', '/auth/v1/admin/users?page=1&per_page=100', { actor: admin });
  assert.ok(Array.isArray(value?.users) && value.users.length < 100, 'Expected a bounded Auth account list');
  return value.users;
}

async function removeIdentity(email) {
  const find = async () => (await listUsers()).find(user => user.email === email);
  const user = await find();
  if (!user) return;
  await reconcileMutation(
    () => request('Cleanup synthetic Auth user', '/auth/v1/admin/users/' + user.id, { actor: admin, method: 'DELETE' }),
    async () => !await find(),
  );
}

const patch = (table, id, body) => request('Update ' + table, '/rest/v1/' + table + '?id=eq.' + id, {
  actor: admin, method: 'PATCH', body, prefer: 'return=representation', status: 200,
}).then(({ value }) => {
  assert.equal(value.length, 1, 'One fixture updated');
  return value[0];
});

async function createIdentity(index) {
  const email = namespace + '-' + index + '@example.com';
  const password = randomUUID() + 'aZ9!';
  cleanup.push(() => removeIdentity(email));
  const { value: user } = await request('Create confirmed synthetic identity', '/auth/v1/admin/users', {
    actor: admin, method: 'POST', body: { email, password, email_confirm: true },
  });
  assert.ok(user.id, 'Synthetic Auth user created');
  return signIn({ email, password }, user.id);
}

async function signIn({ email, password }, expectedId) {
  const { value: session } = await request('Sign in with password', '/auth/v1/token?grant_type=password', {
    method: 'POST', body: { email, password },
  });
  assert.ok(session.access_token && session.user.id && (!expectedId || session.user.id === expectedId), 'Auth returned the expected session');
  return { id: session.user.id, key: anonymous.key, token: session.access_token };
}

const read = async (actor, path) => (await request('Read ' + path.split('?')[0], '/rest/v1/' + path,
  { actor, status: 200 })).value;

const submit = (actor, game, team, expected = {}) => request('Submit pick', '/rest/v1/rpc/submit_pick', {
  actor, method: 'POST', body: { p_game_id: game.id, p_team_id: team.id }, ...expected,
});

async function checkEmptyCompetition() {
  for (const table of fixtureTables) {
    assert.equal((await read(admin, table + '?limit=1')).length, 0, 'Expected an empty competition');
  }
}

const listParticipants = () => read(admin, 'participants?select=id,auth_user_id,seat,active&order=seat');

async function preflight() {
  beginStage('read-only connectivity and credentials');
  await request('Check publishable key and Auth connectivity', '/auth/v1/health', { status: 200 });
  await request('Confirm publishable key has anonymous privileges', '/rest/v1/games?limit=1',
    { status: [401, 403], code: '42501' });
  const users = await listUsers();
  const enrolled = await listParticipants();
  await checkEmptyCompetition();
  if (existingAccounts) {
    assert.equal(enrolled.length, 2);
    assert.equal(users.length, 2);
    assert.ok(enrolled.every((row, i) => row.seat === i + 1 && row.active &&
      users.some(user => user.id === row.auth_user_id && user.email === administeredAccounts[i].email) &&
      administeredAccounts[i].email === 'pickem-test' + (i + 1) + '@example.com'));
  } else {
    assert.deepEqual(enrolled, []);
    assert.deepEqual(users, []);
  }
  baseline = { participants: enrolled, userIds: users.map(user => user.id).sort() };
  console.log('PASS read-only connectivity, key access and empty competition');
}

async function run() {
  await preflight();
  if (preflightOnly) return;
  beginStage('authenticate participants and check public registration');
  let alice, bob, outsider, a, b;
  if (existingAccounts) {
    [a, b] = baseline.participants;
    alice = await signIn(administeredAccounts[0], a.auth_user_id);
    bob = await signIn(administeredAccounts[1], b.auth_user_id);
    // Public signup uses the same confirmed synthetic identity, with no real recipient.
    await request('Public signup disabled', '/auth/v1/signup', { method: 'POST',
      body: { email: administeredAccounts[0].email, password: randomUUID() + 'aZ9!' }, status: 422,
      code: 'signup_disabled' });
    beginStage('create synthetic outsider');
    // A separate auto-confirmed identity exercises a valid but unlinked Auth token.
    outsider = await createIdentity(3);
  } else {
    beginStage('create synthetic Auth fixtures');
    alice = await createIdentity(1);
    bob = await createIdentity(2);
    outsider = await createIdentity(3);
    a = await insert('participants', { auth_user_id: alice.id, display_name: 'Synthetic A', seat: 1, active: true });
    b = await insert('participants', { auth_user_id: bob.id, display_name: 'Synthetic B', seat: 2, active: true });
  }
  beginStage('create synthetic competition fixtures');
  const season = await insert('seasons', { nfl_year: 2999 });
  const week = await insert('weeks', { season_id: season.id, week_number: 1, status: 'active', expected_games: 2 });
  const home = await insert('teams', { abbreviation: 'SYN-A', name: 'Synthetic Home' });
  const away = await insert('teams', { abbreviation: 'SYN-B', name: 'Synthetic Away' });
  const third = await insert('teams', { abbreviation: 'SYN-C', name: 'Synthetic Third' });
  const future = new Date(Date.now() + 600_000).toISOString();
  const gameDefaults = { week_id: week.id, home_team_id: home.id, source: namespace,
    status: 'scheduled', kickoff_at: future };
  const game = await insert('games', { ...gameDefaults, away_team_id: away.id, source_game_id: 'privacy' });
  const boundary = await insert('games', { ...gameDefaults, away_team_id: third.id, source_game_id: 'boundary' });
  for (const fixture of [game, boundary]) cleanup.push(() => removeFixture('picks', { game_id: fixture.id }));

  beginStage('anonymous and outsider access');
  await request('Anonymous table access', '/rest/v1/games', { status: [401, 403], code: '42501' });
  await submit(anonymous, game, home, { status: [401, 403], code: '42501' });
  assert.deepEqual(await read(outsider, 'games'), []);
  assert.deepEqual(await read(outsider, 'participants?select=id,display_name'), []);
  await submit(outsider, game, home, { status: 403, code: '42501' });
  console.log('PASS anonymous and unlinked Auth access');

  beginStage('restricted columns, write denial and pick privacy');
  const directory = await read(alice, 'participants?select=id,display_name');
  assert.equal(directory.length, 2);
  for (const row of directory) assert.deepEqual(Object.keys(row).sort(), ['display_name', 'id']);
  for (const column of ['auth_user_id', 'seat', 'active']) {
    await request('Restricted participant column', '/rest/v1/participants?select=' + column,
      { actor: alice, status: 403, code: '42501' });
  }
  await request('Participant wildcard access', '/rest/v1/participants?select=*',
    { actor: alice, status: 403, code: '42501' });
  await request('Operational ledger access', '/rest/v1/email_log',
    { actor: alice, status: 403, code: '42501' });

  await submit(bob, game, home);
  await submit(bob, game, away);
  assert.equal((await read(bob, 'picks?game_id=eq.' + game.id))[0].team_id, away.id);
  await submit(alice, game, home);
  const own = 'picks?game_id=eq.' + game.id;
  const peer = own + '&participant_id=eq.' + b.id;
  for (const [method, body, suffix] of [
    ['POST', { participant_id: b.id, game_id: game.id, team_id: home.id, updated_at: future }, ''],
    ['PATCH', { team_id: home.id }, '?game_id=eq.' + game.id],
    ['DELETE', undefined, '?game_id=eq.' + game.id],
  ]) {
    await request('Direct pick mutation', '/rest/v1/picks' + suffix,
      { actor: alice, method, body, status: 403, code: '42501' });
  }
  await request('Direct final verification mutation', '/rest/v1/games?id=eq.' + game.id,
    { actor: alice, method: 'PATCH', body: { final_verified_at: future }, status: 403, code: '42501' });
  assert.deepEqual((await read(alice, own)).map(pick => pick.participant_id), [a.id]);
  assert.deepEqual(await read(alice, peer), []);
  if (existingAccounts || process.argv.includes('--phase3')) {
    const { value } = await request('Read current participant identity', '/rest/v1/rpc/pickem_identity',
      { actor: alice, method: 'POST', body: {} });
    assert.equal(value[0].participant_id, a.id);
    assert.equal((await read(alice, 'picks?participant_id=eq.' + a.id + '&games.week_id=eq.' + week.id +
      '&select=game_id,team_id,games!inner(week_id)')).length, 1);
    assert.deepEqual(await read(alice, 'weekly_results?select=week_id,participant_id,points,rank,weeks!inner(season_id,week_number)' +
      '&weeks.season_id=eq.' + season.id), []);
  }
  assert.deepEqual(await read(outsider, own), []);
  await submit(alice, game, third, { status: 400, code: '22023' });
  console.log('PASS restricted columns, write denial and pre-final privacy');

  beginStage('concurrent picks, kickoff and reschedule');
  const concurrent = await Promise.allSettled(Array.from({ length: 6 }, (_, i) =>
    submit(alice, game, i % 2 === 0 ? away : home)));
  for (const result of concurrent) if (result.status === 'rejected') throw result.reason;
  assert.equal((await read(alice, own)).length, 1, 'Concurrent updates leave one pick');

  const { serverTime } = await request('Get server clock', '/rest/v1/games?id=eq.' + boundary.id, { actor: admin });
  assert.ok(Number.isFinite(serverTime), 'Expected HTTP server Date header');
  const deadline = serverTime + 8000;
  await patch('games', boundary.id, { kickoff_at: new Date(deadline).toISOString() });
  const before = await submit(alice, boundary, home);
  assert.ok(before.serverTime < deadline, 'Accepted before the observed kickoff');
  await delay(Math.max(0, deadline - serverTime));
  const after = await submit(alice, boundary, third, { status: 400, code: '22023' });
  assert.ok(after.serverTime >= deadline, 'Denied at or after the observed kickoff');
  const boundaryPicks = await read(alice, 'picks?game_id=eq.' + boundary.id);
  assert.equal(boundaryPicks.length, 1);
  assert.equal(boundaryPicks[0].team_id, home.id, 'Late write preserves the prior pick');
  if (existingAccounts || process.argv.includes('--phase3')) {
    const moved = await patch('games', boundary.id, { kickoff_at: future });
    assert.ok(moved.picks_locked_at, 'Moving a lapsed kickoff preserves its lock');
    await submit(alice, boundary, third, { status: 400, code: '22023' });
  }
  console.log('PASS concurrent submissions and kickoff crossing');

  beginStage('verified-final disclosure and seat revocation');
  const finalTime = new Date().toISOString();
  await patch('games', game.id, { status: 'in_progress', started_at: finalTime });
  assert.deepEqual(await read(alice, peer), [], 'In-progress game hides the peer pick');
  await patch('games', game.id, { status: 'final', home_score: 2, away_score: 1 });
  assert.deepEqual(await read(alice, peer), [], 'Unverified final still hides the peer pick');
  await patch('games', game.id, { final_verified_at: finalTime });
  assert.equal((await read(alice, peer)).length, 1, 'Verified final reveals the peer pick');
  if (existingAccounts) cleanup.push(async () => {
    const active = async () => (await listParticipants()).some(row => row.id === a.id && row.active);
    if (!await active()) await reconcileMutation(() => patch('participants', a.id, { active: true }), active);
  });
  await patch('participants', a.id, { active: false });
  assert.deepEqual(await read(alice, own), [], 'Existing token immediately loses access');
  assert.deepEqual(await read(alice, 'games'), []);
  await submit(alice, boundary, home, { status: 403, code: '42501' });
  assert.equal((await read(bob, own)).length, 2, 'Revoking A preserves B’s access');
  console.log('PASS verified-final disclosure and account revocation');
}

try {
  const { origin, publicKey, serviceKey } = loadConnection(process.env);
  if (existingAccounts && !preflightOnly && administeredAccounts.some(account => !account.password)) {
    throw new Error('Missing temporary seat passwords.');
  }
  admin = { key: serviceKey };
  anonymous = { key: publicKey };
  request = makeRequest({ origin, publicKey });
  await run();
} catch (error) {
  report(error);
  process.exitCode = 1;
} finally {
  if (baseline && !preflightOnly) {
    beginStage('reconcile and verify cleanup');
    let cleanupFailed = false;
    for (const action of cleanup.reverse()) {
      try { await action(); } catch (error) {
        report(error);
        cleanupFailed = true;
      }
    }
    try {
      await checkEmptyCompetition();
      assert.deepEqual(await listParticipants(), baseline.participants);
      assert.deepEqual((await listUsers()).map(user => user.id).sort(), baseline.userIds);
      console.log('PASS cleanup verified against the original competition and Auth state');
    } catch (error) {
      report(error);
      cleanupFailed = true;
    }
    if (cleanupFailed) {
      process.exitCode = 1;
      console.error('Cleanup could not be fully verified. Inspect only synthetic fixtures for run ' + namespace);
    }
  }
}
