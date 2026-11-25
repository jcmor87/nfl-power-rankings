alter table public.games
  add column reference_kickoff_at timestamptz,
  add column pick_deadline_at timestamptz generated always as (least(kickoff_at, reference_kickoff_at)) stored,
  add column kickoff_reconciliation text generated always as (
    case when reference_kickoff_at is null then null
      when kickoff_at = reference_kickoff_at then 'exact'
      else 'earlier_deadline' end
  ) stored,
  add constraint games_kickoff_evidence_tolerance check (
    reference_kickoff_at is null or (kickoff_at is not null and
      abs(extract(epoch from kickoff_at - reference_kickoff_at)) <= 900)
  );

-- Existing source timestamps are retained. Automated picks require fresh, paired evidence.
update public.games set schedule_verified_until = null
where source = 'balldontlie' and status = 'scheduled';

create or replace function pickem_private.guard_game_lifecycle()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  checked_at timestamptz := clock_timestamp();
  new_deadline timestamptz := least(new.kickoff_at, new.reference_kickoff_at);
begin
  if tg_op = 'UPDATE' then
    new.started_at := coalesce(old.started_at, new.started_at);
    new.picks_locked_at := coalesce(old.picks_locked_at,
      case
        when old.started_at is not null then checked_at
        when old.pick_deadline_at <= checked_at then old.pick_deadline_at
        when old.status in ('in_progress', 'suspended', 'final', 'canceled') then checked_at
      end,
      new.picks_locked_at);
  end if;
  if new.picks_locked_at is null and (
    new.started_at is not null or new_deadline <= checked_at
    or new.status in ('in_progress', 'suspended', 'final', 'canceled')
  ) then
    new.picks_locked_at := least(checked_at, new_deadline);
  end if;
  return new;
