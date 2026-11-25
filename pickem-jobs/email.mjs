const application = 'https://jcmor87.github.io/nfl-power-rankings/pickem/';
const escape = value => String(value).replace(/[&<>"']/g, character =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);

const pacific = new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/Los_Angeles', weekday: 'short', month: 'short', day: 'numeric',
  hour: 'numeric', minute: '2-digit', timeZoneName: 'short',
});
const rounds = { 1: 'Wild Card', 2: 'Divisional', 3: 'Conference Championships', 5: 'Super Bowl' };

export function renderEmail({ kind, phase = 'regular', week, reminder, weekly = [], standings = [],
  previous = [], differentiators = [] }) {
  const period = phase === 'postseason' ? rounds[week] :
    Number.isInteger(week) && week >= 1 && week <= 18 ? 'Week ' + week : null;
  if (!period || !['reminder', 'results'].includes(kind)) throw new Error('Invalid email period');
  const confirmation = reminder && reminder.completed === reminder.games;
  const subject = 'Family Pick’em · ' + period + ' ' +
    (kind === 'results' ? 'results' : confirmation ? 'picks complete' : 'reminder');
  const lines = [];
  const blocks = [];
  function paragraph(line) {
    lines.push(line);
    blocks.push('<p>' + escape(line) + '</p>');
  }
  function table(title, rows, includeDetails) {
    lines.push(title);
    blocks.push('<h2 style="font-size:20px">' + escape(title) + '</h2><table style="width:100%;border-collapse:collapse">' +
      '<thead><tr><th scope="col" align="left">Participant</th><th scope="col" align="right">Points</th></tr></thead><tbody>');
    for (const row of rows) {
      const old = !includeDetails && previous.find(item => item.id === row.id);
      const change = old ? old.rank - row.rank : 0;
      const movement = change > 0 ? 'Up ' + change : change < 0 ? 'Down ' + -change : '';
      const detail = includeDetails && row.correct !== undefined ?
        row.correct + ' correct · ' + row.incorrect + ' incorrect · ' + row.missed + ' missed' +
        (row.tied ? ' · ' + row.tied + ' tied' : '') : '';
      const name = '#' + row.rank + ' ' + row.name;
      lines.push([name, row.points + ' pts', detail, movement].filter(Boolean).join(' · '));
      const note = detail || movement;
      blocks.push('<tr><td style="padding:8px 4px;border-top:1px solid #44566a">' + escape(name) +
        (note ? '<br><small style="color:' + (change > 0 ? '#9feabf' : change < 0 ? '#ffb6b6' : '#d8e1ee') +
        '">' + escape(note) + '</small>' : '') + '</td><td align="right" style="border-top:1px solid #44566a">' +
        escape(row.points) + '</td></tr>');
    }
    blocks.push('</tbody></table>');
  }
  if (kind === 'reminder') {
    if (reminder) {
      paragraph('Hi ' + reminder.name + '!');
      paragraph(reminder.games + ' games · ' + reminder.completed + ' picks completed · ' +
        (reminder.games - reminder.completed) + ' outstanding');
      paragraph(confirmation ? 'All your picks are in.' : reminder.deadline ?
        'Earliest remaining pick deadline: ' + pacific.format(new Date(reminder.deadline)) :
        'No remaining unpicked games currently accept picks.');
    } else {
      paragraph('Make or update your picks before each game’s pick deadline.');
    }
  } else {
    if (weekly.length !== 5 || standings.length !== 5 || !weekly.some(row => row.rank === 1)) {
      throw new Error('Expected five ranked participants');
    }
    const winners = weekly.filter(row => row.rank === 1);
    paragraph((winners.length === 1 ? 'Weekly winner · ' : 'Shared weekly winners · ') +
      winners.map(row => row.name).join(', '));
    table('Weekly results', weekly, true);
    table('Season standings', standings, false);
    if (previous.length) {
      for (const [label, direction] of [['Risers', 1], ['Fallers', -1]]) {
        const names = standings.filter(row => {
          const old = previous.find(item => item.id === row.id);
          return old && (old.rank - row.rank) * direction > 0;
        }).map(row => row.name);
        paragraph(label + ' · ' + (names.join(', ') || 'None'));
      }
    }
    if (differentiators.length) {
      blocks.push('<h2 style="font-size:20px">Games that separated the field</h2>');
      lines.push('Games that separated the field');
      for (const game of differentiators) paragraph(game);
    }
  }
  return { subject, text: [subject, ...lines, application].join('\n'),
    html: '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" ' +
      'content="width=device-width,initial-scale=1"><title>' + escape(subject) + '</title></head>' +
      '<body style="margin:0;background:#071323;color:#f4f8ff;font:16px Arial,sans-serif">' +
      '<main style="max-width:560px;margin:auto;padding:20px;background:#11263d"><h1 style="font-size:25px">' +
      escape(subject) + '</h1>' + blocks.join('') +
      '<p style="margin:24px 0"><a style="display:inline-block;background:#9feabf;color:#102034;' +
      'padding:14px 20px;border-radius:6px;font-weight:bold" href="' + application +
      '">Open Family Pick’em</a></p></main></body></html>' };
}

