import { canonicalTeam, postseasonRounds, teamCodes } from './nfl-competition.mjs';

export const scheduleRelease = 'https://github.com/nflverse/nflverse-data/releases/download/schedules/games.csv';

function parseCsv(csv) {
  const rows = [];
  let row = [], field = '', quoted = false;
  for (let index = 0; index < csv.length; index++) {
    const char = csv[index];
    if (char === '"') {
      if (quoted && csv[index + 1] === '"') {
        field += '"';
        index++;
      } else quoted = !quoted;
    } else if (!quoted && (char === ',' || char === '\n')) {
      row.push(field);
      field = '';
      if (char === '\n') {
        rows.push(row);
        row = [];
      }
    } else if (quoted || char !== '\r') field += char;
  }
  if (quoted) throw new Error('Malformed nflverse CSV');
  if (row.length || field) rows.push([...row, field]);
  return rows;
}

const eastern = new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
});

function kickoff(date, time) {
  if (!/^\d{4}-\d\d-\d\d$/.test(date) || !/^\d\d:\d\d$/.test(time)) return null;
  const requested = Date.parse(date + 'T' + time + ':00Z');
  if (!Number.isFinite(requested)) return null;
  // Modern Eastern dates have two possible UTC offsets. Require exactly one
  // round trip to reject nonexistent or ambiguous wall-clock times.
  const matches = [4, 5].map(hours => requested + hours * 3_600_000).filter(instant => {
    const parts = Object.fromEntries(eastern.formatToParts(instant).map(({ type, value }) => [type, value]));
    return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}` === date + 'T' + time;
  });
  return matches.length === 1 ? new Date(matches[0]).toISOString() : null;
}

export function readSchedule(csv, { season, phase, week }) {
  const [columns = [], ...values] = parseCsv(csv);
  const fields = ['game_id', 'season', 'game_type', 'week', 'gameday', 'gametime',
    'home_team', 'away_team', 'home_score', 'away_score'];
  if (fields.some(name => columns.indexOf(name) < 0 || columns.indexOf(name) !== columns.lastIndexOf(name))) {
    throw new Error('Unexpected nflverse CSV fields');
  }
  const indexes = Object.fromEntries(fields.map(name => [name, columns.indexOf(name)]));
  const type = phase === 'regular' ? 'REG' : postseasonRounds[week].feed;
  return values.filter(row => row[indexes.season] === String(season) &&
    row[indexes.game_type] === type && (phase === 'postseason' || row[indexes.week] === String(week))).map(row => {
    if (row.length !== columns.length) throw new Error('Malformed nflverse CSV row');
    const home = canonicalTeam(row[indexes.home_team]);
    const away = canonicalTeam(row[indexes.away_team]);
    const homeScore = row[indexes.home_score];
    const awayScore = row[indexes.away_score];
    const score = value => /^\d{1,5}$/.test(value) && Number(value) <= 32767;
    if (!row[indexes.game_id] || !teamCodes.includes(home) || !teamCodes.includes(away) || home === away ||
        ((homeScore || awayScore) && !(score(homeScore) && score(awayScore)))) {
      throw new Error('Malformed nflverse matchup or score');
    }
    return { id: row[indexes.game_id], home, away, kickoffAt: kickoff(row[indexes.gameday], row[indexes.gametime]),
      homeScore: homeScore ? Number(homeScore) : null, awayScore: awayScore ? Number(awayScore) : null };
  });
}

export async function fetchSchedule(options, fetcher = fetch) {
  const response = await fetcher(scheduleRelease, { signal: AbortSignal.timeout(15_000) });
  if (!response.ok) throw new Error('nflverse HTTP ' + response.status);
  return readSchedule(await response.text(), options);
}
