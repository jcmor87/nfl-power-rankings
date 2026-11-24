import { supabaseUrl, supabasePublishableKey } from './config.mjs';

const access = document.querySelector('#access');
const board = document.querySelector('#board');
const form = document.querySelector('#sign-in');
const authStatus = document.querySelector('#auth-status');
const pickStatus = document.querySelector('#pick-status');
const progress = document.querySelector('#progress');
const games = document.querySelector('#games');
const exit = document.querySelector('#exit');
const demo = document.querySelector('#demo');
const publicKey = /^sb_publishable_[A-Za-z0-9_-]+$/.test(supabasePublishableKey) ?
  supabasePublishableKey : '';
const endpoint = /^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/.test(supabaseUrl) ?
  supabaseUrl.replace(/\/$/, '') : '';

const matchups = [
  { teams: ['Cascade Foxes', 'Harbor Owls'], kickoff: '2030-10-06T17:00:00Z' },
  { teams: ['Mesa Runners', 'Prairie Bison'], kickoff: '2030-10-06T20:25:00Z' },
  { teams: ['Coast Seals', 'Summit Rams'], kickoff: '2030-10-07T00:20:00Z' },
];
const picks = new Map();
const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });
let sessionTimer;
let accessToken;

function showBoard(expiresIn) {
  authStatus.textContent = '';
  access.hidden = true;
  board.hidden = false;
  exit.textContent = expiresIn ? 'Sign out' : 'Exit preview';
  if (expiresIn) sessionTimer = setTimeout(() => showAccess('Session expired. Sign in again.'), expiresIn * 1000);
  exit.focus();
}

function showAccess(message = '') {
  clearTimeout(sessionTimer);
  accessToken = undefined;
  picks.clear();
  games.querySelectorAll('button').forEach((button) => button.setAttribute('aria-pressed', 'false'));
  updateProgress();
  pickStatus.textContent = '';
  board.hidden = true;
  access.hidden = false;
  authStatus.textContent = message;
  demo.focus();
}

function updateProgress() {
  progress.textContent = picks.size + ' of ' + matchups.length + ' picks made';
}

for (const [index, matchup] of matchups.entries()) {
  const card = document.createElement('article');
  card.className = 'game';
  const title = document.createElement('h3');
  title.id = 'matchup-' + index;
  title.textContent = matchup.teams.join(' at ');
  const kickoff = document.createElement('time');
  kickoff.dateTime = matchup.kickoff;
  kickoff.textContent = dateFormat.format(new Date(matchup.kickoff));
  const schedule = document.createElement('p');
  schedule.className = 'kickoff';
  schedule.append(kickoff);
  const choices = document.createElement('div');
  choices.className = 'choices';
  choices.setAttribute('role', 'group');
  choices.setAttribute('aria-labelledby', title.id);

  for (const team of matchup.teams) {
    const button = document.createElement('button');
    button.className = 'choice';
    button.type = 'button';
    button.textContent = team;
    button.setAttribute('aria-pressed', 'false');
    button.addEventListener('click', () => {
      picks.set(index, team);
      for (const choice of choices.children) choice.setAttribute('aria-pressed', String(choice === button));
      updateProgress();
      pickStatus.textContent = 'Sample pick set to ' + team + ' for this preview.';
    });
    choices.append(button);
  }

  card.append(title, schedule, choices);
  games.append(card);
}

demo.addEventListener('click', () => showBoard());
exit.addEventListener('click', async () => {
  const token = accessToken;
  showAccess();
  if (!token) return;
  try {
    const response = await fetch(endpoint + '/auth/v1/logout?scope=local', {
      method: 'POST', headers: { apikey: publicKey, Authorization: 'Bearer ' + token },
      redirect: 'error', signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) throw new Error('Logout unavailable');
  } catch {
    if (!access.hidden && !demo.disabled) {
      authStatus.textContent = 'Signed out of this preview. The server could not confirm logout.';
    }
  }
});

if (endpoint && publicKey) form.hidden = false;
form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!endpoint || !publicKey) return;
  const button = form.querySelector('button');
  button.disabled = true;
  demo.disabled = true;
  authStatus.textContent = 'Signing in…';
  const { email, password } = form.elements;
  try {
    const result = await fetch(endpoint + '/auth/v1/token?grant_type=password', {
      method: 'POST', headers: { apikey: publicKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: email.value.trim(), password: password.value }),
      redirect: 'error', signal: AbortSignal.timeout(12_000),
    });
    if (!result.ok) {
      authStatus.textContent = result.status === 400 || result.status === 401 ?
        'Check your email and password and try again.' : 'Sign-in is unavailable. Try again shortly.';
      return;
    }
    const session = await result.json();
    if (!session.access_token || !Number.isFinite(session.expires_in) || session.expires_in <= 0) {
      throw new Error('Invalid Auth response');
    }
    const headers = { apikey: publicKey, Authorization: 'Bearer ' + session.access_token };
    const accessCheck = await fetch(endpoint + '/rest/v1/participants?select=id&limit=1', {
      headers, redirect: 'error', signal: AbortSignal.timeout(12_000),
    });
    if (!accessCheck.ok) throw new Error('Unverified access');
    const allowed = await accessCheck.json();
    if (allowed.length !== 1) {
      authStatus.textContent = 'This account does not have Pick’em access.';
      return;
    }
    form.reset();
    accessToken = session.access_token;
    showBoard(session.expires_in);
  } catch {
    authStatus.textContent = 'Could not verify sign-in. Try again shortly.';
  } finally {
    password.value = '';
    demo.disabled = false;
    button.disabled = false;
  }
});
