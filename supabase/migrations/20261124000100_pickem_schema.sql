create table public.participants (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete restrict,
  display_name text not null check (length(btrim(display_name)) between 1 and 60),
  seat smallint not null unique check (seat between 1 and 5),
  active boolean not null default false,
  check (not active or auth_user_id is not null)
);

create table public.seasons (
  id bigint generated always as identity primary key,
  nfl_year integer not null unique check (nfl_year >= 2026)
);

create table public.weeks (
  id bigint generated always as identity primary key,
  season_id bigint not null references public.seasons(id),
  week_number smallint not null check (week_number between 1 and 18),
  status text not null default 'planned' check (status in ('planned', 'active', 'complete')),
  expected_games smallint check (expected_games between 1 and 16),
  check (status = 'planned' or expected_games is not null),
  unique (season_id, week_number)
);

create table public.teams (
  id bigint generated always as identity primary key,
  abbreviation text not null unique,
  name text not null
);

create table public.games (
  id bigint generated always as identity primary key,
  week_id bigint not null references public.weeks(id),
  home_team_id bigint not null references public.teams(id),
  away_team_id bigint not null references public.teams(id),
  source text not null,
  source_game_id text not null,
  kickoff_at timestamptz,
  started_at timestamptz,
  status text not null default 'unknown'
    check (status in ('unknown', 'scheduled', 'in_progress', 'postponed', 'suspended', 'final', 'canceled')),
  home_score smallint check (home_score >= 0),
  away_score smallint check (away_score >= 0),
  final_verified_at timestamptz,
  unique (source, source_game_id),
  unique (week_id, home_team_id, away_team_id),
  check (home_team_id <> away_team_id),
  check ((home_score is null) = (away_score is null)),
  check (status <> 'final' or home_score is not null),
  check (final_verified_at is null or (status = 'final' and started_at is not null))
);

create table public.picks (
  participant_id uuid not null references public.participants(id),
  game_id bigint not null references public.games(id),
  team_id bigint not null references public.teams(id),
  updated_at timestamptz not null,
  primary key (participant_id, game_id)
);
create index picks_game_id_idx on public.picks(game_id);

create table public.weekly_results (
  week_id bigint not null references public.weeks(id),
  participant_id uuid not null references public.participants(id),
  points integer not null check (points >= 0),
  eligible_games integer not null check (eligible_games >= points),
  rank integer not null check (rank >= 1),
  calculated_at timestamptz not null default now(),
  primary key (week_id, participant_id)
);

create table public.season_standings (
  season_id bigint not null references public.seasons(id),
  participant_id uuid not null references public.participants(id),
  points integer not null check (points >= 0),
  eligible_games integer not null check (eligible_games >= points),
  rank integer not null check (rank >= 1),
  calculated_at timestamptz not null default now(),
  primary key (season_id, participant_id)
);

create table public.email_log (
  id bigint generated always as identity primary key,
  week_id bigint not null references public.weeks(id),
  participant_id uuid not null references public.participants(id),
  kind text not null check (kind in ('reminder', 'results')),
  status text not null check (status in ('claimed', 'accepted', 'failed', 'ambiguous')),
  provider_message_id text,
  updated_at timestamptz not null default now(),
  unique (week_id, participant_id, kind)
);

create table public.job_runs (
  id bigint generated always as identity primary key,
  job_name text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null check (status in ('running', 'succeeded', 'failed'))
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_participant_id uuid references public.participants(id),
  action text not null,
  occurred_at timestamptz not null default now(),
  details jsonb not null default '{}'
);
