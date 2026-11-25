import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { official2026Matchups } from '../pickem-data/nfl-2026-matchups.mjs';
import { teamCodes } from '../pickem-data/nfl-competition.mjs';

const cli = fileURLToPath(new URL('../pickem-jobs/sync-nfl.mjs', import.meta.url));
const workflow = readFileSync(new URL('../.github/workflows/pickem-nfl-dry-run.yml', import.meta.url), 'utf8');
const directory = teamCodes.map((abbreviation, index) => ({
  id: index + 1, abbreviation, full_name: 'Synthetic ' + abbreviation,
}));
const csv = [
  'game_id,season,game_type,week,gameday,gametime,home_team,away_team,home_score,away_score',
  'fixture-reg-1,2999,REG,1,2999-09-10,16:00,ARI,ATL,,',
  'fixture-reg-2,2999,REG,2,2999-09-10,16:00,ARI,ATL,3,7',
  'fixture-post-5,2999,SB,5,2999-09-10,16:00,ARI,ATL,14,7',
].join('\n');

async function run(args, { teamFailure = false, family = false, expiring = false } = {}) {
  const week13 = official2026Matchups[13].split(' ').map((pair, index) => {
    const [away, home] = pair.split(':');
    return { away, home, id: index + 1 };
  });
  const reference = family ? csv.split('\n')[0] + '\n' + week13.map(game =>
    `week13-${game.id},2026,REG,13,2026-12-03,20:15,${game.home},${game.away},,`).join('\n') : csv;
  const mock = `
    let tick = ${family ? Date.parse('2026-12-01T17:17:00Z') : 0};
    Date.now = () => tick += 20000;
    const trace = [];
    process.on('exit', () => console.log('TRACE ' + JSON.stringify(trace)));
    globalThis.fetch = async (target, options) => {
      const url = new URL(target);
      if (url.hostname === 'api.balldontlie.io') {
        if (url.pathname.endsWith('/teams')) {
          trace.push(['teams']);
          return ${teamFailure} ? new Response(null, { status: 503 }) :
            Response.json({ data: ${JSON.stringify(directory)} });
        }
        const postseason = url.searchParams.get('postseason') === 'true';
        const week = postseason ? 5 : Number(url.searchParams.get('weeks[]'));
        trace.push(['games', week]);
        if (${family}) return Response.json({ data: ${JSON.stringify(week13)}.map(game => ({
          id: game.id, season: 2026, week, postseason: false, date: '2026-12-04T01:15:00Z',
          updated_at: '2026-11-30T00:00:00Z', status_state: 'scheduled',
          home_team: { id: ${JSON.stringify(teamCodes)}.indexOf(game.home) + 1 },
          visitor_team: { id: ${JSON.stringify(teamCodes)}.indexOf(game.away) + 1 },
        })), meta: {} });
        return Response.json({ data: [{
          id: 100 + week, season: 2999, week, postseason, date: '2999-09-10T20:00:00Z',
          updated_at: '2999-09-10T21:00:00Z',
          home_team: { id: 1 }, visitor_team: { id: 2 },
          status_state: week === 1 ? 'scheduled' : 'final',
          home_team_score: week === 1 ? null : 14, visitor_team_score: week === 1 ? null : 7,
        }], meta: {} });
      }
      if (url.hostname === 'github.com') return new Response(${JSON.stringify(reference)});
      if (url.hostname === 'fixture.supabase.co') {
        if (url.pathname.endsWith('/weeks')) {
          trace.push(['read-weeks']);
          return Response.json([{ competition_phase: 'regular', week_number: 12, status: 'active' }]);
        }
        if (url.pathname.endsWith('/games')) {
          trace.push(['read-leases']);
          return Response.json([{
            pick_deadline_at: '2026-12-04T01:15:00Z',
            schedule_verified_until: ${expiring} ? '2026-12-01T17:30:00Z' : '2026-12-01T20:00:00Z',
            weeks: { competition_phase: 'regular', week_number: 13 },
          }]);
        }
        const body = JSON.parse(options.body);
        if (url.pathname.endsWith('/sync_pickem_family_period')) {
          trace.push(['family-apply', body.p_snapshot.week, body.p_snapshot.games.length]);
        } else if (url.pathname.endsWith('/sync_pickem_nfl_week')) {
          trace.push(['apply', body.p_snapshot.phase, body.p_snapshot.week, body.p_snapshot.games[0].status]);
        } else if (url.pathname.endsWith('/invalidate_pickem_nfl_week')) {
          trace.push(['hold', body.p_phase, body.p_week]);
        } else throw new Error('Unexpected database operation');
        return new Response(null, { status: 204 });
      }
      throw new Error('Unexpected request');
    };
  `;
  let result;
  try {
    result = await promisify(execFile)(process.execPath, [
      '--import', 'data:text/javascript,' + encodeURIComponent(mock), cli, ...args,
    ], { env: {
      ...process.env, BALLDONTLIE_API_KEY: 'synthetic-provider-key',
      SUPABASE_URL: 'https://fixture.supabase.co',
      PICKEM_SYNC_CONFIRM_ORIGIN: 'https://fixture.supabase.co',
      SUPABASE_SECRET_KEY: 'sb_secret_synthetic-fixture',
    } });
  } catch (error) {
    if (!error.stdout?.includes('TRACE ')) throw error;
    result = error;
  }
  const trace = JSON.parse(result.stdout.split('\n').find(line => line.startsWith('TRACE ')).slice(6));
  assert.doesNotMatch(result.stdout + result.stderr, /synthetic-provider-key|sb_secret_synthetic-fixture/);
  return { ...result, trace };
}

