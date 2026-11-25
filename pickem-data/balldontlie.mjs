import { canonicalTeam, postseasonRounds, teamCodes } from './nfl-competition.mjs';
import { SyncValidationError } from './sync-validation-error.mjs';
import { setTimeout as delay } from 'node:timers/promises';

const states = new Map([
  ['scheduled', 'scheduled'], ['in_progress', 'in_progress'], ['final', 'final'],
  ['postponed', 'postponed'], ['canceled', 'canceled'], ['suspended', 'suspended'],
  ['delayed', 'postponed'],
]);

function timestamp(value) {
  return typeof value === 'string' && /T\d{2}:\d{2}.*(?:Z|[+-]\d\d:\d\d)$/.test(value) &&
    Number.isFinite(Date.parse(value)) ? new Date(value).toISOString() : null;
}
const score = value => Number.isInteger(value) && value >= 0 && value <= 32767;
const validId = value => Number.isSafeInteger(value) && value > 0;

export function normalizeTeams(rows) {
  if (!Array.isArray(rows)) throw new SyncValidationError('BALLDONTLIE Teams response must contain a data array');
  const remaining = new Set(teamCodes);
  const ids = new Set();
  const teams = rows.map((row, index) => {
    const position = ' at record ' + (index + 1);
    if (!row || typeof row !== 'object' || Array.isArray(row) ||
        !validId(row.id) || typeof row.abbreviation !== 'string' ||
        typeof row.full_name !== 'string' || !row.full_name.trim()) {
      throw new SyncValidationError('Malformed NFL team record' + position + ' (expected id, abbreviation and full_name)');
    }
    const code = canonicalTeam(row.abbreviation);
    if (!teamCodes.includes(code)) throw new SyncValidationError('Unexpected NFL team abbreviation' + position);
    if (!remaining.delete(code)) throw new SyncValidationError('Duplicate NFL team abbreviation' + position);
    if (ids.has(row.id)) throw new SyncValidationError('Duplicate NFL team ID' + position);
    ids.add(row.id);
    return { code, name: row.full_name.trim(), providerId: row.id };
  });
  if (remaining.size) throw new SyncValidationError('Incomplete NFL team directory: expected 32 teams, received ' + teams.length);
  return teams;
}

const paginationMetadata = meta => meta !== null && typeof meta === 'object' && !Array.isArray(meta);

export function normalizeGames(payload, { season, week, phase = 'regular', expectedIds }) {
  if (!Array.isArray(payload?.data) || !paginationMetadata(payload.meta) || payload.meta.next_cursor != null ||
      !payload.data.length || payload.data.length > 16 ||
      (expectedIds && (new Set(expectedIds).size !== expectedIds.length || payload.data.length !== expectedIds.length))) {
    throw new SyncValidationError('Incomplete, paginated or unexpected week snapshot');
  }
  const ids = new Set();
  const missing = expectedIds && new Set(expectedIds);
  return payload.data.map(game => {
    if (!validId(game?.id) || ids.has(game.id) || (missing && !missing.delete(game.id)) ||
        game.season !== season || game.week !== week || game.postseason !== (phase === 'postseason') ||
        !validId(game.home_team?.id) || !validId(game.visitor_team?.id) || game.home_team.id === game.visitor_team.id) {
      throw new SyncValidationError('Unexpected matchup identity');
    }
    ids.add(game.id);
    const kickoffAt = timestamp(game.date);
    const observedAt = timestamp(game.updated_at);
    const status = states.get(game.status_state);
    if (!status) throw new SyncValidationError('Unknown BALLDONTLIE lifecycle status');
    const needsKickoff = status === 'scheduled' || status === 'final';
    if (!observedAt || (needsKickoff && !kickoffAt) || (game.date != null && !kickoffAt) ||
        (status === 'final' && (!score(game.home_team_score) || !score(game.visitor_team_score))) ||
        (status === 'canceled' && (game.home_team_score !== null || game.visitor_team_score !== null)) ||
        [game.home_team_score, game.visitor_team_score].some(value => value != null && !score(value))) {
      throw new SyncValidationError('Malformed BALLDONTLIE kickoff, timestamp or score');
    }
    return {
      source: 'balldontlie', sourceGameId: String(game.id), season, week, phase, kickoffAt,
      observedAt, status, homeSourceTeamId: String(game.home_team.id),
      awaySourceTeamId: String(game.visitor_team.id),
      homeScore: status === 'final' ? game.home_team_score : null,
      awayScore: status === 'final' ? game.visitor_team_score : null,
    };
  });
}

