import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeGames } from '../pickem-data/balldontlie.mjs';
import { deliverClaimedEmail, renderEmail } from '../pickem-jobs/email.mjs';

const schedule = { id: 1, season: 2999, week: 1, postseason: false,
  date: '2999-09-10T17:00:00Z', updated_at: '2999-09-01T00:00:00Z',
  home_team: { id: 2 }, visitor_team: { id: 3 }, status_state: 'scheduled' };
const expected = { season: 2999, week: 1, expectedIds: [1] };
const snapshot = (game, meta = {}) => ({ data: [game], meta });
const status = game => normalizeGames(snapshot(game), expected)[0].status;

test('provider observations fail closed for incomplete or ambiguous data', () => {
  assert.equal(status(schedule), 'scheduled');
  assert.equal(status({ ...schedule, date: 'TBD' }), 'unknown');
  assert.equal(status({ ...schedule, status_state: 'suspended' }), 'suspended');
  assert.equal(status({ ...schedule, status_state: 'canceled' }), 'canceled');
  assert.equal(status({ ...schedule, status_state: 'postponed' }), 'postponed');
  assert.equal(status({ ...schedule, status_state: 'abandoned' }), 'unknown');
  assert.throws(() => normalizeGames(snapshot(schedule, { next_cursor: 55 }), expected));
  assert.throws(() => normalizeGames(snapshot({ ...schedule, id: 9 }), expected));
  assert.equal(status({ ...schedule, status_state: 'final' }), 'unknown');
  const final = { ...schedule, status_state: 'final', home_team_score: 7, visitor_team_score: 0 };
  assert.equal(status(final), 'final');
  assert.equal(normalizeGames(snapshot({ ...final, home_team_score: 14 }), expected)[0].homeScore, 14);
});

test('results use shared winners, standings, movement and escaped HTML', () => {
  const rows = Array.from({ length: 5 }, (_, i) =>
    ({ id: i, name: 'Synthetic <' + i + '>', rank: i < 2 ? 1 : i + 1, points: 5 - i }));
  const email = renderEmail({ kind: 'results', week: 2, weekly: rows, standings: rows,
    previous: [{ id: 0, rank: 3 }, { id: 3, rank: 1 }] });
  assert.match(email.text, /Shared weekly winners/);
  assert.match(email.text, /Risers.*Fallers/s);
  assert.match(email.text, /Season standings/);
  assert.match(email.html, /Synthetic &lt;0&gt;/);
  assert.doesNotMatch(email.html, /Synthetic <0>/);
});

test('a held claim suppresses send and uncertainty is recorded without retries', async () => {
  const finish = async (_, status) => { assert.equal(status, 'ambiguous'); return true; };
  assert.equal(await deliverClaimedEmail({ claim: async () => null, finish,
    transport: () => assert.fail('Duplicate send') }), 'skipped');
  assert.equal(await deliverClaimedEmail({ claim: async () => 'fixture', finish,
    transport: async () => { throw new Error('Unknown outcome'); } }), 'ambiguous');
});
