import { official2026Matchups } from '../pickem-data/nfl-2026-matchups.mjs';
import { postseasonRounds } from '../pickem-data/nfl-competition.mjs';
import { SyncValidationError } from '../pickem-data/sync-validation-error.mjs';

const hour = 3_600_000;
const day = 24 * hour;
export const familySeason = 2026;
export const familyPeriods = [
  ...[13, 14, 15, 16, 17, 18].map(week => ({ season: familySeason, phase: 'regular', week })),
  ...[1, 2, 3, 5].map(week => ({ season: familySeason, phase: 'postseason', week })),
];
export const periodKey = ({ phase, week }) => phase + ':' + week;
export const inFamily = period => familyPeriods.some(candidate =>
  candidate.season === period.season && periodKey(candidate) === periodKey(period));

// Published Week 13–18 dates let missing regular-season data fail loudly in
// its expected window. These dates select periods and never create matchups.
const regularDates = [
  ['2026-12-03','2026-12-07'], ['2026-12-10','2026-12-14'], ['2026-12-17','2026-12-21'],
  ['2026-12-24','2026-12-28'], ['2026-12-31','2027-01-04'], ['2027-01-09','2027-01-10'],
];

export function selectFamilyPeriods({ schedule, existing, now }) {
  const rows = new Map(existing.map(row => [periodKey({ phase: row.competition_phase, week: row.week_number }), row]));
  const targets = [];
  const history = [];
  for (const period of familyPeriods) {
    const row = rows.get(periodKey(period));
    // Retain unfinished live periods even when a provider removes or delays the matchup.
    if (row?.status === 'active') {
      targets.push(period);
      continue;
    }
    const { games, pending } = schedule(period);
    const expected = period.phase === 'regular' ? official2026Matchups[period.week].split(' ').length :
      postseasonRounds[period.week].games;
    // Playoff slots have no schedule identity until both teams are known.
    if (period.phase === 'postseason' && (pending || games.length < expected) && !row) continue;
    const times = games.map(game => Date.parse(game.kickoffAt)).filter(Number.isFinite);
    if (!times.length && period.phase === 'regular') {
      for (const date of regularDates[period.week - 13]) times.push(Date.parse(date + 'T20:00:00Z'));
    }
    if (!times.length) {
      if (row?.status === 'planned') targets.push(period);
      continue;
    }
    const first = Math.min(...times);
    const last = Math.max(...times);
    if ((row?.status === 'complete' || row?.status === 'planned') && now > last + 2 * day) {
      if (row.status === 'complete' && now <= last + 14 * day) history.push(period);
      continue;
    }
    if (now >= first - 7 * day && now <= last + 2 * day) targets.push(period);
  }
  // Recheck one older completed period daily, rotating within the correction window.
  if (new Date(now).getUTCHours() === 12 && history.length) {
    targets.push(history[Math.floor(now / day) % history.length]);
  }
  return targets;
}

export function checkLeaseHealth(rows, now) {
  if (!Array.isArray(rows)) throw new SyncValidationError('Unexpected schedule lease response.');
  if (rows.some(row => {
    const deadline = Date.parse(row.pick_deadline_at);
    const lease = Date.parse(row.schedule_verified_until);
    return !Number.isFinite(deadline) || (deadline > now &&
      (!Number.isFinite(lease) || (lease <= now + hour && lease < deadline)));
  })) {
    throw new SyncValidationError('One or more open game verification leases are expired or expire within one hour.');
  }
}
