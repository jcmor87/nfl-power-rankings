import { SyncValidationError } from './sync-validation-error.mjs';
import { postseasonRounds } from './nfl-competition.mjs';

export function reconcile({ teams, observations, reference, season, phase, week }) {
  const expectedCount = phase === 'postseason' ? postseasonRounds[week].games : reference.length;
  if (!expectedCount || expectedCount > 16 || reference.length !== expectedCount || observations.length !== expectedCount) {
    throw new SyncValidationError('Schedule coverage differs between providers');
  }
  const key = (home, away) => home + ':' + away;
  const expected = new Map(reference.map(game => [key(game.home, game.away), game]));
  if (expected.size !== expectedCount || new Set(reference.map(game => game.id)).size !== expectedCount ||
      new Set(reference.flatMap(game => [game.home, game.away])).size !== expectedCount * 2) {
    throw new SyncValidationError('Duplicate matchups or teams in the reference schedule');
  }
  const codes = new Map(teams.map(team => [String(team.providerId), team.code]));
  const games = observations.map(game => {
    const home = codes.get(game.homeSourceTeamId);
    const away = codes.get(game.awaySourceTeamId);
    const other = expected.get(key(home, away));
    if (!other) throw new SyncValidationError('Unmatched or duplicate provider matchup');
    expected.delete(key(home, away));
    const kickoffAgrees = game.kickoffAt && game.kickoffAt === other.kickoffAt;
    if ((game.status === 'scheduled' || game.status === 'final') && !kickoffAgrees) {
      throw new SyncValidationError('Kickoff requires matching evidence');
    }
    if (game.status === 'final' &&
        (game.homeScore !== other.homeScore || game.awayScore !== other.awayScore)) {
      throw new SyncValidationError('Final score requires matching evidence');
    }
    if (game.status === 'canceled' && other.status !== 'canceled') {
      throw new SyncValidationError('Cancellation requires explicit corroboration. The current reference may omit canceled games.');
    }
    if (game.status !== 'final' && (other.homeScore != null || other.awayScore != null)) {
      throw new SyncValidationError('Provider game status conflicts with published reference scores');
    }
    return { provider_id: game.sourceGameId, reference_id: other.id, home, away, status: game.status,
      kickoff_at: kickoffAgrees ? game.kickoffAt : null, observed_at: game.observedAt,
      home_score: game.homeScore, away_score: game.awayScore };
  });
  return { season, phase, week, teams, games };
}