end;
$$;

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
     or checked_at >= game.pick_deadline_at
     or (game.source = 'balldontlie' and (game.reference_kickoff_at is null or game.schedule_verified_until is null
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

create or replace function public.sync_pickem_nfl_week(p_snapshot jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  year_number integer := (p_snapshot->>'season')::integer;
  phase text := p_snapshot->>'phase';
  round_number integer := (p_snapshot->>'week')::integer;
  game_count integer := jsonb_array_length(p_snapshot->'games');
  checked_at timestamptz := clock_timestamp();
  season_key bigint;
  target_week public.weeks;
  old_game public.games;
  saved_game public.games;
  team_row record;
  game_row record;
  home_id bigint;
  away_id bigint;
  changes boolean := false;
  old_values jsonb;
  new_values jsonb;
begin
  if jsonb_typeof(p_snapshot->'teams') is distinct from 'array'
    or jsonb_array_length(p_snapshot->'teams') is distinct from 32
    or game_count is null or game_count not between 1 and 16
    or year_number is null or year_number not between 2026 and 9999
    or round_number is null or not coalesce(
      (phase = 'regular' and round_number between 1 and 18)
      or (phase = 'postseason' and game_count = case round_number when 1 then 6 when 2 then 4
          when 3 then 2 when 5 then 1 end), false
    ) then raise exception 'Invalid snapshot coverage'; end if;

  if (select count(distinct code) from jsonb_to_recordset(p_snapshot->'teams') as t(code text)) <> 32
    or (select count(distinct "providerId") from jsonb_to_recordset(p_snapshot->'teams') as t("providerId" bigint)) <> 32
    or exists (
      select 1 from jsonb_to_recordset(p_snapshot->'teams') as t(code text, name text, "providerId" bigint)
      where (code = any(string_to_array('ARI ATL BAL BUF CAR CHI CIN CLE DAL DEN DET GB HOU IND JAX KC LA LAC LV MIA MIN NE NO NYG NYJ PHI PIT SEA SF TB TEN WAS', ' ')))
        is distinct from true or nullif(btrim(name), '') is null or "providerId" <= 0
    ) then raise exception 'Invalid team directory'; end if;
  if (select count(distinct provider_id) from jsonb_to_recordset(p_snapshot->'games') as g(provider_id text)) <> game_count
    or (select count(distinct reference_id) from jsonb_to_recordset(p_snapshot->'games') as g(reference_id text)) <> game_count
    or (select count(distinct code) from jsonb_to_recordset(p_snapshot->'games') as g(home text, away text)
      cross join lateral (values (g.home), (g.away)) sides(code)) <> game_count * 2
    then raise exception 'Duplicate or missing matchup identities'; end if;

  perform pg_advisory_xact_lock(20261125, 400);
  insert into public.seasons (nfl_year) values (year_number) on conflict (nfl_year) do nothing;
  select id into season_key from public.seasons where nfl_year = year_number for no key update;

  for team_row in select * from jsonb_to_recordset(p_snapshot->'teams') as t(code text, name text, "providerId" bigint)
  loop
    insert into public.teams (abbreviation, name, balldontlie_id)
    values (team_row.code, team_row.name, team_row."providerId")
    on conflict (abbreviation) do update set name = excluded.name, balldontlie_id = excluded.balldontlie_id
      where public.teams.balldontlie_id is null or public.teams.balldontlie_id = excluded.balldontlie_id;
    if not found then raise exception 'Provider team identity changed'; end if;
  end loop;

  insert into public.weeks (season_id, competition_phase, week_number, expected_games)
  values (season_key, phase, round_number, game_count)
  on conflict (season_id, competition_phase, week_number) do nothing;
  select * into target_week from public.weeks
  where season_id = season_key and competition_phase = phase and week_number = round_number;

  -- Match scoring and pick submission's game-before-week ordering.
  perform 1 from public.games where week_id = target_week.id order by id for update;
  select * into target_week from public.weeks where id = target_week.id for update;
  if target_week.expected_games is not null and target_week.expected_games <> game_count then
    raise exception 'Snapshot changes the expected matchup count';
  end if;
  update public.weeks set expected_games = game_count where id = target_week.id and expected_games is null;
  if exists (
    select 1 from public.games g where g.week_id = target_week.id and (
      g.source <> 'balldontlie' or not exists (
        select 1 from jsonb_to_recordset(p_snapshot->'games') as n(provider_id text)
        where n.provider_id = g.source_game_id
      )
    )
  ) then raise exception 'Snapshot omits or remaps an existing game'; end if;

  for game_row in select * from jsonb_to_recordset(p_snapshot->'games') as g(
    provider_id text, reference_id text, home text, away text, status text, kickoff_at timestamptz,
    reference_kickoff_at timestamptz, observed_at timestamptz, home_score smallint, away_score smallint)
  loop
    if game_row.provider_id !~ '^[1-9][0-9]*$' or nullif(btrim(game_row.reference_id), '') is null
      or game_row.observed_at is null or game_row.observed_at > checked_at + interval '5 minutes'
      or game_row.status is null or game_row.status not in
        ('scheduled', 'in_progress', 'postponed', 'suspended', 'final', 'canceled')
      or game_row.kickoff_at is null or game_row.reference_kickoff_at is null
      or abs(extract(epoch from game_row.kickoff_at - game_row.reference_kickoff_at)) > 900
      or (game_row.status = 'final' and (game_row.kickoff_at > checked_at
          or game_row.home_score is null or game_row.away_score is null
          or game_row.home_score < 0 or game_row.away_score < 0))
      or (game_row.status <> 'final' and (game_row.home_score is not null or game_row.away_score is not null))
      then raise exception 'Invalid game evidence'; end if;

    select id into strict home_id from public.teams where abbreviation = game_row.home;
    select id into strict away_id from public.teams where abbreviation = game_row.away;
    select * into old_game from public.games where source = 'balldontlie' and source_game_id = game_row.provider_id;
    if found and (
      old_game.week_id <> target_week.id or old_game.home_team_id <> home_id or old_game.away_team_id <> away_id
      or (old_game.reference_game_id is not null and old_game.reference_game_id <> game_row.reference_id)
      or (old_game.provider_updated_at is not null and game_row.observed_at < old_game.provider_updated_at)
      or (old_game.status in ('final', 'canceled') and old_game.status <> game_row.status)
    ) then raise exception 'Stale observation or game identity conflict'; end if;

    old_values := jsonb_build_object('status', old_game.status, 'kickoff_at', old_game.kickoff_at,
      'home_score', old_game.home_score, 'away_score', old_game.away_score);
    new_values := jsonb_build_object('status', game_row.status,
      'kickoff_at', game_row.kickoff_at,
      'home_score', game_row.home_score, 'away_score', game_row.away_score);
    if old_game.provider_updated_at = game_row.observed_at and old_values is distinct from new_values then
      raise exception 'Changed game evidence has no newer provider timestamp';
    end if;

    -- Track reference-only updates without requiring the primary provider's timestamp to advance.
    old_values := old_values || jsonb_build_object('reference_kickoff_at', old_game.reference_kickoff_at,
      'pick_deadline_at', old_game.pick_deadline_at, 'kickoff_reconciliation', old_game.kickoff_reconciliation);
    new_values := new_values || jsonb_build_object('reference_kickoff_at', game_row.reference_kickoff_at,
      'pick_deadline_at', least(game_row.kickoff_at, game_row.reference_kickoff_at),
      'kickoff_reconciliation', case when game_row.kickoff_at = game_row.reference_kickoff_at
        then 'exact' else 'earlier_deadline' end);

    insert into public.games (week_id, home_team_id, away_team_id, source, source_game_id, reference_game_id,
      kickoff_at, reference_kickoff_at, started_at, status, home_score, away_score, provider_updated_at, schedule_verified_until,
      final_verified_at, cancellation_verified_at)
    values (target_week.id, home_id, away_id, 'balldontlie', game_row.provider_id, game_row.reference_id,
      game_row.kickoff_at, game_row.reference_kickoff_at,
      case when game_row.status in ('in_progress', 'suspended', 'final') then
        coalesce(old_game.started_at, game_row.kickoff_at, checked_at) end,
      game_row.status, game_row.home_score, game_row.away_score, game_row.observed_at,
      case when game_row.status = 'scheduled' then checked_at + interval '3 hours' end,
      case when game_row.status = 'final' then
        case when old_values is not distinct from new_values then coalesce(old_game.final_verified_at, checked_at)
             else checked_at end end,
      case when game_row.status = 'canceled' then coalesce(old_game.cancellation_verified_at, checked_at) end)
    on conflict (source, source_game_id) do update set reference_game_id = excluded.reference_game_id,
      kickoff_at = excluded.kickoff_at, reference_kickoff_at = excluded.reference_kickoff_at, started_at = excluded.started_at, status = excluded.status,
      home_score = excluded.home_score, away_score = excluded.away_score,
      provider_updated_at = excluded.provider_updated_at, schedule_verified_until = excluded.schedule_verified_until,
      final_verified_at = excluded.final_verified_at, cancellation_verified_at = excluded.cancellation_verified_at
    returning * into saved_game;

    if old_values is distinct from new_values or old_game.final_verified_at is distinct from saved_game.final_verified_at
        or old_game.cancellation_verified_at is distinct from saved_game.cancellation_verified_at then
      changes := true;
      insert into public.audit_log (action, details) values (
        case when old_game.status = 'final' and game_row.status = 'final'
          and (old_game.home_score,old_game.away_score) is distinct from (game_row.home_score,game_row.away_score)
             then 'nfl_score_correction'
             when game_row.status = 'canceled' then 'nfl_cancellation'
             else 'nfl_game_update' end,
        jsonb_build_object('game_id',saved_game.id, 'before',old_values, 'after',new_values,
          'provider_id',game_row.provider_id,'reference_id',game_row.reference_id,'observed_at',game_row.observed_at)
      );
    end if;
  end loop;

  if (target_week.status = 'active' or (target_week.status = 'complete' and changes))
    and not exists (select 1 from public.games where week_id = target_week.id and not (
      (status = 'final' and final_verified_at is not null)
      or (status = 'canceled' and cancellation_verified_at is not null)
    )) then perform public.recalculate_pickem_week(target_week.id); end if;
  insert into public.job_runs (job_name, status, finished_at)
    values ('nfl_sync', 'succeeded', clock_timestamp());
end;
$$;