test('workflow keeps writes scoped to main, the production environment and explicitly enabled modes', () => {
  const [dryRun, production] = workflow.split('\n  sync-production:');
  assert.match(dryRun, /workflow_dispatch.*inputs\.mode == 'dry-run'/);
  assert.doesNotMatch(dryRun, /SUPABASE_SECRET_KEY|--apply/);
  assert.match(workflow, /cron: '17 \* \* \* \*'/);
  assert.match(workflow, /group: pickem-nfl-provider\n  cancel-in-progress: false/);
  assert.match(production, /github\.repository == 'jcmor87\/nfl-power-rankings'/);
  assert.match(production, /github\.ref == 'refs\/heads\/main'/);
  assert.match(production, /vars\.PICKEM_NFL_SYNC_ENABLED == 'true' &&\s*\(github\.event_name == 'schedule' \|\|/);
  assert.match(production, /github\.event_name == 'workflow_dispatch' && inputs\.mode == 'apply'/);
  assert.match(production, /environment: pickem-production/);
  assert.match(production, /--apply --family --periods="\$PERIODS"/);
  assert.match(production, /--apply --family --auto/);
  assert.doesNotMatch(production, /vars\.PICKEM_SYNC_PERIODS/);
  assert.match(production, /notify-owner:[\s\S]+needs: sync-production[\s\S]+issues: write/);
});

test('batch reuses one Teams request, holds only a conflicting period, and continues through Super Bowl', async () => {
  const result = await run(['--apply', '--periods=2999:regular:1,2999:regular:2,2999:postseason:5']);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /regular 2.*Final score requires matching evidence/);
  assert.deepEqual(result.trace, [
    ['teams'], ['games', 1], ['apply', 'regular', 1, 'scheduled'],
    ['games', 2], ['hold', 'regular', 2], ['games', 5], ['apply', 'postseason', 5, 'final'],
  ]);
});

test('team-provider outage holds every target without writing a snapshot', async () => {
  const result = await run(['--apply', '--periods=2999:regular:1,2999:postseason:5'], { teamFailure: true });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /team validation.*HTTP 503/);
  assert.deepEqual(result.trace, [
    ['teams'], ['teams'], ['teams'], ['hold', 'regular', 1], ['hold', 'postseason', 5],
  ]);
});

test('batch dry runs never reach the database, even with configured write credentials', async () => {
  const result = await run(['--periods=2999:regular:1,2999:postseason:5']);
  assert.equal(result.stderr, '');
  assert.deepEqual(result.trace, [['teams'], ['games', 1], ['games', 5]]);
  assert.equal((result.stdout.match(/"mode":"dry-run"/g) ?? []).length, 2);
});

test('invalid and duplicate configured targets stop before any service call', async () => {
  for (const periods of ['', '2999:postseason:4', '2999:regular:1,2999:regular:01',
    '2999:regular:1,2999:regular:2,2999:regular:3,2999:regular:4,2999:regular:5']) {
    const result = await run(['--apply', '--periods=' + periods]);
    assert.equal(result.code, 1);
    assert.match(result.stderr, /configuration.*one to four distinct/);
    assert.deepEqual(result.trace, []);
  }
});


test('family production overrides reject pre-start history while historical dry runs remain available', async () => {
  const result = await run(['--apply', '--family', '--periods=2026:regular:12']);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /outside the 2026 family competition/);
  assert.deepEqual(result.trace, []);
});


test('auto CLI selects and applies only Week 13, then alerts on still-open games with expiring leases', async () => {
  const args = ['--apply', '--family', '--auto'];
  const expected = [['read-weeks'], ['teams'], ['games', 13], ['family-apply', 13, 14], ['read-leases']];
  const healthy = await run(args, { family: true });
  assert.equal(healthy.stderr, '');
  assert.deepEqual(healthy.trace, expected);
  const unhealthy = await run(args, { family: true, expiring: true });
  assert.equal(unhealthy.code, 1);
  assert.match(unhealthy.stderr, /lease monitoring.*within one hour/);
  assert.deepEqual(unhealthy.trace, expected);
});
