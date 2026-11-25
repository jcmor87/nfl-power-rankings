export const teamCodes = Object.freeze(('ARI ATL BAL BUF CAR CHI CIN CLE DAL DEN DET GB HOU IND JAX KC ' +
  'LA LAC LV MIA MIN NE NO NYG NYJ PHI PIT SEA SF TB TEN WAS').split(' '));
const aliases = { LAR: 'LA', JAC: 'JAX', WSH: 'WAS' };
export const canonicalTeam = code => Object.hasOwn(aliases, code) ? aliases[code] : code;

export const postseasonRounds = Object.freeze({
  1: { label: 'Wild Card', games: 6, feed: 'WC' },
  2: { label: 'Divisional Round', games: 4, feed: 'DIV' },
  3: { label: 'Conference Championships', games: 2, feed: 'CON' },
  5: { label: 'Super Bowl', games: 1, feed: 'SB' },
});

export function validWeek(season, phase, week) {
  return Number.isInteger(season) && season >= 2002 && season <= 9999 && Number.isInteger(week) &&
    (phase === 'regular' ? week >= 1 && week <= 18 : phase === 'postseason' && Object.hasOwn(postseasonRounds, week));
}
