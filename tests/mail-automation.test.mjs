import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { createBrevo } from '../pickem-jobs/brevo.mjs';
import { prepareDraft, renderEmail } from '../pickem-jobs/email.mjs';
import { previews } from '../pickem-jobs/email-fixtures.mjs';
import { runMail } from '../pickem-jobs/mail-runner.mjs';

const roster = ['Alex Sample', 'Blair Sample', 'Casey Sample', 'Drew Sample', 'Ellis Sample'].map((name, i) => ({
  id: String(i), name, email: 'person' + i + '@example.invalid', completed: i + 1, deadline: '2026-12-04T01:15:00Z',
}));
const reminder = { kind: 'reminder', phase: 'regular', week: 13, weekId: 8, revision: null, gameCount: 5, recipients: roster };

test('personalized reminder includes Pacific deadline, outstanding count and only the recipient', () => {
  const draft = renderEmail(prepareDraft(reminder, roster[0]));
  assert.match(draft.text, /Hi Alex!/);
  assert.match(draft.text, /5 games · 1 picks completed · 4 outstanding/);
  assert.match(draft.text, /5:15 PM PST/);
  assert.doesNotMatch(draft.text, /Blair|example\.invalid/);
  const confirmation = renderEmail(prepareDraft(reminder, roster[4]));
  assert.match(confirmation.subject, /picks complete/);
  assert.match(confirmation.text, /All your picks are in/);
  assert.doesNotMatch(confirmation.text, /deadline/);
});

test('postseason results show tied winners, correct, incorrect, missed, tied, and cumulative changes', () => {
  const history = [1, 1, 0, 0, 0].map((points, i) => ({ id: String(i), points, weekId: 9, rank: i < 2 ? 1 : 3 }));
  history.push(...[0, 1, 2, 0, 0].map((points, i) => ({ id: String(i), points, weekId: 8 })));
  const job = { kind: 'results', phase: 'postseason', week: 5, weekId: 9, recipients: roster, history, finals: [
    { away: 'DEM', home: 'SYN', awayScore: 20, homeScore: 24, winner: 4, picks: { 0: 4, 1: 4, 2: 5 } },
    { away: 'FOO', home: 'BAR', awayScore: 20, homeScore: 20, winner: null, picks: { 1: 9 } },
  ] };
  const message = renderEmail(prepareDraft(job, roster[0]));
  assert.match(message.subject, /Super Bowl/);
  assert.match(message.text, /Shared weekly winners · Alex Sample, Blair Sample/);
  assert.match(message.text, /1 correct · 0 incorrect · 0 missed · 1 tied/);
  assert.match(message.text, /0 correct · 1 incorrect · 1 missed/);
  assert.match(message.text, /Risers · Blair Sample/);
  assert.match(message.text, /Fallers · Drew Sample, Ellis Sample/);
  assert.match(message.text, /2 of 5 picked the winner/);
  assert.throws(() => prepareDraft({ ...job, history: [] }, roster[0]), /Incomplete weekly scoring/);
});

test('overlapping workers claim each delivery at most once and hold unknown outcomes', async () => {
  const claimed = new Set();
  const sent = [];
  const finished = [];
  const rpc = async (name, args) => {
    if (name === 'pickem_mail_work') return [reminder];
    if (name === 'claim_pickem_mail_job') {
      if (claimed.has(args.p_participant_id)) return null;
      claimed.add(args.p_participant_id);
      return args.p_participant_id;
    }
    finished.push(args);
    return true;
  };
  const send = async message => {
    sent.push(message);
    if (message.to === roster[0].email) throw new Error('private timeout details');
    return { status: 'accepted', messageId: 'synthetic-provider-id' };
  };
  const both = await Promise.all([runMail({ rpc, send }), runMail({ rpc, send })]);
  assert.equal(both.reduce((sum, row) => sum + row.ambiguous, 0), 1);
  assert.equal(sent.length, 5);
  assert.equal(new Set(sent.map(row => row.deliveryKey)).size, 5);
  assert.equal(finished.find(row => row.p_claim === '0').p_provider_message_id, null);
  assert.equal(finished.find(row => row.p_claim === '0').p_status, 'ambiguous');
  await assert.rejects(runMail({ rpc: async () => [{ ...reminder, recipients: roster.slice(0, 4) }], send }),
    /exactly five/);
});

