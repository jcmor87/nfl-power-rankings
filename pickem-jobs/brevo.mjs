const endpoint = 'https://api.brevo.com/v3/';

export function createBrevo(apiKey, sender, request = fetch) {
  function call(path, options) {
    return request(endpoint + path, {
      ...options, redirect: 'error', signal: AbortSignal.timeout(12000),
      headers: { 'api-key': apiKey, accept: 'application/json', 'content-type': 'application/json' },
    });
  }

  return {
    async send({ to, subject, text, html, deliveryKey }) {
      const response = await call('smtp/email', {
        method: 'POST',
        body: JSON.stringify({
          sender: { name: 'NFL Family Pick’em', email: sender }, to: [{ email: to }],
          subject, textContent: text, htmlContent: html, headers: { IdempotencyKey: deliveryKey },
        }),
      });
      const body = await response.json().catch(() => null);
      if (response.ok && typeof body?.messageId === 'string' && body.messageId.trim()) {
        return { status: 'accepted', messageId: body.messageId };
      }
      if (body?.code === 'duplicate_parameter') return { status: 'ambiguous' };
      return { status: [400, 401, 403, 404, 413, 422, 429].includes(response.status) ? 'failed' : 'ambiguous' };
    },
    async tracking(messageId) {
      const query = new URLSearchParams({ messageId, days: '7', limit: '50' });
      const response = await call('smtp/statistics/events?' + query, { method: 'GET' });
      if (!response.ok) throw new Error('Provider tracking request failed');
      const body = await response.json();
      if (!Array.isArray(body.events)) throw new Error('Invalid provider tracking response');
      const events = new Set(body.events.filter(event => event.messageId === messageId).map(event => event.event));
      if (events.has('delivered')) return 'delivered';
      if (events.has('hardBounce') || events.has('invalid')) return 'bounced';
      if (events.has('blocked') || events.has('error')) return 'blocked';
      return null;
    },
  };
}
