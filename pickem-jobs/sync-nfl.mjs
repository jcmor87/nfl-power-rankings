#!/usr/bin/env node
import { parseArgs } from 'node:util';
import { createClient } from '../pickem-data/balldontlie.mjs';
import { fetchSchedule } from '../pickem-data/nflverse-schedule.mjs';
import { reconcile } from '../pickem-data/reconcile.mjs';
import { SyncValidationError } from '../pickem-data/sync-validation-error.mjs';
import { validWeek } from '../pickem-data/nfl-competition.mjs';

function parsePeriods(values) {
  const { periods, season, phase, week } = values;
  if (periods !== undefined && (season !== undefined || phase !== undefined || week !== undefined)) {
    throw new SyncValidationError('Use either --periods or the single-period arguments.');
  }
  const targets = periods === undefined ? [{ season: Number(season), phase: phase ?? 'regular', week: Number(week) }] :
    periods.split(',').map(value => {
      const match = /^(\d{4}):(regular|postseason):(\d{1,2})$/.exec(value.trim());
      return match && { season: Number(match[1]), phase: match[2], week: Number(match[3]) };
    });
  if (targets.length > 4 || targets.some(period => !period || !validWeek(period.season, period.phase, period.week)) ||
      new Set(targets.map(periodLabel)).size !== targets.length) {
    throw new SyncValidationError('Specify one to four distinct, supported season:phase:week periods.');
  }
  return targets;
}

function rpc(origin, key, name, body) {
  return fetch(origin + '/rest/v1/rpc/' + name, {
    method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(25_000),
    headers: { apikey: key, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
}

async function hold(period, origin, key) {
  try {
    const response = await rpc(origin, key, 'invalidate_pickem_nfl_week',
      { p_season: period.season, p_phase: period.phase, p_week: period.week });
    if (!response.ok) throw new SyncValidationError('Could not invalidate');
    console.error('Scheduled games held for ' + periodLabel(period) + '.');
  } catch {
    console.error('Immediate schedule hold could not be confirmed for ' + periodLabel(period) +
      '. Existing verification leases expire automatically.');
  }
}

function periodLabel({ season, phase, week }) {
  return season + ' ' + phase + ' ' + week;
}

function reportFailure(stage, error, period) {
  // Only authored validation messages are safe to emit. Avoid response bodies,
  // request headers, URLs and exception objects.
  const message = error instanceof SyncValidationError ? error.message :
    'Unexpected error. Check the inputs or service configuration.';
  console.error('NFL sync failed during ' + stage + (period ? ' for ' + periodLabel(period) : '') + '. ' + message);
  process.exitCode = 1;
}

async function syncPeriod({ period, client, teams, apply, origin, key }) {
  let stage = 'provider schedule';
  try {
    const observations = await client.week(period);
    stage = 'independent reconciliation';
    const reference = await fetchSchedule(period);
    const snapshot = reconcile({ ...period, teams, observations, reference });
    console.log(JSON.stringify({ mode: apply ? 'apply' : 'dry-run', ...period, teams: snapshot.teams.length,
      games: snapshot.games.length,
      kickoff_discrepancies: snapshot.games.filter(game => game.kickoff_reconciliation === 'earlier_deadline')
        .map(({ away, home, kickoff_at, reference_kickoff_at, pick_deadline_at, kickoff_reconciliation }) =>
          ({ away, home, kickoff_at, reference_kickoff_at, pick_deadline_at, kickoff_reconciliation })),
      statuses: Object.fromEntries([...new Set(snapshot.games.map(game => game.status))]
        .map(status => [status, snapshot.games.filter(game => game.status === status).length])) }));
    if (apply) {
      stage = 'database synchronization';
      const response = await rpc(origin, key, 'sync_pickem_nfl_week', { p_snapshot: snapshot });
      if (!response.ok) throw new SyncValidationError('Atomic database sync rejected (HTTP ' + response.status + ').');
      console.log('Atomic sync accepted for ' + periodLabel(period) + '.');
    }
  } catch (error) {
    reportFailure(stage, error, period);
    if (apply) await hold(period, origin, key);
  }
}

async function main() {
  const { values } = parseArgs({ options: {
    season: { type: 'string' }, phase: { type: 'string' }, week: { type: 'string' },
    periods: { type: 'string' }, apply: { type: 'boolean', default: false },
  } });
  const targets = parsePeriods(values);
  const { apply } = values;
  const { BALLDONTLIE_API_KEY, SUPABASE_URL, SUPABASE_SECRET_KEY, PICKEM_SYNC_CONFIRM_ORIGIN } = process.env;
  const origin = SUPABASE_URL?.replace(/\/$/, '');
  if (apply && (targets.some(period => period.season < 2026) || !origin || origin !== PICKEM_SYNC_CONFIRM_ORIGIN?.replace(/\/$/, '') ||
      !/^http:\/\/127\.0\.0\.1:\d+$|^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(origin) ||
      !/^sb_secret_[A-Za-z0-9_-]+$/.test(SUPABASE_SECRET_KEY ?? ''))) {
    throw new SyncValidationError('Applying requires a confirmed project origin, a backend key, and seasons from 2026 onward.');
  }
  const client = createClient({ key: BALLDONTLIE_API_KEY });
  let teams;
  try {
    teams = await client.teams();
  } catch (error) {
    reportFailure('team validation', error);
    if (apply) for (const period of targets) await hold(period, origin, SUPABASE_SECRET_KEY);
    return;
  }

  // A batch shares one provider client and rate limiter, and a failed period
  // does not block the remaining ones from receiving fresh leases or results.
  for (const period of targets) {
    await syncPeriod({ period, client, teams, apply, origin, key: SUPABASE_SECRET_KEY });
  }
}

try {
  await main();
} catch (error) {
  reportFailure('configuration', error);
}