test('Brevo contract separates definite failures, ambiguous responses and delivery events', async () => {
  const responses = [
    [201, { messageId: 'synthetic-id' }], [429, { code: 'too_many_requests' }],
    [400, { code: 'duplicate_parameter' }], [502, {}], [201, {}],
    [200, { events: [{ messageId: 'other', event: 'delivered' }, { messageId: 'synthetic-id', event: 'hardBounce' }] }],
  ];
  let sent = false;
  const brevo = createBrevo('synthetic-key', 'owner@example.invalid', async (url, options) => {
    assert.equal(new URL(url).origin, 'https://api.brevo.com');
    assert.equal(options.redirect, 'error');
    assert.equal(options.headers['api-key'], 'synthetic-key');
    if (options.method === 'POST') {
      assert.deepEqual(JSON.parse(options.body).to, [{ email: 'synthetic@example.invalid' }]);
      assert.equal(JSON.parse(options.body).headers.IdempotencyKey, 'stable-key');
      sent = true;
    } else {
      assert.equal(new URL(url).searchParams.get('messageId'), 'synthetic-id');
    }
    const [status, body] = responses.shift();
    return Response.json(body, { status });
  });
  const payload = { ...renderEmail(previews.reminder), to: 'synthetic@example.invalid', deliveryKey: 'stable-key' };
  for (const status of ['accepted', 'failed', 'ambiguous', 'ambiguous', 'ambiguous']) {
    assert.equal((await brevo.send(payload)).status, status);
  }
  assert.ok(sent);
  assert.equal(await brevo.tracking('synthetic-id'), 'bounced');
});

test('CLI defaults to synthetic, rejects apply with either switch or branch guard off, and redacts failures', () => {
  const script = 'pickem-jobs/send-pickem-mail.mjs';
  const env = { ...process.env, GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: 'jcmor87/nfl-power-rankings',
    GITHUB_REF: 'refs/heads/main', PICKEM_EMAIL_ENABLED: 'false', PICKEM_EMAIL_TEST_ENABLED: 'false',
    PICKEM_BREVO_API_KEY: 'test-do-not-print', PICKEM_BREVO_SENDER: 'owner@example.invalid' };
  const preview = spawnSync(process.execPath, [script], { env, encoding: 'utf8' });
  assert.equal(preview.status, 0);
  assert.match(preview.stdout, /No external requests/);
  for (const [command, overrides] of [['--apply', {}], ['--test-sender', {}],
    ['--apply', { PICKEM_EMAIL_ENABLED: 'true', GITHUB_REF: 'refs/heads/feature/nfl-family-pickem' }]]) {
    const refused = spawnSync(process.execPath, [script, command], { env: { ...env, ...overrides }, encoding: 'utf8' });
    assert.equal(refused.status, 1);
    assert.match(refused.stderr, /configuration/);
    assert.doesNotMatch(refused.stderr + refused.stdout, /test-do-not-print|owner@example\.invalid/);
  }
  const workflow = readFileSync('.github/workflows/pickem-email.yml', 'utf8');
  assert.match(workflow, /refs\/heads\/main[\s\S]+PICKEM_EMAIL_ENABLED == 'true'[\s\S]+environment: pickem-production/);
  assert.doesNotMatch(workflow.split('  owner-test:')[0], /secrets\./);
});

test('tracked previews contain responsive markup and only escaped synthetic content', () => {
  for (const [kind, fixture] of Object.entries(previews)) {
    const html = renderEmail(fixture).html;
    assert.equal(readFileSync('docs/email-previews/' + kind + '.html', 'utf8'), html + '\n');
    assert.match(html, /width=device-width/);
    assert.match(html, /max-width:560px/);
    assert.doesNotMatch(html, /<script|api.key|@/);
  }
  const quoted = renderEmail({ ...previews.reminder, reminder: { ...previews.reminder.reminder, name: '<img>' } });
  assert.match(quoted.html, /&lt;img&gt;/);
});
