import { supabaseUrl, supabasePublishableKey } from './config.mjs';

const byId = (id) => document.getElementById(id);
const buttons = [...document.querySelectorAll('[data-section]')];
const titles = { picks: 'Make Picks', weekly: 'Weekly Results', season: 'Season Standings', history: 'Competition History' };
const pacific = new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/Los_Angeles', weekday: 'short', month: 'short', day: 'numeric',
  hour: 'numeric', minute: '2-digit', timeZoneName: 'short',
});
const state = { generation: 0 };
let poll;
let timer;
let loadVersion = 0;
let refreshingGeneration;

class RequestFailure extends Error {
  constructor(operation, kind, status) {
    super(kind);
    this.operation = operation;
    this.kind = kind;
    this.status = status;
  }
}

function reportFailure(message, operation, error) {
  const kinds = ['TypeError', 'RangeError', 'SyntaxError', 'ReferenceError', 'AbortError'];
  const kind = error instanceof RequestFailure ? error.kind :
    kinds.includes(error?.name) ? error.name : 'Error';
  const target = error instanceof RequestFailure ? error.operation : operation;
  const detail = target + ' · ' + kind +
    (error instanceof RequestFailure && error.status ? ' (HTTP ' + error.status + ')' : '');
  // Never log the error object, request URL/query, response data, or exception message.
  console.warn('Pick’em: ' + detail);
  byId('status').textContent = message + ' (' + detail + ')';
}

function readRows(value, operation) {
  if (!Array.isArray(value) || value.some(row => !row || typeof row !== 'object' || Array.isArray(row))) {
    throw new RequestFailure(operation, 'UnexpectedResponse');
  }
  return value;
}

function element(tag, text) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  return node;
}

function connection() {
  const url = byId('project').value.trim();
  const key = byId('publishable-key').value.trim();
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/.test(url) ||
      !/^sb_publishable_[A-Za-z0-9_-]+$/.test(key)) return null;
  return { url: url.replace(/\/$/, ''), key };
}

async function call(config, path, { token, body } = {}) {
  const headers = { apikey: config.key };
  if (token) headers.Authorization = 'Bearer ' + token;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const operation = path.split('?')[0];
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12_000);
  try {
    const response = await fetch(config.url + path, {
      method: body === undefined ? 'GET' : 'POST', headers,
      body: body === undefined ? undefined : JSON.stringify(body), redirect: 'error',
      cache: 'no-store', signal: controller.signal,
    });
    if (!response.ok) throw new RequestFailure(operation, 'HTTPError', response.status);
    if (response.status === 204) return null;
    try {
      return await response.json();
    } catch {
      throw new RequestFailure(operation, controller.signal.aborted ? 'Timeout' : 'InvalidJSON');
    }
  } catch (error) {
    if (error instanceof RequestFailure) throw error;
    throw new RequestFailure(operation, controller.signal.aborted ? 'Timeout' : 'NetworkError');
  } finally {
    clearTimeout(timeout);
  }
}

const rest = (path, body) => call(state.config, '/rest/v1/' + path, { token: state.token, body });
const restRows = async (path, body) => readRows(await rest(path, body), '/rest/v1/' + path.split('?')[0]);

function closeSession(message = '') {
  clearInterval(poll);
  clearInterval(timer);
  state.generation++;
  state.token = null;
  state.identity = null;
  state.data = null;
  state.demo = false;
  state.saving = false;
  byId('access').hidden = false;
  byId('board').hidden = true;
  byId('exit').hidden = true;
  byId('games').textContent = '';
  byId('results').textContent = '';
  byId('week').textContent = '';
  byId('participant-name').textContent = '';
  byId('pick-status').textContent = '';
  byId('status').textContent = message;
}

