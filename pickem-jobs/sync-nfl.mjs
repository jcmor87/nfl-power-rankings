#!/usr/bin/env node
import { parseArgs } from 'node:util';
import { createClient } from '../pickem-data/balldontlie.mjs';
import { fetchSchedule } from '../pickem-data/nflverse-schedule.mjs';
import { reconcile } from '../pickem-data/reconcile.mjs';
import { validWeek } from '../pickem-data/nfl-competition.mjs';

let stage = 'configuration';
let invalidate;

function rpc(origin, key, name, body) {
  return fetch(origin + '/rest/v1/rpc/' + name, {
    method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(25_000),
    headers: { apikey: key, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
}
try {
  const { values } = parseArgs({ options: {
    season: { type: 'string' }, phase: { type: 'string', default: 'regular' },
    week: { type: 'string' }, apply: { type: 'boolean', default: false },
  } });
  const { phase, apply } = values;
  const season = Number(values.season);
  const week = Number(values.week);
  if (!validWeek(season, phase, week)) throw new Error('Specify a supported season, phase and week/round.');
  const { BALLDONTLIE_API_KEY, SUPABASE_URL, SUPABASE_SECRET_KEY, PICKEM_SYNC_CONFIRM_ORIGIN } = process.env;
  const origin = SUPABASE_URL?.replace(/\/$/, '');
  if (apply && (season < 2026 || !origin || origin !== PICKEM_SYNC_CONFIRM_ORIGIN ||
      !/^http:\/\/127\.0\.0\.1:\d+$|^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(origin) ||
      !/^sb_secret_[A-Za-z0-9_-]+$/.test(SUPABASE_SECRET_KEY ?? ''))) {
    throw new Error('Applying requires a confirmed project origin and a backend key.');
  }
  const client = createClient({ key: BALLDONTLIE_API_KEY });
  const period = { season, phase, week };
  if (apply) invalidate = () => rpc(origin, SUPABASE_SECRET_KEY, 'invalidate_pickem_nfl_week',
    { p_season: season, p_phase: phase, p_week: week });
  stage = 'team validation';
  const teams = await client.teams();
  stage = 'provider schedule';
  const observations = await client.week(period);
  stage = 'independent reconciliation';
  const reference = await fetchSchedule(period);
  const snapshot = reconcile({ ...period, teams, observations, reference });
  console.log(JSON.stringify({ mode: apply ? 'apply' : 'dry-run', ...period, teams: snapshot.teams.length,
    games: snapshot.games.length, statuses: Object.fromEntries([...new Set(snapshot.games.map(game => game.status))]
      .map(status => [status, snapshot.games.filter(game => game.status === status).length])) }));
  if (apply) {
    stage = 'database synchronization';
    const response = await rpc(origin, SUPABASE_SECRET_KEY, 'sync_pickem_nfl_week',
      { p_snapshot: snapshot });
    if (!response.ok) throw new Error('Atomic database sync rejected (HTTP ' + response.status + ').');
    console.log('Atomic sync accepted.');
  }
} catch (error) {
  // Only the reconciliation and transport modules' own known messages are safe
  // to emit. Never print response bodies, URLs, request headers or exception objects.
  const message = /^(BALLDONTLIE |nflverse HTTP |Kickoff requires |Final score requires |Cancellation requires |Schedule coverage )/.test(error?.message) ?
    error.message : 'Check the inputs or service configuration.';
  console.error('NFL sync failed during ' + stage + '. ' + message);
  if (invalidate) {
    try {
      const response = await invalidate();
      if (!response.ok) throw new Error('Could not invalidate');
      console.error('Scheduled games held for this period.');
    } catch {
      console.error('Immediate schedule hold could not be confirmed. Existing verification leases expire automatically.');
    }
  }
  process.exitCode = 1;
}
