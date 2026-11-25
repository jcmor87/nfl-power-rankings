#!/usr/bin/env node
import { parseArgs } from 'node:util';
import { createClient } from '../pickem-data/balldontlie.mjs';
import { fetchScheduleReader } from '../pickem-data/nflverse-schedule.mjs';
import { reconcile } from '../pickem-data/reconcile.mjs';
import { SyncValidationError } from '../pickem-data/sync-validation-error.mjs';
import { checkLeaseHealth, familySeason, inFamily, selectFamilyPeriods, periodKey } from './family-periods.mjs';
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

async function syncPeriod({ period, client, teams, schedule, apply, family, allowPending, origin, key }) {
  let stage = 'provider schedule';
  try {
    stage = 'independent reconciliation';
    const reference = schedule(period).games;
    stage = 'provider schedule';
    const observations = await client.week({ ...period, allowPending: allowPending &&
      reference.every(game => Date.parse(game.kickoffAt) > Date.now()) });
    if (observations === null) {
      console.log('Waiting for postseason matchup identities for ' + periodLabel(period) + '.');
      return;
    }
    stage = 'independent reconciliation';
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
      const response = await rpc(origin, key, family ? 'sync_pickem_family_period' : 'sync_pickem_nfl_week',
        { p_snapshot: snapshot });
      if (!response.ok) throw new SyncValidationError('Atomic database sync rejected (HTTP ' + response.status + ').');
      console.log('Atomic sync accepted for ' + periodLabel(period) + '.');
    }
  } catch (error) {
    reportFailure(stage, error, period);
    if (apply) await hold(period, origin, key);
  }
}

async function readDatabase(origin, key, table, query) {
  const response = await fetch(origin + '/rest/v1/' + table + '?' + new URLSearchParams(query), {
    headers: { apikey: key }, redirect: 'manual', signal: AbortSignal.timeout(25_000),
  });
  if (!response.ok) throw new SyncValidationError('Database read failed (HTTP ' + response.status + ').');
  return response.json();
}

async function monitorLeases(origin, key) {
  const rows = await readDatabase(origin, key, 'games', {
    select: 'pick_deadline_at,schedule_verified_until,weeks!inner(week_number,competition_phase,seasons!inner(nfl_year))',
    'weeks.seasons.nfl_year': 'eq.' + familySeason, 'weeks.status': 'eq.active',
    status: 'eq.scheduled', source: 'eq.balldontlie', picks_locked_at: 'is.null',
  });
  if (!Array.isArray(rows)) throw new SyncValidationError('Unexpected schedule lease response.');
  checkLeaseHealth(rows.filter(row => inFamily({
    season: familySeason, phase: row.weeks?.competition_phase, week: row.weeks?.week_number,
  })), Date.now());
}

async function main() {
  const { values } = parseArgs({ options: {
    season: { type: 'string' }, phase: { type: 'string' }, week: { type: 'string' },
    periods: { type: 'string' }, apply: { type: 'boolean', default: false },
    family: { type: 'boolean', default: false }, auto: { type: 'boolean', default: false },
  } });
  const { apply, family, auto } = values;
  if ((auto && (!family || ['season','phase','week','periods'].some(field => values[field] !== undefined))) ||
      (family && !apply)) throw new SyncValidationError('Automatic selection requires family apply mode without explicit periods.');
  let targets = auto ? [] : parsePeriods(values);
  if (family && targets.some(period => !inFamily(period))) {
    throw new SyncValidationError('Production override is outside the 2026 family competition.');
  }
  const { BALLDONTLIE_API_KEY, SUPABASE_URL, SUPABASE_SECRET_KEY, PICKEM_SYNC_CONFIRM_ORIGIN } = process.env;
  const origin = SUPABASE_URL?.replace(/\/$/, '');
  if (apply && (targets.some(period => period.season < 2026) || !origin || origin !== PICKEM_SYNC_CONFIRM_ORIGIN?.replace(/\/$/, '') ||
      !/^http:\/\/127\.0\.0\.1:\d+$|^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(origin) ||
      !/^sb_secret_[A-Za-z0-9_-]+$/.test(SUPABASE_SECRET_KEY ?? ''))) {
    throw new SyncValidationError('Applying requires a confirmed project origin, a backend key, and seasons from 2026 onward.');
  }

  try {
    let schedule;
    const known = new Set();
    try {
      if (auto) {
        schedule = await fetchScheduleReader();
        const existing = await readDatabase(origin, SUPABASE_SECRET_KEY, 'weeks', {
          select: 'week_number,competition_phase,status,seasons!inner(nfl_year)', 'seasons.nfl_year': 'eq.' + familySeason,
        });
        if (!Array.isArray(existing)) throw new SyncValidationError('Unexpected competition periods response.');
        for (const row of existing) known.add(periodKey({ phase: row.competition_phase, week: row.week_number }));
        targets = selectFamilyPeriods({ schedule: period => schedule(period, { discovery: true }),
          existing, now: Date.now() });
      }
    } catch (error) {
      reportFailure('schedule discovery', error);
      if (apply) for (const period of targets) await hold(period, origin, SUPABASE_SECRET_KEY);
      return;
    }
    if (!targets.length) {
      console.log('No family periods are due for synchronization.');
      return;
    }

    let client, teams;
    try {
      client = createClient({ key: BALLDONTLIE_API_KEY });
      teams = await client.teams();
    } catch (error) {
      reportFailure('team validation', error);
      if (apply) for (const period of targets) await hold(period, origin, SUPABASE_SECRET_KEY);
      return;
    }
    if (!schedule) {
      try { schedule = await fetchScheduleReader(); } catch (error) {
        reportFailure('independent reconciliation', error);
        if (apply) for (const period of targets) await hold(period, origin, SUPABASE_SECRET_KEY);
        return;
      }
    }
    for (const period of targets) {
      await syncPeriod({ period, client, teams, schedule, apply, family,
        allowPending: auto && period.phase === 'postseason' && !known.has(periodKey(period)), origin, key: SUPABASE_SECRET_KEY });
    }
  } finally {
    if (family) {
      try { await monitorLeases(origin, SUPABASE_SECRET_KEY); } catch (error) {
        reportFailure('lease monitoring', error);
      }
    }
  }
}

try {
  await main();
} catch (error) {
  reportFailure('configuration', error);
}
