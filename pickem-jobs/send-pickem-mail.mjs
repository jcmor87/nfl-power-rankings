import { mkdir, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { createBrevo } from './brevo.mjs';
import { renderEmail } from './email.mjs';
import { previews } from './email-fixtures.mjs';
import { runMail } from './mail-runner.mjs';

const address = /^[^\s@]+@[^\s@]+$/;
const args = process.argv.slice(2);
let stage = 'configuration';

function database(url, secret) {
  return async function request(path, method, data) {
    const response = await fetch(url + '/rest/v1/' + path, {
      method, redirect: 'error', signal: AbortSignal.timeout(12000),
      headers: { apikey: secret, 'Content-Type': 'application/json' },
      body: data === undefined ? undefined : JSON.stringify(data),
    });
    if (!response.ok) throw new Error('Database request failed');
    if (response.status !== 204) return response.json();
  };
}

async function track(request, transport) {
  const now = new Date();
  const cutoff = new Date(+now - 45 * 60_000).toISOString();
  const recent = new Date(+now - 7 * 86400_000).toISOString();
  const query = new URLSearchParams({
    select: 'id,provider_message_id,updated_at', status: 'eq.accepted',
    delivery_status: 'is.null', order: 'delivery_checked_at.asc.nullsfirst,id.asc', limit: '10',
    or: '(delivery_checked_at.is.null,delivery_checked_at.lt.' + cutoff + ')',
  });
  const unresolved = new URLSearchParams({
    select: 'id', updated_at: 'gte.' + recent, limit: '1',
    or: '(status.eq.ambiguous,status.eq.failed,and(status.eq.claimed,updated_at.lt.' +
      new Date(+now - 20 * 60_000).toISOString() + '),delivery_status.in.(bounced,blocked,unconfirmed))',
  });
  for (const row of await request('email_log?' + query, 'GET')) {
    const age = +now - Date.parse(row.updated_at);
    const event = age < 7 * 86400_000 ? await transport.tracking(row.provider_message_id) : null;
    const filters = new URLSearchParams({ id: 'eq.' + row.id, status: 'eq.accepted', delivery_status: 'is.null' });
    await request('email_log?' + filters, 'PATCH', {
      delivery_checked_at: now.toISOString(), delivery_status: event ?? (age >= 2 * 86400_000 ? 'unconfirmed' : null),
    });
  }
  return (await request('email_log?' + unresolved, 'GET')).length > 0;
}

try {
  if (!args.length || (args[0] === '--preview-dir' && args.length === 2)) {
    stage = 'synthetic preview';
    if (args.length) await mkdir(args[1], { recursive: true });
    for (const [kind, fixture] of Object.entries(previews)) {
      const rendered = renderEmail(fixture);
      if (args.length) await writeFile(args[1] + '/' + kind + '.html', rendered.html + '\n');
    }
    console.log('Rendered three synthetic previews. No external requests.');
  } else {
    const isTest = args.length === 1 && args[0] === '--test-sender';
    if ((args.length !== 1 || (args[0] !== '--apply' && !isTest)) ||
        process.env.GITHUB_ACTIONS !== 'true' || process.env.GITHUB_REPOSITORY !== 'jcmor87/nfl-power-rankings' ||
        process.env.GITHUB_REF !== 'refs/heads/main') throw new Error('Protected workflow required');
    if (process.env[isTest ? 'PICKEM_EMAIL_TEST_ENABLED' : 'PICKEM_EMAIL_ENABLED'] !== 'true') {
      throw new Error('Delivery disabled');
    }
    const { PICKEM_BREVO_API_KEY: key, PICKEM_BREVO_SENDER: sender,
      SUPABASE_URL: url, SUPABASE_SECRET_KEY: secret } = process.env;
    if (!key?.trim() || !address.test(sender ?? '')) throw new Error('Invalid provider configuration');
    const transport = createBrevo(key, sender);
    if (isTest) {
      stage = 'owner mailbox test';
      const message = renderEmail(previews.reminder);
      const response = await transport.send({
        ...message, subject: '[Synthetic owner test] ' + message.subject, to: sender, deliveryKey: randomUUID(),
      });
      if (response.status !== 'accepted') throw new Error('Owner mailbox acceptance unconfirmed');
      console.log('Provider accepted the synthetic owner test. Confirm inbox delivery in Brevo and in your mailbox.');
    } else {
      if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url ?? '') ||
          !/^sb_secret_[A-Za-z0-9_-]+$/.test(secret ?? '')) throw new Error('Invalid database configuration');
      const request = database(url, secret);
      stage = 'claim and delivery';
      const counts = await runMail({ rpc: (name, data = {}) => request('rpc/' + name, 'POST', data), send: transport.send });
      console.log('Mail counts: ' + JSON.stringify(counts));
      stage = 'delivery tracking';
      const unresolved = await track(request, transport);
      if (unresolved || counts.failed || counts.ambiguous || counts.held) {
        throw new Error('Unresolved delivery needs review');
      }
    }
  }
} catch {
  console.error('Pick’em mail failed during ' + stage + '. Review protected provider and database dashboards.');
  process.exitCode = 1;
}
