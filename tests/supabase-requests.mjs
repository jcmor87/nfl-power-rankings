import { setTimeout as delay } from 'node:timers/promises';

const legacy = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
const transientCodes = new Set([
  'EAI_AGAIN', 'ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'EPIPE',
  'ENETUNREACH', 'EHOSTUNREACH', 'UND_ERR_CONNECT_TIMEOUT', 'UND_ERR_HEADERS_TIMEOUT',
  'UND_ERR_BODY_TIMEOUT', 'UND_ERR_SOCKET', 'TIMEOUT',
]);
const safeCodes = new Set([...transientCodes, 'ENOTFOUND', 'CERT_HAS_EXPIRED',
  'UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'SELF_SIGNED_CERT_IN_CHAIN',
  'DEPTH_ZERO_SELF_SIGNED_CERT', 'ERR_TLS_CERT_ALTNAME_INVALID']);

export class RequestFailure extends Error {
  constructor(method, endpoint, status, kind, uncertain = false) {
    super(method + ' ' + endpoint + ' · HTTP ' + (status ?? 'unavailable') + ' · ' + kind);
    this.uncertain = uncertain;
  }
}

export function loadConnection(env) {
  if (Number(process.versions.node.split('.')[0]) < 20 || typeof fetch !== 'function') {
    throw new Error('Node.js 20 or later is required.');
  }
  const parseOrigin = (raw = '') => {
    const value = raw.trim();
    if (!/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$|^http:\/\/(?:localhost|127\.0\.0\.1):[0-9]+\/?$/.test(value)) return null;
    try { return new URL(value).origin; } catch { return null; }
  };
  const origin = parseOrigin(env.PICKEM_TEST_URL);
  if (!origin || origin !== parseOrigin(env.PICKEM_TEST_CONFIRM_ORIGIN)) {
    throw new Error('Enter matching Supabase project origins, without an API path.');
  }
  const publicKey = env.PICKEM_TEST_PUBLIC_KEY?.trim();
  const serviceKey = env.PICKEM_TEST_SERVICE_KEY?.trim();
  if (!publicKey || !serviceKey || publicKey === serviceKey ||
      !(legacy.test(publicKey) || /^sb_publishable_[A-Za-z0-9_-]+$/.test(publicKey)) ||
      !(legacy.test(serviceKey) || /^sb_secret_[A-Za-z0-9_-]+$/.test(serviceKey))) {
    throw new Error('Enter distinct publishable and service API keys in their matching prompts.');
  }
  return { origin, publicKey, serviceKey };
}

function networkCode(error, signal) {
  if (signal.aborted) return 'TIMEOUT';
  const nested = error?.cause?.errors;
  for (const cause of [error?.cause, ...(Array.isArray(nested) ? nested : []), error]) {
    if (typeof cause?.code === 'string' && safeCodes.has(cause.code)) return cause.code;
  }
  return 'NetworkError';
}

export function makeRequest({ origin, publicKey, fetcher = fetch, pause = delay, retryLog = console.warn }) {
  return async function request(label, path, { actor = { key: publicKey }, method = 'GET', body, prefer, status, code } = {}) {
    const endpoint = path.split('?')[0].replace(/^\/auth\/v1\/admin\/users\/.+$/, '/auth/v1/admin/users/:id');
    const headers = { apikey: actor.key };
    // The gateway resolves opaque keys from apikey. Authorization carries an
    // Auth session JWT, or a legacy JWT key when exercising an older stack.
    const token = actor.token ?? (legacy.test(actor.key) ? actor.key : null);
    if (token) headers.Authorization = 'Bearer ' + token;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (prefer) headers.Prefer = prefer;

    for (let attempt = 1; ; attempt++) {
      const signal = AbortSignal.timeout(12_000);
      let response, raw, failure, retry = false;
      try {
        response = await fetcher(origin + path, {
          method, headers, body: body === undefined ? undefined : JSON.stringify(body),
          redirect: 'manual', signal,
        });
        raw = await response.text();
      } catch (error) {
        const kind = networkCode(error, signal);
        failure = new RequestFailure(method, endpoint, response?.status, label + ' · ' + kind, method !== 'GET');
        retry = transientCodes.has(kind);
      }
      if (!failure) {
        const accepted = Array.isArray(status) ? status.includes(response.status) :
          status === undefined ? response.ok : response.status === status;
        if (accepted) {
          let value;
          try { value = raw ? JSON.parse(raw) : null; } catch {
            throw new RequestFailure(method, endpoint, response.status, label + ' · InvalidJSON', method !== 'GET');
          }
          if (code && (value?.error_code ?? value?.code) !== code) {
            throw new RequestFailure(method, endpoint, response.status, label + ' · unexpected error code');
          }
          return { value, serverTime: Date.parse(response.headers.get('date')) };
        }
        retry = [429, 500, 502, 503, 504].includes(response.status);
        failure = new RequestFailure(method, endpoint, response.status, label + ' · UnexpectedStatus',
          method !== 'GET' && (response.ok || response.status === 408 || response.status >= 500));
      }
      if (method !== 'GET' || !retry || attempt === 3) throw failure;
      retryLog('RETRY ' + attempt + '/2 · ' + failure.message);
      await pause(attempt * 250);
    }
  };
}

// Reconcile a lost mutation response by reading the resource. Never resend a
// mutation based solely on a transport error.
export async function reconcileMutation(action, verify) {
  try {
    await action();
  } catch (error) {
    if (!(error instanceof RequestFailure) || !error.uncertain || !await verify()) throw error;
    return;
  }
  if (!await verify()) throw new Error('Cleanup verification failed.');
}