export function createClient({ key, fetcher = fetch, sleep = delay, now = Date.now }) {
  if (!key) throw new SyncValidationError('BALLDONTLIE_API_KEY is required');
  let nextRequest = 0;
  async function page(endpoint, query) {
    const url = new URL(endpoint, 'https://api.balldontlie.io/nfl/v1/');
    url.search = new URLSearchParams(query);
    for (let attempt = 1; attempt <= 3; attempt++) {
      if (nextRequest > now()) await sleep(nextRequest - now());
      // Space all requests, including retries, to stay below five per minute.
      nextRequest = now() + 15_100;
      let response;
      try {
        response = await fetcher(url, { headers: { Authorization: key }, redirect: 'manual',
          signal: AbortSignal.timeout(12_000) });
      } catch {
        if (attempt === 3) throw new SyncValidationError('BALLDONTLIE network unavailable after three attempts');
        continue;
      }
      if (response.ok) {
        try { return await response.json(); } catch {
          throw new SyncValidationError('BALLDONTLIE ' + endpoint + ' response is not valid JSON');
        }
      }
      if (attempt === 3 || ![429, 500, 502, 503, 504].includes(response.status)) {
        throw new SyncValidationError('BALLDONTLIE HTTP ' + response.status);
      }
      const retryAfter = response.headers.get('retry-after');
      const wait = !retryAfter ? 0 : /^\d+$/.test(retryAfter) ?
        Number(retryAfter) * 1000 : Date.parse(retryAfter) - now();
      if (wait > 60_000) throw new SyncValidationError('BALLDONTLIE requested retry beyond the job limit');
      if (Number.isFinite(wait)) nextRequest = Math.max(nextRequest, now() + wait);
    }
  }

  async function pages(endpoint, query = {}) {
    const rows = [];
    const seen = new Set();
    let cursor;
    for (let i = 0; i < 10; i++) {
      const payload = await page(endpoint, { ...query, per_page: 100, ...(cursor == null ? {} : { cursor }) });
      if (!Array.isArray(payload?.data)) throw new SyncValidationError('BALLDONTLIE Games response must contain a data array');
      if (!paginationMetadata(payload.meta)) throw new SyncValidationError('BALLDONTLIE Games response is missing valid pagination metadata');
      rows.push(...payload.data);
      cursor = payload.meta.next_cursor;
      if (cursor == null) return rows;
      if (!validId(cursor) || seen.has(cursor)) throw new SyncValidationError('Invalid BALLDONTLIE pagination cursor');
      seen.add(cursor);
    }
    throw new SyncValidationError('BALLDONTLIE pagination limit exceeded');
  }

  return {
    async teams() {
      const payload = await page('teams', { per_page: 100 });
      if (payload?.meta?.next_cursor != null) {
        throw new SyncValidationError('BALLDONTLIE Teams response unexpectedly contains a pagination cursor');
      }
      return normalizeTeams(payload?.data);
    },
    async week({ season, phase, week, allowPending = false }) {
      const rows = await pages('games', phase === 'postseason' ?
        { 'seasons[]': season, postseason: 'true' } :
        { 'seasons[]': season, 'weeks[]': week, 'season_types[]': 2 });
      if (phase === 'postseason') {
        if (new Set(rows.map(row => row?.id)).size !== rows.length ||
            rows.some(row => row?.season !== season || row.postseason !== true || !Object.hasOwn(postseasonRounds, row.week))) {
          throw new SyncValidationError('Invalid BALLDONTLIE postseason inventory');
        }
      }
      const selected = phase === 'postseason' ? rows.filter(row => row.week === week) : rows;
      if (phase === 'postseason' && allowPending &&
          (selected.length < postseasonRounds[week].games ||
            selected.some(row => ['scheduled', 'unknown'].includes(row.status_state) &&
              row.home_team_score == null && row.visitor_team_score == null &&
              (!row.home_team?.id || !row.visitor_team?.id)))) return null;
      return normalizeGames({ data: selected, meta: {} },
        { season, phase, week });
    },
  };
}
