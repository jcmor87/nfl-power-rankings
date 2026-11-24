// Provider adapters accept a captured payload and return normalized observations.
// Completeness and final verification belong to the calling application.
const statuses = new Map([
  ['STATUS_SCHEDULED', 'scheduled'],
  ['STATUS_IN_PROGRESS', 'in_progress'],
  ['STATUS_HALFTIME', 'in_progress'],
  ['STATUS_END_PERIOD', 'in_progress'],
  ['STATUS_POSTPONED', 'postponed'],
  ['STATUS_SUSPENDED', 'suspended'],
  ['STATUS_FINAL', 'final'],
  ['STATUS_FINAL_OVERTIME', 'final'],
  ['STATUS_CANCELED', 'canceled'],
]);

function parseScore(value) {
  if (typeof value !== 'string' || !/^\d+$/.test(value) || Number(value) > 32767) {
    throw new Error('Missing or invalid final score');
  }
  return Number(value);
}

export function normalizeEspnScoreboard(payload, { season, week }) {
  if (!Number.isInteger(season) || !Number.isInteger(week) || week < 1 || week > 18 ||
      payload?.season?.year !== season || payload.season.type !== 2 ||
      payload.week?.number !== week || !Array.isArray(payload.events) || !payload.events.length) {
    throw new Error('Expected a nonempty scoreboard for the requested regular-season week');
  }

  const ids = new Set();
  return payload.events.map((event) => {
    const competition = event.competitions?.[0];
    const teams = competition?.competitors;
    const home = teams?.find((team) => team.homeAway === 'home')?.team?.id;
    const away = teams?.find((team) => team.homeAway === 'away')?.team?.id;
    if (typeof event.id !== 'string' || !/^\d+$/.test(event.id) || ids.has(event.id) ||
        event.season?.year !== season || event.season?.type !== 2 ||
        event.week?.number !== week || event.competitions?.length !== 1 ||
        teams?.length !== 2 || !home || !away || home === away) {
      throw new Error('Unexpected event identity, season, week, or teams');
    }
    ids.add(event.id);

    const type = competition.status?.type;
    let status = statuses.get(type?.name) ?? 'unknown';
    if ((status === 'final' && (type.completed !== true || type.state !== 'post')) ||
        (status === 'scheduled' && (type.completed !== false || type.state !== 'pre'))) {
      status = 'unknown';
    }
    const date = competition.date;
    const kickoff = !competition.timeValid || typeof date !== 'string' ||
      !/(?:Z|[+-]\d\d:\d\d)$/.test(date) ? NaN : Date.parse(date);
    return {
      source: 'espn',
      sourceGameId: event.id,
      season,
      week,
      homeSourceTeamId: home,
      awaySourceTeamId: away,
      kickoffAt: Number.isFinite(kickoff) ? new Date(kickoff).toISOString() : null,
      status,
      homeScore: status === 'final' ? parseScore(teams.find((team) => team.homeAway === 'home').score) : null,
      awayScore: status === 'final' ? parseScore(teams.find((team) => team.homeAway === 'away').score) : null,
    };
  });
}
