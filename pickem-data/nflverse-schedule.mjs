import { SyncValidationError } from './sync-validation-error.mjs';
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
  if (quoted) throw new SyncValidationError('Malformed nflverse CSV');
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

export function openSchedule(csv) {
  const [columns = [], ...values] = parseCsv(csv);
  const fields = ['game_id', 'season', 'game_type', 'week', 'gameday', 'gametime',
    'home_team', 'away_team', 'home_score', 'away_score'];
  if (fields.some(name => columns.indexOf(name) < 0 || columns.indexOf(name) !== columns.lastIndexOf(name))) {
    throw new SyncValidationError('Unexpected nflverse CSV fields');
  }
  const indexes = Object.fromEntries(fields.map(name => [name, columns.indexOf(name)]));
  return ({ season, phase, week }, { discovery = false } = {}) => {
    const type = phase === 'regular' ? 'REG' : postseasonRounds[week].feed;
    let pending = false;
    const games = [];
    for (const row of values) {
      if (row[indexes.season] !== String(season) || row[indexes.game_type] !== type ||
          (phase === 'regular' && row[indexes.week] !== String(week))) continue;
      if (row.length !== columns.length) throw new SyncValidationError('Malformed nflverse CSV row');
      const home = canonicalTeam(row[indexes.home_team]);
      const away = canonicalTeam(row[indexes.away_team]);
      const kickoffAt = kickoff(row[indexes.gameday], row[indexes.gametime]);
      const homeScore = row[indexes.home_score];
      const awayScore = row[indexes.away_score];
      const score = value => /^\d{1,5}$/.test(value) && Number(value) <= 32767;
      if (discovery && phase === 'postseason' && !homeScore && !awayScore &&
          (!kickoffAt || ['', 'TBD'].includes(home) || ['', 'TBD'].includes(away))) {
        pending = true;
        continue;
      }
      if (!row[indexes.game_id] || !teamCodes.includes(home) || !teamCodes.includes(away) || home === away ||
          ((homeScore || awayScore) && !(score(homeScore) && score(awayScore)))) {
        throw new SyncValidationError('Malformed nflverse matchup or score');
      }
      games.push({ id: row[indexes.game_id], home, away, kickoffAt,
        homeScore: homeScore ? Number(homeScore) : null, awayScore: awayScore ? Number(awayScore) : null });
    }
    return { games, pending };
  };
}

export function readSchedule(csv, period) {
  return openSchedule(csv)(period).games;
}

export async function fetchScheduleReader(fetcher = fetch) {
  const response = await fetcher(scheduleRelease, { signal: AbortSignal.timeout(15_000) });
  if (!response.ok) throw new SyncValidationError('nflverse HTTP ' + response.status);
  return openSchedule(await response.text());
}