async function refresh() {
  const generation = state.generation;
  if (refreshingGeneration === generation) return;
  refreshingGeneration = generation;
  let operation = 'refresh-competition';
  try {
    if (Date.now() >= state.expiry) return closeSession('Session expired. Sign in again.');
    const [identity] = await restRows('rpc/pickem_identity', {});
    if (state.generation !== generation) return;
    if (!identity) return closeSession('This account does not have Pick’em access.');
    const serverTime = Date.parse(identity.server_time);
    if (typeof identity.participant_id !== 'string' || !Number.isFinite(serverTime)) {
      throw new RequestFailure('/rest/v1/rpc/pickem_identity', 'UnexpectedResponse');
    }
    state.identity = identity.participant_id;
    state.clockOffset = serverTime - Date.now();
    const [weeks, seasons, directory] = await Promise.all([
      restRows('weeks?select=id,season_id,week_number,status&status=neq.planned&order=week_number.desc'),
      restRows('seasons?select=id,nfl_year&order=nfl_year.desc'),
      restRows('participants?select=id,display_name'),
    ]);
    if (state.generation !== generation) return;
    // Hosted runs use a separate fixture season. Its rows are shown only in this private preview.
    state.weeks = weeks.sort((a, b) => b.season_id - a.season_id || b.week_number - a.week_number);
    state.seasons = seasons;
    state.names = new Map(directory.map(row => [row.id, row.display_name]));
    const name = state.names.get(state.identity);
    if (typeof name !== 'string' || !name.trim()) {
      throw new RequestFailure('/rest/v1/participants', 'UnexpectedResponse');
    }
    byId('participant-name').textContent = 'Signed in as ' + name;
    operation = 'set-week-options';
    setWeekOptions();
    await loadWeek();
  } catch (error) {
    if (state.generation !== generation) return;
    if (error.status === 401) return closeSession('Session expired. Sign in again.');
    if (error.status === 403) return closeSession('This account does not have Pick’em access.');
    reportFailure('Could not load competition data. Retrying shortly.', operation, error);
  } finally {
    if (refreshingGeneration === generation) refreshingGeneration = undefined;
  }
}

function setWeekOptions() {
  const select = byId('week');
  const current = select.value;
  const options = state.weeks.map(week => {
    const year = state.seasons.find(season => season.id === week.season_id)?.nfl_year;
    const option = element('option', year + ' · Week ' + week.week_number);
    option.value = String(week.id);
    return option;
  });
  select.textContent = '';
  for (const option of options) select.appendChild(option);
  if (state.weeks.some(week => String(week.id) === current)) select.value = current;
  select.disabled = !state.weeks.length;
}

async function loadWeek() {
  const generation = state.generation;
  const version = ++loadVersion;
  let operation = 'load-week';
  try {
    const week = state.weeks.find(item => String(item.id) === byId('week').value);
    if (!week || state.data?.week.id !== week.id) {
      state.data = null;
      operation = 'render-board';
      render();
      if (!week) {
        byId('status').textContent = '';
        return;
      }
      operation = 'load-week';
    }
    const [games, teams, picks, weekly, season, historyWeeks] = await Promise.all([
      restRows('games?select=id,home_team_id,away_team_id,kickoff_at,started_at,status,picks_locked_at,final_verified_at,cancellation_verified_at,home_score,away_score&week_id=eq.' + week.id + '&order=kickoff_at.asc.nullslast,id.asc'),
      restRows('teams?select=id,name'),
      restRows('picks?participant_id=eq.' + encodeURIComponent(state.identity) +
        '&games.week_id=eq.' + week.id + '&select=game_id,team_id,games!inner(week_id)'),
      restRows('weekly_results?select=week_id,participant_id,points,rank,weeks!inner(season_id,week_number)&weeks.season_id=eq.' + week.season_id + '&order=rank.asc'),
      restRows('season_standings?select=participant_id,points,rank&season_id=eq.' + week.season_id + '&order=rank.asc'),
      Promise.resolve(state.weeks.filter(item => item.season_id === week.season_id && item.status === 'complete')),
    ]);
    if (state.generation !== generation || version !== loadVersion) return;
    const finals = games.filter(game => game.status === 'final' && game.final_verified_at).map(game => game.id);
    const revealed = finals.length ? await restRows('picks?select=game_id,participant_id,team_id&game_id=in.(' +
      finals.join(',') + ')') : [];
    if (state.generation !== generation || version !== loadVersion) return;
    state.data = { week, games, teams: new Map(teams.map(team => [team.id, team.name])),
      picks: new Map(picks.map(pick => [pick.game_id, pick.team_id])), weekly, season, historyWeeks, revealed };
    operation = 'render-board';
    render();
    byId('status').textContent = '';
  } catch (error) {
    if (state.generation !== generation || version !== loadVersion) return;
    if (error.status === 401) return closeSession('Session expired. Sign in again.');
    if (error.status === 403) return closeSession('This account does not have Pick’em access.');
    reportFailure('Could not load this week. Retrying shortly.', operation, error);
  }
}

function locked(game, week) {
  return week.status !== 'active' || game.status !== 'scheduled' || game.started_at ||
    game.picks_locked_at || !game.kickoff_at || Date.now() + state.clockOffset >= Date.parse(game.kickoff_at);
}

