alter table public.games
  add column picks_locked_at timestamptz,
  add column cancellation_verified_at timestamptz,
  add constraint verified_cancellation_has_canceled_status
    check (cancellation_verified_at is null or status = 'canceled');

create function pickem_private.guard_game_lifecycle()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  checked_at timestamptz := clock_timestamp();
begin
  if tg_op = 'UPDATE' then
    new.started_at := coalesce(old.started_at, new.started_at);
    new.picks_locked_at := coalesce(old.picks_locked_at,
      case
        when old.started_at is not null then checked_at
        when old.kickoff_at <= checked_at then old.kickoff_at
        when old.status in ('in_progress', 'suspended', 'final', 'canceled') then checked_at
      end,
      new.picks_locked_at);
  end if;
  if new.picks_locked_at is null and (
    new.started_at is not null or new.kickoff_at <= checked_at
    or new.status in ('in_progress', 'suspended', 'final', 'canceled')
  ) then
    new.picks_locked_at := least(checked_at, new.kickoff_at);
  end if;
  return new;
end;
$$;
revoke all on function pickem_private.guard_game_lifecycle() from public, anon, authenticated;

create trigger guard_game_lifecycle
before insert or update on public.games
for each row execute function pickem_private.guard_game_lifecycle();

-- Backfill games the previous schema already treated as locked.
update public.games set picks_locked_at = least(clock_timestamp(), kickoff_at)
where started_at is not null or kickoff_at <= clock_timestamp()
  or status in ('in_progress', 'suspended', 'final', 'canceled');

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

create function public.pickem_identity()
returns table (participant_id uuid, server_time timestamptz)
language sql stable security definer set search_path = ''
as $$
  select p.id, statement_timestamp()
  from public.participants p where p.auth_user_id = auth.uid() and p.active
$$;
revoke all on function public.pickem_identity() from public, anon, authenticated;
grant execute on function public.pickem_identity() to authenticated;
