import { createHash } from 'node:crypto';
import { deliverClaimedEmail, prepareDraft, renderEmail } from './email.mjs';

export async function runMail({ rpc, send }) {
  const jobs = await rpc('pickem_mail_work');
  if (!Array.isArray(jobs)) throw new Error('Invalid mail work response');
  const counts = { accepted: 0, skipped: 0, failed: 0, ambiguous: 0, held: 0 };
  for (const job of jobs) {
    const recipients = job.recipients;
    if (recipients.length !== 5 || new Set(recipients.map(row => row.id)).size !== 5 ||
        new Set(recipients.map(row => row.email.toLowerCase())).size !== 5 ||
        recipients.some(row => !/^[^\s@]+@[^\s@]+$/.test(row.email))) {
      throw new Error('Mail requires exactly five distinct verified recipients');
    }
    for (const recipient of recipients) {
      if (recipient.delivery === 'claimed' || recipient.delivery === 'ambiguous' ||
          (recipient.delivery === 'failed' && recipient.attempts >= 3)) {
        if (recipient.delivery !== 'claimed' || recipient.staleClaim) counts.held++;
        continue;
      }
      if (recipient.delivery === 'accepted') continue;
      const payload = { ...renderEmail(prepareDraft(job, recipient)), to: recipient.email,
        deliveryKey: createHash('sha256').update([job.weekId, recipient.id, job.kind].join(':')).digest('hex') };
      const status = await deliverClaimedEmail({
        claim: () => rpc('claim_pickem_mail_job', { p_week_id: job.weekId, p_participant_id: recipient.id,
          p_kind: job.kind, p_revision: job.revision }),
        finish: (token, status, messageId) => rpc('finish_pickem_email', {
          p_claim: token, p_status: status, p_provider_message_id: messageId,
        }),
        transport: send, payload,
      });
      counts[status]++;
    }
  }
  return counts;
}
