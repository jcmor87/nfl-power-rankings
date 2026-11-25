const application = 'https://jcmor87.github.io/nfl-power-rankings/pickem/';
const escape = value => String(value).replace(/[&<>"']/g, character =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);

export function renderEmail({ kind, week, weekly = [], standings = [], previous = [] }) {
  if (!Number.isInteger(week) || week < 1 || week > 18 || !['reminder', 'results'].includes(kind)) {
    throw new Error('Expected a regular-season email');
  }
  const subject = 'Family Pick’em · Week ' + week + (kind === 'results' ? ' results' : ' reminder');
  const lines = [];
  if (kind === 'reminder') {
    lines.push('Make or update your picks before each game kicks off.');
  } else {
    if (weekly.length !== 5 || standings.length !== 5 || !weekly.some(row => row.rank === 1)) {
      throw new Error('Expected five ranked participants and at least one weekly winner');
    }
    const winners = weekly.filter(row => row.rank === 1);
    lines.push((winners.length === 1 ? 'Weekly winner · ' : 'Shared weekly winners · ') +
      winners.map(row => row.name).join(', '), 'Weekly results');
    const movement = weekly.map(row => {
      const old = previous.find(item => item.id === row.id);
      return { ...row, change: old ? old.rank - row.rank : 0 };
    });
    for (const row of movement) {
      const change = row.change > 0 ? ' · Up ' + row.change :
        row.change < 0 ? ' · Down ' + Math.abs(row.change) : '';
      lines.push('#' + row.rank + ' · ' + row.name + ' · ' + row.points + ' pts' + change);
    }
    for (const [label, direction] of [['Risers', 1], ['Fallers', -1]]) {
      const names = movement.filter(row => row.change * direction > 0).map(row => row.name);
      if (names.length) lines.push(label + ' · ' + names.join(', '));
    }
    lines.push('Season standings');
    for (const row of standings) lines.push('#' + row.rank + ' · ' + row.name + ' · ' + row.points + ' pts');
  }
  return { subject, text: [subject, ...lines, application].join('\n'),
    html: '<main style="max-width:36rem;margin:auto;padding:1rem;font:16px system-ui">' +
      '<h1>' + escape(subject) + '</h1>' + lines.map(line => '<p>' + escape(line) + '</p>').join('') +
      '<p><a href="' + application + '">Open Family Pick’em</a></p></main>' };
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