export function prepareDraft(job, recipient) {
  const base = { kind: job.kind, phase: job.phase, week: job.week };
  if (job.kind === 'reminder') return { ...base, reminder: {
    name: recipient.name.trim().split(/\s+/)[0], games: job.gameCount,
    completed: recipient.completed, deadline: recipient.deadline,
  } };
  function cumulative(history) {
    const rows = job.recipients.map(({ id, name }) => ({ id, name,
      points: history.filter(row => row.id === id).reduce((total, row) => total + row.points, 0),
    })).sort((a, b) => b.points - a.points || a.name.localeCompare(b.name));
    return rows.map(row => ({ ...row, rank: rows.findIndex(other => other.points === row.points) + 1 }));
  }
  const weekly = job.recipients.map(({ id, name }) => {
    const score = job.history.find(row => row.id === id && row.weekId === job.weekId);
    if (!score) throw new Error('Incomplete weekly scoring');
    const detail = { correct: 0, incorrect: 0, missed: 0, tied: 0 };
    for (const game of job.finals) {
      const pick = game.picks[id];
      const key = pick == null ? 'missed' : game.winner == null ? 'tied' :
        pick === game.winner ? 'correct' : 'incorrect';
      detail[key]++;
    }
    if (score.points !== detail.correct) throw new Error('Final games and weekly scoring disagree');
    return { ...score, ...detail, name };
  }).sort((a, b) => a.rank - b.rank || a.name.localeCompare(b.name));
  const previous = job.history.filter(row => row.weekId !== job.weekId);
  const differentiators = job.finals.filter(game => game.winner != null).map(game => ({ ...game,
    correct: job.recipients.filter(({ id }) => game.picks[id] === game.winner).length,
  })).filter(game => game.correct > 0 && game.correct < job.recipients.length)
    .sort((a, b) => a.correct - b.correct || a.home.localeCompare(b.home)).slice(0, 3)
    .map(game => game.away + ' ' + game.awayScore + ' – ' + game.home + ' ' + game.homeScore +
      ' · ' + game.correct + ' of ' + job.recipients.length + ' picked the winner');
  return { ...base, weekly, standings: cumulative(job.history),
    previous: previous.length ? cumulative(previous) : [], differentiators };
}

// The transport must normalize unequivocal pre-acceptance rejection as failed.
// Exceptions and missing acceptance identifiers are held for reconciliation.
export async function deliverClaimedEmail({ claim, finish, transport, payload }) {
  const token = await claim();
  if (!token) return 'skipped';
  let result;
  try {
    result = await transport(payload);
  } catch {
    result = { status: 'ambiguous' };
  }
  const accepted = result?.status === 'accepted' && typeof result.messageId === 'string' &&
    result.messageId.trim();
  const status = accepted ? 'accepted' : result?.status === 'failed' ? 'failed' : 'ambiguous';
  if (!await finish(token, status, accepted ? result.messageId : null)) {
    throw new Error('Delivery state requires reconciliation; leave the claim held');
  }
  return status;
}

// Supply a server-side RPC client and a reviewed sender. An explicit dry run
// renders without claiming or calling the transport.
export async function runWeekEmail({ draft, recipients, weekId, dryRun = true, rpc, send }) {
  const message = renderEmail(draft);
  if (dryRun) return { message, outcomes: [] };
  if (!Number.isSafeInteger(weekId) || !Array.isArray(recipients) || recipients.length !== 5 ||
      new Set(recipients.map(row => row.id)).size !== 5 ||
      recipients.some(row => !row.id || typeof row.email !== 'string' || !row.email.includes('@'))) {
    throw new Error('Expected five privately resolved recipients for the selected week');
  }
  const outcomes = [];
  for (const recipient of recipients) {
    const status = await deliverClaimedEmail({
      claim: () => rpc('claim_pickem_email', { p_week_id: weekId, p_participant_id: recipient.id, p_kind: draft.kind }),
      finish: (token, status, messageId) => rpc('finish_pickem_email', {
        p_claim: token, p_status: status, p_provider_message_id: messageId,
      }),
      transport: send,
      payload: { ...message, to: recipient.email },
    });
    outcomes.push(status);
  }
  return { outcomes };
}
