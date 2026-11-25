import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { createClient, normalizeGames, normalizeTeams } from '../pickem-data/balldontlie.mjs';
import { readSchedule } from '../pickem-data/nflverse-schedule.mjs';
import { reconcile } from '../pickem-data/reconcile.mjs';
import { teamCodes, postseasonRounds } from '../pickem-data/nfl-competition.mjs';

const directory = teamCodes.map((code, index) => ({ id: index + 1, abbreviation: code, full_name: 'Synthetic ' + code }));
const teams = normalizeTeams(directory);
const headers = 'game_id,season,game_type,week,gameday,gametime,home_team,away_team,home_score,away_score,venue';
const regular = { season: 2999, phase: 'regular', week: 1 };
const game = { id: 101, season: 2999, week: 1, postseason: false, date: '2999-09-10T20:00:00Z',
  updated_at: '2999-09-01T20:00:00Z', home_team: { id: 1 }, visitor_team: { id: 2 },
  status_state: 'scheduled' };
const row = 'g-1,2999,REG,1,2999-09-10,16:00,ARI,ATL,,,"Stadium, with quotes"';
const normalize = rows => normalizeGames({ data: rows, meta: {} }, regular);
const combine = (rows, csv = row) => reconcile({ ...regular, teams, observations: normalize(rows),
  reference: readSchedule(headers + '\n' + csv, regular) });

test('requires all 32 distinct current team codes and stable provider IDs', () => {
  assert.equal(normalizeTeams(directory.map(row => row.abbreviation === 'LA' ? { ...row, abbreviation: 'LAR' } : row)).length, 32);
  assert.throws(() => normalizeTeams(directory.slice(1)), /Incomplete/);
  assert.throws(() => normalizeTeams([...directory.slice(1), directory[1]]), /Duplicate NFL team abbreviation/);
});

test('pairs independent schedule identities and Eastern kickoff instants', () => {
  assert.equal(combine([game]).games[0].kickoff_at, game.date.replace('Z', '.000Z'));
  assert.throws(() => combine([game], row + '\n' + row.replace('g-1', 'g-2')), /coverage/);
  assert.throws(() => normalize([game, game]), /identity/);
  assert.throws(() => combine([{ ...game, date: '2999-09-10T21:00:00Z' }]), /Kickoff/);
  assert.equal(combine([{ ...game, date: null, status_state: 'postponed' }]).games[0].status, 'postponed');
});

test('requires corroborated finals, rejects malformed scores, and holds unverified cancellations', () => {
  const final = { ...game, status_state: 'final', status: 'Final/OT', home_team_score: 0, visitor_team_score: 0 };
  const scoredRow = row.replace('ARI,ATL,,,', 'ARI,ATL,0,0,');
  assert.deepEqual(combine([final], scoredRow).games.map(item => [item.status, item.home_score, item.away_score]), [['final', 0, 0]]);
  assert.throws(() => combine([final]), /score requires/);
  assert.throws(() => normalize([{ ...final, home_team_score: '0' }]), /Malformed/);
  const canceled = { ...game, status_state: 'canceled', home_team_score: null, visitor_team_score: null };
  assert.throws(() => combine([canceled]), /explicit corroboration/);
  const [reference] = readSchedule(headers + '\n' + row, regular);
  assert.equal(reconcile({ ...regular, teams, observations: normalize([canceled]),
    reference: [{ ...reference, status: 'canceled' }] }).games[0].status, 'canceled');
});

test('maps postseason feed game types and enforces round counts without reusing regular periods', () => {
  for (const [week, round] of Object.entries(postseasonRounds)) {
    const period = { season: 2999, phase: 'postseason', week: Number(week) };
    const rows = Array.from({ length: round.games }, (_, i) => ({ ...game, id: i + 101, week: Number(week),
      postseason: true, home_team: { id: i * 2 + 1 }, visitor_team: { id: i * 2 + 2 } }));
    const csv = rows.map((_, i) => `p${i},2999,${round.feed},20,2999-09-10,16:00,${teamCodes[i * 2]},${teamCodes[i * 2 + 1]},,,field`).join('\n');
    const reference = readSchedule(headers + '\n' + csv, period);
    const observations = normalizeGames({ data: rows, meta: {} }, period);
    assert.equal(reconcile({ ...period, teams, observations, reference }).games.length, round.games);
    assert.throws(() => reconcile({ ...period, teams, observations: observations.slice(1), reference }), /coverage/);
  }
});

test('paginates documented endpoints and paces bounded rate-limit and outage retries', async () => {
  let clock = 0;
  const seen = [];
  const client = createClient({ key: 'synthetic', now: () => clock, sleep: async ms => { clock += ms; },
    fetcher: async url => {
      seen.push([url, clock]);
      if (seen.length === 1) return new Response(null, { status: 429, headers: { 'retry-after': '20' } });
      if (seen.length === 2) return Response.json({ data: [game], meta: { next_cursor: 16 } });
      if (seen.length === 3) return Response.json({ data: [{ ...game, id: 102 }], meta: {} });
      return new Response(null, { status: 503 });
    },
  });
  assert.equal((await client.week(regular)).length, 2);
  assert.equal(seen[1][1], 20_000);
  assert.equal(seen[2][0].searchParams.get('cursor'), '16');
  await assert.rejects(client.week({ ...regular, phase: 'postseason' }), /HTTP 503/);
  assert.equal(seen[3][0].searchParams.get('postseason'), 'true');
  assert.equal(seen.length, 6);
  assert.ok(seen.slice(1).every(([, at], i) => at - seen[i][1] >= 15_100));
});