function renderGames(data) {
  const destination = byId('games');
  for (const game of data.games) {
    const closed = locked(game, data.week);
    const card = element('article');
    card.className = 'game';
    const home = data.teams.get(game.home_team_id) ?? 'Home team';
    const away = data.teams.get(game.away_team_id) ?? 'Away team';
    card.append(element('h3', away + ' at ' + home));
    const time = element('time', game.kickoff_at ? pacific.format(new Date(game.kickoff_at)) : 'Kickoff to be confirmed');
    if (game.kickoff_at) time.dateTime = game.kickoff_at;
    const kickoff = element('p');
    kickoff.className = 'kickoff';
    kickoff.append(time);
    const choices = element('div');
    choices.className = 'choices';
    for (const id of [game.away_team_id, game.home_team_id]) {
      const choice = element('button', data.teams.get(id));
      choice.type = 'button';
      choice.className = 'choice';
      choice.disabled = Boolean(closed || state.saving);
      choice.setAttribute('aria-pressed', String(data.picks.get(game.id) === id));
      choice.addEventListener('click', () => savePick(game, id));
      choices.append(choice);
    }
    const message = game.final_verified_at ? 'Final · ' + away + ' ' + game.away_score + ', ' + home + ' ' + game.home_score :
      game.cancellation_verified_at ? 'Canceled' :
        closed ? 'Picks locked' : data.picks.has(game.id) ? 'Pick saved' : 'Choose a team';
    const status = element('p', message);
    status.className = 'game-status';
    card.append(kickoff, choices, status);
    if (game.status === 'final' && game.final_verified_at) {
      const list = element('ul');
      for (const pick of data.revealed.filter(pick => pick.game_id === game.id)) {
        if (pick.participant_id === state.identity) continue;
        const name = state.names.get(pick.participant_id) ?? 'Participant';
        list.append(element('li', name + ' · ' + (data.teams.get(pick.team_id) ?? 'Team')));
      }
      if (list.childElementCount) card.append(list);
    }
    destination.append(card);
  }
  byId('progress').textContent = data.games.filter(game => data.picks.has(game.id)).length +
    ' of ' + data.games.length + ' picks completed';
}

function renderResults(data) {
  const target = byId('results');
  const byWeek = id => data.weekly.filter(row => row.week_id === id);
  const previous = data.historyWeeks.find(week => week.week_number < data.week.week_number);
  if (state.section === 'history') {
    for (const week of data.historyWeeks) {
      const winners = byWeek(week.id).filter(row => row.rank === 1)
        .map(row => state.names.get(row.participant_id) ?? 'Participant');
      if (winners.length) target.append(element('p', 'Week ' + week.week_number + ' · ' + winners.join(', ')));
    }
  } else {
    const rows = state.section === 'weekly' ? byWeek(data.week.id) : data.season;
    if (rows.length) {
      const list = element('ol');
      list.className = 'result-list';
      const risers = [];
      const fallers = [];
      for (const row of rows) {
        const before = state.section === 'weekly' && previous &&
          byWeek(previous.id).find(item => item.participant_id === row.participant_id);
        const movement = before ? before.rank - row.rank : 0;
        const name = state.names.get(row.participant_id) ?? 'Participant';
        if (movement > 0) risers.push(name);
        if (movement < 0) fallers.push(name);
        const change = movement ? ' · ' + (movement > 0 ? 'Up ' : 'Down ') + Math.abs(movement) : '';
        list.append(element('li', '#' + row.rank + ' · ' + name +
          ' · ' + row.points + (row.points === 1 ? ' point' : ' points') + change));
      }
      target.append(list);
      if (risers.length) target.append(element('p', 'Risers · ' + risers.join(', ')));
      if (fallers.length) target.append(element('p', 'Fallers · ' + fallers.join(', ')));
    }
  }
  if (!target.childElementCount) target.append(element('p', 'Results appear after a full week is verified.'));
}

function render() {
  if (state.saving) return;
  const data = state.data;
  byId('board-title').textContent = titles[state.section];
  byId('progress').textContent = '';
  byId('games').textContent = '';
  byId('results').textContent = '';
  if (!data) {
    byId('results').append(element('p', state.weeks.length ? 'Loading week…' : 'No competition weeks are available.'));
    return;
  }
  if (state.section === 'picks') renderGames(data);
  else renderResults(data);
}

function renderSafely() {
  try {
    render();
  } catch (error) {
    reportFailure('Could not display the competition.', 'render-board', error);
  }
}

