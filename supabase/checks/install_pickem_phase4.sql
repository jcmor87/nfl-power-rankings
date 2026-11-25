-- Run this entire script as postgres in one Supabase SQL Editor query.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '45s';
set local search_path = pg_catalog, public;
select pg_advisory_xact_lock(20261124, 100);

do $history$
begin
  if to_regclass('supabase_migrations.schema_migrations') is null then
    raise exception 'Missing baseline migration ledger';
  end if;
  if exists (select 1 from supabase_migrations.schema_migrations
    where version in ('20261125000400','20261125000500')) then
    raise exception 'Phase 4 migration already recorded';
  end if;
end;
$history$;

do $baseline$
declare failed text;
begin
  select string_agg(check_name, ', ' order by check_name) into failed from (
    with expected_tables(name, participant_access) as (
      values ('participants', 'directory'), ('seasons', 'read'), ('weeks', 'read'),
        ('teams', 'read'), ('games', 'read'), ('picks', 'read'),
        ('weekly_results', 'read'), ('season_standings', 'read'), ('email_log', 'none'),
        ('job_runs', 'none'), ('audit_log', 'none')
    ), tables as (
      select e.*, c.oid, c.relrowsecurity, c.relowner
      from expected_tables e
      left join pg_class c on c.oid = to_regclass('public.' || e.name) and c.relkind = 'r'
    ), expected_functions(signature, source_hash, is_definer, participant_exec, service_exec, defaults) as (
      values
        ('pickem_private.active_participant_id()', 'fe2c6a6d427ba3aab96593e7755f3409', true, true, false, 0),
        ('public.submit_pick(bigint,bigint)', 'cd58ae42fba0498f8bd2ababab12b165', true, true, false, 0),
        ('pickem_private.guard_game_lifecycle()', '6bd99b754523fe99cfcf9a7e155c02ab', false, false, false, 0),
        ('public.pickem_identity()', 'd0b3ba76649d831a5131200cb57c618a', true, true, false, 0),
        ('public.recalculate_pickem_week(bigint)', '311c078f4833105df507383af0c394f0', true, false, true, 0),
        ('public.claim_pickem_email(bigint,uuid,text)', 'fa83953eeb70b46eac5f97fe3c5306d8', true, false, true, 0),
        ('public.finish_pickem_email(uuid,text,text)', 'a476df2838f3d8c503720f51034fc5e6', true, false, true, 1)
    ), checks as (
      select 'Table and RLS · ' || name as check_name,
        oid is not null and coalesce(relrowsecurity, false) as passed
      from tables
      union all
      select 'Policy · ' || t.name, coalesce((
        select case when t.participant_access = 'none' then count(*) = 0
          else count(*) = 1 and bool_and(
            p.policyname = t.name || '_read' and p.cmd = 'SELECT'
            and p.roles = array['authenticated']::name[] and p.permissive = 'PERMISSIVE'
            and p.with_check is null
            and regexp_replace(replace(p.qual, 'public.games', 'games'), '[[:space:]]', '', 'g')
              = case when t.name = 'picks' then
                '(((SELECTpickem_private.active_participant_id()ASactive_participant_id)ISNOTNULL)AND((participant_id=(SELECTpickem_private.active_participant_id()ASactive_participant_id))OR(EXISTS(SELECT1FROMgamesWHERE((games.id=picks.game_id)AND(games.status=''final''::text)AND(games.final_verified_atISNOTNULL))))))'
                else '((SELECTpickem_private.active_participant_id()ASactive_participant_id)ISNOTNULL)' end
          ) end
        from pg_policies p where p.schemaname = 'public' and p.tablename = t.name
      ), false)
      from tables t
      union all
      select 'Table grants · ' || t.name, coalesce(
        not has_any_column_privilege('anon', oid, 'SELECT,INSERT,UPDATE,REFERENCES')
        and not has_table_privilege('anon', oid, 'DELETE,TRUNCATE,TRIGGER')
        and not has_any_column_privilege('authenticated', oid, 'INSERT,UPDATE,REFERENCES')
        and not has_table_privilege('authenticated', oid, 'DELETE,TRUNCATE,TRIGGER')
        and case participant_access
          when 'read' then has_table_privilege('authenticated', oid, 'SELECT')
          when 'none' then not has_any_column_privilege('authenticated', oid, 'SELECT')
          else not has_table_privilege('authenticated', oid, 'SELECT')
            and (select array_agg(a.attname::text order by a.attname)
                 from pg_attribute a where a.attrelid = t.oid and a.attnum > 0
                   and not a.attisdropped
                   and has_column_privilege('authenticated', t.oid, a.attnum, 'SELECT'))
                = array['display_name','id']
        end
        and has_table_privilege('service_role', oid, 'SELECT')
        and has_table_privilege('service_role', oid, 'INSERT')
        and has_table_privilege('service_role', oid, 'UPDATE')
        and has_table_privilege('service_role', oid, 'DELETE'), false)
      from tables t
      union all
      select 'Function and execution grants · ' || f.signature,
        coalesce(md5(p.prosrc) = f.source_hash and p.prosecdef = f.is_definer
          and p.proowner = (select relowner from tables where name = 'picks')
          and 'search_path=""' = any(p.proconfig) and p.pronargdefaults = f.defaults
          and not has_function_privilege('anon', p.oid, 'EXECUTE')
          and has_function_privilege('authenticated', p.oid, 'EXECUTE') = f.participant_exec
          and (not f.service_exec or has_function_privilege('service_role', p.oid, 'EXECUTE')), false)
      from expected_functions f
      left join pg_proc p on p.oid = to_regprocedure(f.signature)
      union all
      select 'Private schema usage',
        coalesce(has_schema_privilege('authenticated', to_regnamespace('pickem_private'), 'USAGE')
          and not has_schema_privilege('anon', to_regnamespace('pickem_private'), 'USAGE'), false)
      union all
      select 'Pick’em tables excluded from Realtime',
        not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
          and schemaname = 'public' and tablename in (select name from expected_tables))
      union all
      select 'Column · ' || e.table_name || '.' || e.column_name, exists (
        select 1 from pg_attribute a
        left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
        where a.attrelid = to_regclass('public.' || e.table_name) and a.attname = e.column_name
          and a.attnum > 0 and not a.attisdropped and a.atttypid = e.column_type::regtype
          and a.attnotnull = e.required
          and case when e.required then pg_get_expr(d.adbin, d.adrelid) in ('0', '0::smallint', '''0''::smallint')
              else d.oid is null end
      )
      from (values ('games','picks_locked_at','timestamptz',false),
        ('games','cancellation_verified_at','timestamptz',false), ('email_log','claim_token','uuid',false),
        ('email_log','attempts','smallint',true)) e(table_name,column_name,column_type,required)
      union all
      select 'Constraint · ' || e.constraint_name, exists (
        select 1 from pg_constraint c
        where c.conrelid = to_regclass('public.' || e.table_name) and c.conname = e.constraint_name
          and c.contype = 'c' and c.convalidated
          and regexp_replace(pg_get_expr(c.conbin,c.conrelid), '[[:space:]()]', '', 'g') = e.expression
      )
      from (values ('games','verified_cancellation_has_canceled_status',
          'cancellation_verified_atISNULLORstatus=''canceled''::text'),
        ('email_log','email_log_attempts_check','attempts>=0ANDattempts<=3'))
        e(table_name,constraint_name,expression)
      union all
      select 'Index · email_log_claim_token_idx', exists (
        select 1 from pg_index i
        join pg_class idx on idx.oid = i.indexrelid
        join pg_am am on am.oid = idx.relam
        join pg_attribute a on a.attrelid = i.indrelid and a.attname = 'claim_token' and not a.attisdropped
        where i.indexrelid = to_regclass('public.email_log_claim_token_idx')
          and i.indrelid = to_regclass('public.email_log') and am.amname = 'btree'
          and i.indisunique and i.indisvalid and i.indisready
          and i.indnkeyatts = 1 and i.indnatts = 1 and i.indkey[0] = a.attnum
          and i.indexprs is null and pg_get_expr(i.indpred,i.indrelid) = '(claim_token IS NOT NULL)'
      )
      union all
      select 'Trigger · guard_game_lifecycle', exists (
        select 1 from pg_trigger t where t.tgrelid = to_regclass('public.games')
          and t.tgname = 'guard_game_lifecycle' and not t.tgisinternal and t.tgenabled = 'O'
          -- ROW (1) + BEFORE (2) + INSERT (4) + UPDATE (16).
          and t.tgtype = 23 and t.tgnargs = 0 and t.tgqual is null and t.tgattr::text = ''
          and t.tgfoid = to_regprocedure('pickem_private.guard_game_lifecycle()')
      )
      union all
      select 'Migration history · ' || e.version, exists (
        select 1 from supabase_migrations.schema_migrations m
        where m.version = e.version and m.name = e.name
      )
      from (values
        ('20261124000100', 'pickem_schema'),
        ('20261124000200', 'pickem_access'),
        ('20261125000100', 'pickem_game_lifecycle'),
        ('20261125000200', 'pickem_scoring'),
        ('20261125000300', 'pickem_mail_claims')
      ) e(version,name)
    )
    select check_name, passed from checks
  ) verified where passed is distinct from true;
  if failed is not null then raise exception 'Phase 4 refused because Phase 3 verification failed (%)', failed; end if;
end;
$baseline$;

-- Begin 20261125000400_pickem_nfl_periods.sql
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
-- End 20261125000400_pickem_nfl_periods.sql

-- Begin 20261125000500_pickem_nfl_sync.sql
create function public.sync_pickem_nfl_week(p_snapshot jsonb)
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
    observed_at timestamptz, home_score smallint, away_score smallint)
  loop
    if game_row.provider_id !~ '^[1-9][0-9]*$' or nullif(btrim(game_row.reference_id), '') is null
      or game_row.observed_at is null or game_row.observed_at > checked_at + interval '5 minutes'
      or game_row.status is null or game_row.status not in
        ('scheduled', 'in_progress', 'postponed', 'suspended', 'final', 'canceled')
      or (game_row.status in ('scheduled', 'final') and game_row.kickoff_at is null)
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
      'kickoff_at', coalesce(game_row.kickoff_at, old_game.kickoff_at),
      'home_score', game_row.home_score, 'away_score', game_row.away_score);
    if old_game.provider_updated_at = game_row.observed_at and old_values is distinct from new_values then
      raise exception 'Changed game evidence has no newer provider timestamp';
    end if;

    insert into public.games (week_id, home_team_id, away_team_id, source, source_game_id, reference_game_id,
      kickoff_at, started_at, status, home_score, away_score, provider_updated_at, schedule_verified_until,
      final_verified_at, cancellation_verified_at)
    values (target_week.id, home_id, away_id, 'balldontlie', game_row.provider_id, game_row.reference_id,
      coalesce(game_row.kickoff_at, old_game.kickoff_at),
      case when game_row.status in ('in_progress', 'suspended', 'final') then
        coalesce(old_game.started_at, game_row.kickoff_at, checked_at) end,
      game_row.status, game_row.home_score, game_row.away_score, game_row.observed_at,
      case when game_row.status = 'scheduled' then checked_at + interval '3 hours' end,
      case when game_row.status = 'final' then
        case when old_values is not distinct from new_values then coalesce(old_game.final_verified_at, checked_at)
             else checked_at end end,
      case when game_row.status = 'canceled' then coalesce(old_game.cancellation_verified_at, checked_at) end)
    on conflict (source, source_game_id) do update set reference_game_id = excluded.reference_game_id,
      kickoff_at = excluded.kickoff_at, started_at = excluded.started_at, status = excluded.status,
      home_score = excluded.home_score, away_score = excluded.away_score,
      provider_updated_at = excluded.provider_updated_at, schedule_verified_until = excluded.schedule_verified_until,
      final_verified_at = excluded.final_verified_at, cancellation_verified_at = excluded.cancellation_verified_at
    returning * into saved_game;

    if old_values is distinct from new_values or old_game.final_verified_at is distinct from saved_game.final_verified_at
        or old_game.cancellation_verified_at is distinct from saved_game.cancellation_verified_at then
      changes := true;
      insert into public.audit_log (action, details) values (
        case when old_game.status = 'final' and game_row.status = 'final' then 'nfl_score_correction'
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
revoke all on function public.sync_pickem_nfl_week(jsonb) from public, anon, authenticated;
grant execute on function public.sync_pickem_nfl_week(jsonb) to service_role;

-- A detected bad snapshot or outage closes open automated games immediately.
-- The original kickoff, permanent lock and any verified final stay intact.
create function public.invalidate_pickem_nfl_week(p_season integer, p_phase text, p_week integer)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(20261125, 400);
  update public.games g set schedule_verified_until = null
  from public.weeks w join public.seasons s on s.id = w.season_id
  where g.week_id = w.id and s.nfl_year = p_season and w.competition_phase = p_phase
    and w.week_number = p_week and g.source = 'balldontlie' and g.status = 'scheduled'
    and g.schedule_verified_until is not null;
  insert into public.job_runs (job_name, status, finished_at)
    values ('nfl_sync', 'failed', clock_timestamp());
end;
$$;
revoke all on function public.invalidate_pickem_nfl_week(integer,text,integer) from public, anon, authenticated;
grant execute on function public.invalidate_pickem_nfl_week(integer,text,integer) to service_role;
-- End 20261125000500_pickem_nfl_sync.sql

insert into supabase_migrations.schema_migrations (version,name) values
    ('20261125000400', 'pickem_nfl_periods'),
    ('20261125000500', 'pickem_nfl_sync');

do $installed$
declare failed text;
begin
  select string_agg(check_name, ', ' order by check_name) into failed from (
    with expected_tables(name, participant_access) as (
      values ('participants', 'directory'), ('seasons', 'read'), ('weeks', 'read'),
        ('teams', 'read'), ('games', 'read'), ('picks', 'read'),
        ('weekly_results', 'read'), ('season_standings', 'read'), ('email_log', 'none'),
        ('job_runs', 'none'), ('audit_log', 'none')
    ), tables as (
      select e.*, c.oid, c.relrowsecurity, c.relowner
      from expected_tables e
      left join pg_class c on c.oid = to_regclass('public.' || e.name) and c.relkind = 'r'
    ), expected_functions(signature, source_hash, is_definer, participant_exec, service_exec, defaults) as (
      values
        ('pickem_private.active_participant_id()', 'fe2c6a6d427ba3aab96593e7755f3409', true, true, false, 0),
        ('public.submit_pick(bigint,bigint)', 'e2e97b75169d78ea05e7fdead195e50f', true, true, false, 0),
        ('pickem_private.guard_game_lifecycle()', '6bd99b754523fe99cfcf9a7e155c02ab', false, false, false, 0),
        ('public.pickem_identity()', 'd0b3ba76649d831a5131200cb57c618a', true, true, false, 0),
        ('public.recalculate_pickem_week(bigint)', '311c078f4833105df507383af0c394f0', true, false, true, 0),
        ('public.claim_pickem_email(bigint,uuid,text)', 'fa83953eeb70b46eac5f97fe3c5306d8', true, false, true, 0),
        ('public.sync_pickem_nfl_week(jsonb)', '91bedaac1af929c0feb604814a23ad97', true, false, true, 0),
        ('public.invalidate_pickem_nfl_week(integer,text,integer)', '1e5087bf5f2cb0c7a27107b2c94501b2', true, false, true, 0),
        ('public.finish_pickem_email(uuid,text,text)', 'a476df2838f3d8c503720f51034fc5e6', true, false, true, 1)
    ), checks as (
      select 'Table and RLS · ' || name as check_name,
        oid is not null and coalesce(relrowsecurity, false) as passed
      from tables
      union all
      select 'Policy · ' || t.name, coalesce((
        select case when t.participant_access = 'none' then count(*) = 0
          else count(*) = 1 and bool_and(
            p.policyname = t.name || '_read' and p.cmd = 'SELECT'
            and p.roles = array['authenticated']::name[] and p.permissive = 'PERMISSIVE'
            and p.with_check is null
            and regexp_replace(replace(p.qual, 'public.games', 'games'), '[[:space:]]', '', 'g')
              = case when t.name = 'picks' then
                '(((SELECTpickem_private.active_participant_id()ASactive_participant_id)ISNOTNULL)AND((participant_id=(SELECTpickem_private.active_participant_id()ASactive_participant_id))OR(EXISTS(SELECT1FROMgamesWHERE((games.id=picks.game_id)AND(games.status=''final''::text)AND(games.final_verified_atISNOTNULL))))))'
                else '((SELECTpickem_private.active_participant_id()ASactive_participant_id)ISNOTNULL)' end
          ) end
        from pg_policies p where p.schemaname = 'public' and p.tablename = t.name
      ), false)
      from tables t
      union all
      select 'Table grants · ' || t.name, coalesce(
        not has_any_column_privilege('anon', oid, 'SELECT,INSERT,UPDATE,REFERENCES')
        and not has_table_privilege('anon', oid, 'DELETE,TRUNCATE,TRIGGER')
        and not has_any_column_privilege('authenticated', oid, 'INSERT,UPDATE,REFERENCES')
        and not has_table_privilege('authenticated', oid, 'DELETE,TRUNCATE,TRIGGER')
        and case participant_access
          when 'read' then has_table_privilege('authenticated', oid, 'SELECT')
          when 'none' then not has_any_column_privilege('authenticated', oid, 'SELECT')
          else not has_table_privilege('authenticated', oid, 'SELECT')
            and (select array_agg(a.attname::text order by a.attname)
                 from pg_attribute a where a.attrelid = t.oid and a.attnum > 0
                   and not a.attisdropped
                   and has_column_privilege('authenticated', t.oid, a.attnum, 'SELECT'))
                = array['display_name','id']
        end
        and has_table_privilege('service_role', oid, 'SELECT')
        and has_table_privilege('service_role', oid, 'INSERT')
        and has_table_privilege('service_role', oid, 'UPDATE')
        and has_table_privilege('service_role', oid, 'DELETE'), false)
      from tables t
      union all
      select 'Function and execution grants · ' || f.signature,
        coalesce(md5(p.prosrc) = f.source_hash and p.prosecdef = f.is_definer
          and p.proowner = (select relowner from tables where name = 'picks')
          and 'search_path=""' = any(p.proconfig) and p.pronargdefaults = f.defaults
          and not has_function_privilege('anon', p.oid, 'EXECUTE')
          and has_function_privilege('authenticated', p.oid, 'EXECUTE') = f.participant_exec
          and (not f.service_exec or has_function_privilege('service_role', p.oid, 'EXECUTE')), false)
      from expected_functions f
      left join pg_proc p on p.oid = to_regprocedure(f.signature)
      union all
      select 'Private schema usage',
        coalesce(has_schema_privilege('authenticated', to_regnamespace('pickem_private'), 'USAGE')
          and not has_schema_privilege('anon', to_regnamespace('pickem_private'), 'USAGE'), false)
      union all
      select 'Pick’em tables excluded from Realtime',
        not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
          and schemaname = 'public' and tablename in (select name from expected_tables))
      union all
      select 'Column · ' || e.table_name || '.' || e.column_name, exists (
        select 1 from pg_attribute a
        left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
        where a.attrelid = to_regclass('public.' || e.table_name) and a.attname = e.column_name
          and a.attnum > 0 and not a.attisdropped and a.atttypid = e.column_type::regtype
          and a.attnotnull = e.required
          and case when e.required then pg_get_expr(d.adbin, d.adrelid) in ('0', '0::smallint', '''0''::smallint')
              else d.oid is null end
      )
      from (values ('games','picks_locked_at','timestamptz',false),
        ('games','cancellation_verified_at','timestamptz',false), ('email_log','claim_token','uuid',false),
        ('email_log','attempts','smallint',true)) e(table_name,column_name,column_type,required)
      union all
      select 'Constraint · ' || e.constraint_name, exists (
        select 1 from pg_constraint c
        where c.conrelid = to_regclass('public.' || e.table_name) and c.conname = e.constraint_name
          and c.contype = 'c' and c.convalidated
          and regexp_replace(pg_get_expr(c.conbin,c.conrelid), '[[:space:]()]', '', 'g') = e.expression
      )
      from (values ('games','verified_cancellation_has_canceled_status',
          'cancellation_verified_atISNULLORstatus=''canceled''::text'),
        ('email_log','email_log_attempts_check','attempts>=0ANDattempts<=3'))
        e(table_name,constraint_name,expression)
      union all
      select 'Index · email_log_claim_token_idx', exists (
        select 1 from pg_index i
        join pg_class idx on idx.oid = i.indexrelid
        join pg_am am on am.oid = idx.relam
        join pg_attribute a on a.attrelid = i.indrelid and a.attname = 'claim_token' and not a.attisdropped
        where i.indexrelid = to_regclass('public.email_log_claim_token_idx')
          and i.indrelid = to_regclass('public.email_log') and am.amname = 'btree'
          and i.indisunique and i.indisvalid and i.indisready
          and i.indnkeyatts = 1 and i.indnatts = 1 and i.indkey[0] = a.attnum
          and i.indexprs is null and pg_get_expr(i.indpred,i.indrelid) = '(claim_token IS NOT NULL)'
      )
      union all
      select 'Trigger · guard_game_lifecycle', exists (
        select 1 from pg_trigger t where t.tgrelid = to_regclass('public.games')
          and t.tgname = 'guard_game_lifecycle' and not t.tgisinternal and t.tgenabled = 'O'
          -- ROW (1) + BEFORE (2) + INSERT (4) + UPDATE (16).
          and t.tgtype = 23 and t.tgnargs = 0 and t.tgqual is null and t.tgattr::text = ''
          and t.tgfoid = to_regprocedure('pickem_private.guard_game_lifecycle()')
      )
      union all
      select 'Migration history · ' || e.version, exists (
        select 1 from supabase_migrations.schema_migrations m
        where m.version = e.version and m.name = e.name
      )
      from (values
        ('20261124000100', 'pickem_schema'),
        ('20261124000200', 'pickem_access'),
        ('20261125000100', 'pickem_game_lifecycle'),
        ('20261125000200', 'pickem_scoring'),
        ('20261125000300', 'pickem_mail_claims'),
        ('20261125000400', 'pickem_nfl_periods'),
        ('20261125000500', 'pickem_nfl_sync')
      ) e(version,name)
      union all
      select 'Column · ' || e.table_name || '.' || e.column_name, exists (
        select 1 from pg_attribute a
        left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
        where a.attrelid = to_regclass('public.' || e.table_name) and a.attname = e.column_name
          and a.attnum > 0 and not a.attisdropped and a.atttypid = e.column_type::regtype
          and (case when e.column_name = 'competition_phase' then a.attnotnull
            and pg_get_expr(d.adbin,d.adrelid) = '''regular''::text' else not a.attnotnull and d.oid is null end)
      )
      from (values ('weeks','competition_phase','text'), ('teams','balldontlie_id','bigint'),
        ('games','provider_updated_at','timestamptz'), ('games','reference_game_id','text'),
        ('games','schedule_verified_until','timestamptz')) e(table_name,column_name,column_type)
      union all
      select 'Constraint · ' || e.constraint_name, exists (
        select 1 from pg_constraint c where c.conrelid = to_regclass('public.' || e.table_name)
          and c.conname = e.constraint_name and c.convalidated
          and pg_get_constraintdef(c.oid) = e.definition
      )
      from (values ('weeks','weeks_season_phase_number_key','UNIQUE (season_id, competition_phase, week_number)'),
        ('teams','teams_balldontlie_id_key','UNIQUE (balldontlie_id)'),
        ('teams','teams_balldontlie_id_check','CHECK ((balldontlie_id > 0))'))
        e(table_name,constraint_name,definition)
      union all
      select 'Constraint · allowed competition periods', exists (
        select 1 from pg_constraint c where conrelid = to_regclass('public.weeks')
          and conname = 'weeks_competition_period_check' and contype = 'c' and convalidated
          and regexp_replace(pg_get_expr(c.conbin,c.conrelid), '[[:space:]()]', '', 'g') =
            'competition_phase=''regular''::textANDweek_number>=1ANDweek_number<=18ORcompetition_phase=''postseason''::textANDweek_number=ANYARRAY[1,2,3,5]'
      )
      union all
      select 'Index · games_balldontlie_reference_key', exists (
        select 1 from pg_index i
        join pg_attribute a on a.attrelid=i.indrelid and a.attname='reference_game_id' and not a.attisdropped
        where i.indexrelid = to_regclass('public.games_balldontlie_reference_key')
          and i.indrelid = to_regclass('public.games') and i.indisunique and i.indisvalid and i.indisready
          and i.indnkeyatts = 1 and i.indnatts = 1 and i.indkey[0] = a.attnum and i.indexprs is null
          and pg_get_expr(i.indpred,i.indrelid) = '((source = ''balldontlie''::text) AND (reference_game_id IS NOT NULL))'
      )
      union all
      select 'Service privilege hardening · ' || name, coalesce(
        not has_table_privilege('service_role', oid, 'TRUNCATE,TRIGGER')
        and not has_any_column_privilege('service_role', oid, 'REFERENCES'), false)
      from tables
    )
    select check_name, passed from checks
  ) verified where passed is distinct from true;
  if failed is not null then raise exception 'Phase 4 rolled back because verification failed (%)', failed; end if;
end;
$installed$;

notify pgrst, 'reload schema';
commit;
