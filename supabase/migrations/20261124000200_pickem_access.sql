alter table public.participants enable row level security;
alter table public.seasons enable row level security;
alter table public.weeks enable row level security;
alter table public.teams enable row level security;
alter table public.games enable row level security;
alter table public.picks enable row level security;
alter table public.weekly_results enable row level security;
alter table public.season_standings enable row level security;
alter table public.email_log enable row level security;
alter table public.job_runs enable row level security;
alter table public.audit_log enable row level security;

revoke all on public.participants, public.seasons, public.weeks, public.teams,
  public.games, public.picks, public.weekly_results, public.season_standings,
  public.email_log, public.job_runs, public.audit_log from public, anon, authenticated;

create schema pickem_private;
revoke all on schema pickem_private from public;
grant usage on schema pickem_private to authenticated;

create function pickem_private.active_participant_id()
returns uuid
language sql stable security definer set search_path = ''
as $$
  select id from public.participants where auth_user_id = auth.uid() and active
$$;
revoke all on function pickem_private.active_participant_id() from public, anon, authenticated;
grant execute on function pickem_private.active_participant_id() to authenticated;

grant select (id, display_name) on public.participants to authenticated;
grant select on public.seasons, public.weeks, public.teams, public.games, public.picks to authenticated;

create policy participants_read on public.participants for select to authenticated
  using ((select pickem_private.active_participant_id()) is not null);
create policy seasons_read on public.seasons for select to authenticated
  using ((select pickem_private.active_participant_id()) is not null);
create policy weeks_read on public.weeks for select to authenticated
  using ((select pickem_private.active_participant_id()) is not null);
create policy teams_read on public.teams for select to authenticated
  using ((select pickem_private.active_participant_id()) is not null);
create policy games_read on public.games for select to authenticated
  using ((select pickem_private.active_participant_id()) is not null);
create policy picks_read on public.picks for select to authenticated
  using (
    (select pickem_private.active_participant_id()) is not null
    and (
      participant_id = (select pickem_private.active_participant_id())
      or exists (
        select 1 from public.games
        where id = game_id and status = 'final' and final_verified_at is not null
      )
    )
  );

create function public.submit_pick(p_game_id bigint, p_team_id bigint)
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

  -- Serialize competing submissions and game updates before checking the clock.
  select * into game from public.games where id = p_game_id for update;
  select status into week_status from public.weeks where id = game.week_id for share;
  checked_at := clock_timestamp();

  if week_status is distinct from 'active'
     or game.status is distinct from 'scheduled'
     or game.started_at is not null
     or game.kickoff_at is null
     or checked_at >= game.kickoff_at then
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
revoke all on function public.submit_pick(bigint, bigint) from public, anon, authenticated;
grant execute on function public.submit_pick(bigint, bigint) to authenticated;

grant select, insert, update, delete on public.participants, public.seasons, public.weeks,
  public.teams, public.games, public.picks, public.weekly_results, public.season_standings,
  public.email_log, public.job_runs, public.audit_log to service_role;
grant usage, select on sequence public.seasons_id_seq, public.weeks_id_seq, public.teams_id_seq,
  public.games_id_seq, public.email_log_id_seq, public.job_runs_id_seq,
  public.audit_log_id_seq to service_role;