async function savePick(game, team) {
  const data = state.data;
  const generation = state.generation;
  if (state.saving || locked(game, data.week)) return;
  state.saving = true;
  loadVersion++;
  byId('games').querySelectorAll('button').forEach(button => { button.disabled = true; });
  byId('pick-status').textContent = 'Saving pick…';
  try {
    if (!state.demo) await rest('rpc/submit_pick', { p_game_id: game.id, p_team_id: team });
    if (state.generation !== generation) return;
    loadVersion++;
    data.picks.set(game.id, team);
    if (state.data?.week.id === data.week.id) state.data.picks.set(game.id, team);
    else if (byId('week').value !== String(data.week.id)) void loadWeek();
    byId('pick-status').textContent = state.demo ? 'Sample pick saved for this preview.' : 'Pick saved.';
  } catch (error) {
    if (state.generation !== generation) return;
    if (error.status === 401 || error.status === 403) return closeSession('Sign in again to verify your Pick’em access.');
    byId('pick-status').textContent = error.status === 400 ?
      'Pick rejected. The game may now be locked.' : 'Could not confirm the save. Refresh before trying again.';
    void loadWeek();
  } finally {
    if (state.generation === generation) {
      state.saving = false;
      renderSafely();
    }
  }
}

function openBoard() {
  byId('access').hidden = true;
  byId('board').hidden = false;
  byId('exit').hidden = false;
  byId('exit').textContent = state.demo ? 'Exit sample' : 'Sign out';
  state.section = 'picks';
  buttons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.section === 'picks')));
  byId('board-title').focus();
}

byId('project').value = supabaseUrl;
byId('publishable-key').value = supabasePublishableKey;
byId('connection').open = !connection();
byId('sign-in').addEventListener('submit', async event => {
  event.preventDefault();
  const config = connection();
  if (!config) {
    byId('connection').open = true;
    byId('status').textContent = 'Enter a Supabase project URL and an sb_publishable_ key.';
    return;
  }
  const form = event.currentTarget;
  const submit = form.querySelector('button');
  submit.disabled = byId('demo').disabled = true;
  byId('status').textContent = 'Signing in…';
  try {
    const session = await call(config, '/auth/v1/token?grant_type=password', { body: {
      email: byId('email').value.trim(), password: byId('password').value,
    } });
    if (!session.access_token || !Number.isFinite(session.expires_in)) throw new Error('Session unavailable');
    state.config = config;
    state.token = session.access_token;
    state.expiry = Date.now() + session.expires_in * 1000;
    state.weeks = [];
    openBoard();
    byId('status').textContent = 'Loading competition…';
    await refresh();
    if (state.token) {
      poll = setInterval(refresh, 30_000);
      timer = setInterval(() => {
        if (Date.now() >= state.expiry) closeSession('Session expired. Sign in again.');
        else if (state.section === 'picks' && state.data && !state.saving) {
          const cards = [...byId('games').children];
          if (state.data.games.some((game, i) => locked(game, state.data.week) &&
            cards[i]?.querySelector('button:not(:disabled)'))) renderSafely();
        }
      }, 1000);
    }
  } catch (error) {
    closeSession(error.status === 400 || error.status === 401 ?
      'Check your email and password.' : 'Sign-in is unavailable. Try again shortly.');
  } finally {
    byId('password').value = '';
    submit.disabled = byId('demo').disabled = false;
  }
});

byId('exit').addEventListener('click', async () => {
  const { config, token } = state;
  closeSession();
  if (token) {
    try { await call(config, '/auth/v1/logout?scope=local', { token, body: {} }); }
    catch { if (!state.token && !state.demo) byId('status').textContent = 'Local session cleared. Server logout could not be confirmed.'; }
  }
});

byId('week').addEventListener('change', () => { if (!state.demo) void loadWeek(); });
for (const button of buttons) button.addEventListener('click', () => {
  state.section = button.dataset.section;
  buttons.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  byId('pick-status').textContent = '';
  renderSafely();
});

byId('demo').addEventListener('click', () => {
  state.demo = true;
  state.clockOffset = 0;
  const week = { id: 1, season_id: 1, week_number: 1, status: 'active' };
  state.weeks = [week];
  state.seasons = [{ id: 1, nfl_year: 2099 }];
  state.data = { week, teams: new Map([[1, 'Cascade Foxes'], [2, 'Harbor Owls'], [3, 'Mesa Runners']]),
    games: [
      { id: 1, home_team_id: 1, away_team_id: 2, kickoff_at: '2099-09-13T17:00:00Z', status: 'scheduled' },
      { id: 2, home_team_id: 2, away_team_id: 3, kickoff_at: '2099-09-13T20:25:00Z', status: 'scheduled', picks_locked_at: true },
    ], picks: new Map(), weekly: [], season: [], historyWeeks: [], revealed: [] };
  byId('status').textContent = 'Sample matchups and teams';
  openBoard();
  setWeekOptions();
  renderSafely();
});
