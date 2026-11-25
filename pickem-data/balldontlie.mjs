const states = new Map([
  ['scheduled', 'scheduled'], ['in_progress', 'in_progress'], ['final', 'final'],
  ['postponed', 'postponed'], ['canceled', 'canceled'], ['suspended', 'suspended'],
  ['delayed', 'postponed'],
]);

function timestamp(value) {
  return typeof value === 'string' && /T\d{2}:\d{2}.*(?:Z|[+-]\d\d:\d\d)$/.test(value) &&
    Number.isFinite(Date.parse(value)) ? new Date(value).toISOString() : null;
}

function score(value) {
  return Number.isInteger(value) && value >= 0 && value <= 32767;
}

export function normalizeGames(payload, { season, week, expectedIds }) {
  if (!Array.isArray(payload?.data) || !payload.meta || payload.meta.next_cursor != null ||
      !Array.isArray(expectedIds) || !expectedIds.length || expectedIds.length > 16 ||
      new Set(expectedIds).size !== expectedIds.length || payload.data.length !== expectedIds.length) {
    throw new Error('Incomplete, paginated or unexpected week snapshot');
  }
  const missing = new Set(expectedIds);
  return payload.data.map(game => {
    if (!Number.isSafeInteger(game.id) || !missing.delete(game.id) || game.season !== season ||
        game.week !== week || game.postseason !== false || !game.home_team?.id ||
        !game.visitor_team?.id || game.home_team.id === game.visitor_team.id) {
      throw new Error('Unexpected matchup identity');
    }
    const kickoffAt = timestamp(game.date);
    const observedAt = timestamp(game.updated_at);
    let status = states.get(game.status_state) ?? 'unknown';
    if ((status === 'scheduled' && !kickoffAt) ||
        (status === 'final' && (!observedAt || !score(game.home_team_score) || !score(game.visitor_team_score))) ||
        (status === 'canceled' && !observedAt)) status = 'unknown';
    return {
      source: 'balldontlie', sourceGameId: String(game.id), season, week, kickoffAt,
      observedAt, status, homeSourceTeamId: String(game.home_team.id),
      awaySourceTeamId: String(game.visitor_team.id),
      homeScore: status === 'final' ? game.home_team_score : null,
      awayScore: status === 'final' ? game.visitor_team_score : null,
    };
  });
}

export async function fetchWeek({ season, week, expectedIds, key }) {
  if (!key || !Number.isInteger(season) || !Number.isInteger(week) || week < 1 || week > 18) {
    throw new Error('Configure an authorized provider key and regular-season week');
  }
  const url = new URL('https://api.balldontlie.io/nfl/v1/games');
  url.search = new URLSearchParams({
    'seasons[]': season, 'weeks[]': week, 'season_types[]': 2, per_page: 100,
  });
  const response = await fetch(url, {
    headers: { Authorization: key }, redirect: 'error', signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error('NFL provider HTTP ' + response.status);
  return normalizeGames(await response.json(), { season, week, expectedIds });
}