test('CLI defaults to read-only even when write credentials are configured', async () => {
  const fixtures = JSON.stringify({ directory, game, csv: headers + '\n' + row });
  const mock = `
    const { directory, game, csv } = ${fixtures};
    let tick = 0;
    Date.now = () => ++tick * 20000;
    globalThis.fetch = async (target, options) => {
      const url = new URL(target);
      if (options.method && options.method !== 'GET') throw new Error('Unexpected write');
      if (url.hostname === 'api.balldontlie.io' && url.pathname.endsWith('/teams')) {
        return Response.json({ data: directory });
      }
      if (url.hostname === 'api.balldontlie.io' && url.pathname.endsWith('/games')) {
        return Response.json({ data: [game], meta: {} });
      }
      if (url.hostname === 'github.com') return new Response(csv);
      throw new Error('Unexpected database or provider request');
    };
  `;
  const cli = fileURLToPath(new URL('../pickem-jobs/sync-nfl.mjs', import.meta.url));
  const { stdout, stderr } = await promisify(execFile)(process.execPath, [
    '--import', 'data:text/javascript,' + encodeURIComponent(mock), cli,
    '--season=2999', '--week=1',
  ], { env: { ...process.env, BALLDONTLIE_API_KEY: 'synthetic-local-fixture',
    SUPABASE_URL: 'https://fixture.supabase.co', PICKEM_SYNC_CONFIRM_ORIGIN: 'https://fixture.supabase.co',
    SUPABASE_SECRET_KEY: 'sb_secret_synthetic-local-fixture' } });
  assert.deepEqual(JSON.parse(stdout), {
    mode: 'dry-run', season: 2999, phase: 'regular', week: 1, teams: 32, games: 1, statuses: { scheduled: 1 },
  });
  assert.equal(stderr, '');
});

test('Teams accepts the data-only envelope and rejects invalid directory records', async () => {
  const load = payload => createClient({ key: 'synthetic', fetcher: async url => {
    assert.equal(url.pathname, '/nfl/v1/teams');
    assert.equal(url.searchParams.get('per_page'), '100');
    assert.equal(url.searchParams.has('cursor'), false);
    return Response.json(payload);
  } }).teams();
  assert.deepEqual(await load({ data: directory }), teams);

  const cases = [
    [{}, /data array/],
    [{ data: directory.slice(1) }, /Incomplete NFL team directory: expected 32 teams, received 31/],
    [{ data: [{ ...directory[0], id: directory[1].id }, ...directory.slice(1)] }, /Duplicate NFL team ID/],
    [{ data: [{ ...directory[0], abbreviation: directory[1].abbreviation }, ...directory.slice(1)] }, /Duplicate NFL team abbreviation/],
    [{ data: [null, ...directory.slice(1)] }, /Malformed NFL team record/],
    [{ data: [{ ...directory[0], full_name: ' ' }, ...directory.slice(1)] }, /Malformed NFL team record/],
    [{ data: [{ ...directory[0], abbreviation: 'SYN' }, ...directory.slice(1)] }, /Unexpected NFL team abbreviation/],
    [{ data: directory, meta: { next_cursor: 32 } }, /unexpectedly contains a pagination cursor/],
  ];
  for (const [payload, error] of cases) await assert.rejects(load(payload), error);
});

test('Games still requires metadata and rejects invalid pagination cursors', async () => {
  for (const [payload, error] of [
    [{ data: [game] }, /pagination metadata/],
    [{ data: [game], meta: [] }, /pagination metadata/],
    [{ data: [game], meta: { next_cursor: '32' } }, /Invalid BALLDONTLIE pagination cursor/],
  ]) {
    const client = createClient({ key: 'synthetic', fetcher: async () => Response.json(payload) });
    await assert.rejects(client.week(regular), error);
  }
});

test('CLI prints a specific safe validation diagnostic without echoing provider values', async () => {
  const cli = fileURLToPath(new URL('../pickem-jobs/sync-nfl.mjs', import.meta.url));
  const mock = "globalThis.fetch = async () => Response.json({ data: [{ id: 1, abbreviation: 'SYNTHETIC_PRIVATE_VALUE', full_name: 'Synthetic' }] });";
  await assert.rejects(promisify(execFile)(process.execPath, [
    '--import', 'data:text/javascript,' + encodeURIComponent(mock), cli,
    '--season=2999', '--week=1',
  ], { env: { ...process.env, BALLDONTLIE_API_KEY: 'synthetic-private-key' } }), error => {
    assert.equal(error.code, 1);
    assert.match(error.stderr, /team validation.*Unexpected NFL team abbreviation at record 1/);
    assert.doesNotMatch(error.stderr, /SYNTHETIC_PRIVATE_VALUE|synthetic-private-key/);
    return true;
  });
});
