import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, rm, writeFile, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';
import { checkLeaseHealth, familyPeriods, inFamily, periodKey, selectFamilyPeriods } from '../pickem-jobs/family-periods.mjs';
import { openSchedule } from '../pickem-data/nflverse-schedule.mjs';
import { createClient } from '../pickem-data/balldontlie.mjs';

const empty = { games: [], pending: false };
const periodRow = (phase, week_number, status) => ({ competition_phase: phase, week_number, status });

test('family scope starts at Week 13 and covers only the 2026 season through Super Bowl', () => {
  assert.deepEqual(familyPeriods.map(periodKey),
    ['regular:13','regular:14','regular:15','regular:16','regular:17','regular:18',
      'postseason:1','postseason:2','postseason:3','postseason:5']);
  assert.equal(inFamily({ season: 2026, phase: 'regular', week: 12 }), false);
  assert.equal(inFamily({ season: 2025, phase: 'postseason', week: 5 }), false);
});

test('finds the opening week, upcoming periods and unresolved live periods automatically', () => {
  const select = (now, existing = []) =>
    selectFamilyPeriods({ now: Date.parse(now), existing, schedule: () => empty }).map(periodKey);
  assert.deepEqual(select('2026-11-25T22:00:00Z'), []);
  assert.deepEqual(select('2026-12-03T22:00:00Z'), ['regular:13','regular:14']);
  assert.deepEqual(select('2027-01-19T17:00:00Z', [
    periodRow('regular', 12, 'active'), periodRow('regular', 13, 'active'),
  ]), ['regular:13']);
});

test('daily correction selects a completed period and ignores earlier family history outside the scope', () => {
  const existing = [periodRow('regular', 12, 'complete'), periodRow('regular', 13, 'complete')];
  const schedule = p => p.week === 13 ?
    { games: [{ kickoffAt: '2026-12-07T20:00:00Z' }], pending: false } : empty;
  const due = hour => selectFamilyPeriods({ schedule, existing, now: Date.parse('2026-12-14T' + hour + ':17:00Z') })
    .map(periodKey);
  assert.ok(due('12').includes('regular:13'));
  assert.ok(!due('13').includes('regular:13'));
  assert.ok(!due('12').includes('regular:12'));
});

test('unassigned postseason matchups wait without error until the period has full identities', async () => {
  const csv = [
    'game_id,season,game_type,week,gameday,gametime,home_team,away_team,home_score,away_score',
    'fixture,2026,SB,22,2027-02-14,18:30,TBD,TBD,,',
  ].join('\n');
  const schedule = openSchedule(csv);
  const period = { season: 2026, phase: 'postseason', week: 5 };
  assert.deepEqual(schedule(period, { discovery: true }), { games: [], pending: true });
  const options = { existing: [], now: Date.parse('2027-02-10T21:00:00Z') };
  assert.deepEqual(selectFamilyPeriods({ ...options, schedule: p => schedule(p, { discovery: true }) }), []);
  assert.deepEqual(selectFamilyPeriods({ ...options,
    schedule: p => openSchedule(csv.replace('TBD,TBD', 'ARI,ATL'))(p, { discovery: true }) }), [period]);
  const pending = () => createClient({ key: 'synthetic', fetcher: async () => Response.json({ data: [], meta: {} }) });
  assert.equal(await pending().week({ ...period, allowPending: true }), null);
  await assert.rejects(pending().week(period), /Incomplete/);
});

test('lease warnings apply to still-open picks and distinguish expiration from a normal cutoff', () => {
  const now = Date.parse('2026-12-03T21:00:00Z');
  const game = (pick_deadline_at, schedule_verified_until) => ({ pick_deadline_at, schedule_verified_until });
  assert.doesNotThrow(() => checkLeaseHealth([game('2026-12-04T01:15:00Z','2026-12-03T23:00:00Z')], now));
  assert.doesNotThrow(() => checkLeaseHealth([game('2026-12-03T21:30:00Z','2026-12-03T21:45:00Z')], now));
  assert.doesNotThrow(() => checkLeaseHealth([game('2026-12-03T20:45:00Z',null)], now));
  for (const lease of [null, '2026-12-03T20:00:00Z', '2026-12-03T22:00:00Z']) {
    assert.throws(() => checkLeaseHealth([game('2026-12-04T01:15:00Z',lease)], now), /within one hour/);
  }
});

test('incident script opens once, suppresses repeated alerts, then closes only the owned incident', async () => {
  const scratch = await mkdtemp(join(tmpdir(), 'pickem-health-'));
  try {
    await writeFile(join(scratch, 'gh'), `#!/usr/bin/env bash
case "$1 $2" in
  "api --paginate") if [[ -f "$STATE" ]]; then printf '321\\n'; fi ;;
  "issue create") cat > "$STATE"; printf 'create\\n' >> "$TRACE" ;;
  "issue close") [[ "$3" == 321 ]] || exit 1; rm "$STATE"; printf 'close\\n' >> "$TRACE" ;;
  *) exit 1 ;;
esac
`, { mode: 0o700 });
    const script = fileURLToPath(new URL('../pickem-jobs/report-sync-health.sh', import.meta.url));
    const run = (result, full = true) => promisify(execFile)('bash', [script], { env: { ...process.env,
      PATH: scratch + ':' + process.env.PATH, STATE: join(scratch, 'state'), TRACE: join(scratch, 'trace'),
      SYNC_RESULT: result, FULL_RUN: String(full), GITHUB_SERVER_URL: 'https://github.com', GITHUB_REPOSITORY: 'fixture/fixture',
      GITHUB_REPOSITORY_OWNER: 'fixture', GITHUB_RUN_ID: '123',
    } });
    await run('skipped');
    await run('cancelled');
    await run('failure');
    assert.match(await readFile(join(scratch,'state'),'utf8'), /pickem-sync-incident/);
    await run('success', false);
    assert.match(await readFile(join(scratch,'state'),'utf8'), /pickem-sync-incident/);
    await run('success');
    await run('success');
    assert.equal(await readFile(join(scratch,'trace'),'utf8'), 'create\nclose\n');
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
});
