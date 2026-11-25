alter table public.weeks add column competition_phase text not null default 'regular';
alter table public.weeks drop constraint weeks_week_number_check, drop constraint weeks_season_id_week_number_key;
alter table public.weeks
  add constraint weeks_competition_period_check check (
    (competition_phase = 'regular' and week_number between 1 and 18)
    or (competition_phase = 'postseason' and week_number in (1, 2, 3, 5))
  ),
  add constraint weeks_season_phase_number_key unique (season_id, competition_phase, week_number);

alter table public.teams add column balldontlie_id bigint unique check (balldontlie_id > 0);
alter table public.games
  add column provider_updated_at timestamptz,
  add column reference_game_id text,
  add column schedule_verified_until timestamptz;
create unique index games_balldontlie_reference_key on public.games(reference_game_id)
  where source = 'balldontlie' and reference_game_id is not null;

revoke truncate, trigger, references on public.participants, public.seasons, public.weeks,
  public.teams, public.games, public.picks, public.weekly_results, public.season_standings,
  public.email_log, public.job_runs, public.audit_log from service_role;

create or replace function public.submit_pick(p_game_id bigint, p_team_id bigint)
returns public.picks
language plpgsql security definer set search_path = ''
as $$
declare
  participant uuid;
  game public.games;
  week_status text;
  saved public.picks;
  checked_at timestamptz;
begin
  select id into participant from public.participants
  where auth_user_id = auth.uid() and active for share;
  if participant is null then
    raise exception 'Active participant required' using errcode = '42501';
  end if;

  select * into game from public.games where id = p_game_id for update;
  select status into week_status from public.weeks where id = game.week_id for share;
  checked_at := clock_timestamp();
  if week_status is distinct from 'active'
     or game.status is distinct from 'scheduled'
     or game.started_at is not null
     or game.picks_locked_at is not null
     or game.kickoff_at is null
     or checked_at >= game.kickoff_at
     or (game.source = 'balldontlie' and (game.schedule_verified_until is null
       or checked_at >= game.schedule_verified_until)) then
    raise exception 'Game is closed for picks' using errcode = '22023';
  end if;
  if p_team_id is null or p_team_id not in (game.home_team_id, game.away_team_id) then
    raise exception 'Select a team playing in this game' using errcode = '22023';
  end if;
  insert into public.picks (participant_id, game_id, team_id, updated_at)
  values (participant, p_game_id, p_team_id, checked_at)
  on conflict (participant_id, game_id) do update
    set team_id = excluded.team_id, updated_at = excluded.updated_at
  returning * into saved;
  return saved;
end;
$$;
