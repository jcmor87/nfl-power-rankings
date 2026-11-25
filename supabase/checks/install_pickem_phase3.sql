-- Install Phase 3 over the reviewed Pick’em baseline.
-- Paste the entire script into one Supabase SQL Editor query as postgres.
-- After an error or uncertain connection, inspect history and catalog state
-- before retrying. Existing Phase 3 artifacts or history cause refusal.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local search_path = pg_catalog, public;
select pg_advisory_xact_lock(20261124, 100);

do $preflight$
declare
  failed text;
begin
  if to_regclass('supabase_migrations.schema_migrations') is null then
    raise exception 'Phase 3 refused: migration history is missing';
  end if;
  if (select count(*) from supabase_migrations.schema_migrations
      where (version,name) in (('20261124000100','pickem_schema'), ('20261124000200','pickem_access'))) <> 2 then
    raise exception 'Phase 3 refused: expected both baseline versions and names';
  end if;
  if exists (select 1 from supabase_migrations.schema_migrations where version in ('20261125000100', '20261125000200', '20261125000300')) then
    raise exception 'Phase 3 refused: at least one Phase 3 version is already recorded';
  end if;
  if exists (
    select 1 from pg_attribute where attnum > 0 and not attisdropped and (
      (attrelid = to_regclass('public.games') and attname in ('picks_locked_at','cancellation_verified_at'))
      or (attrelid = to_regclass('public.email_log') and attname in ('claim_token','attempts'))
    )
  ) or exists (
    select 1 from pg_constraint where
      (conrelid = to_regclass('public.games') and conname = 'verified_cancellation_has_canceled_status')
      or (conrelid = to_regclass('public.email_log') and conname = 'email_log_attempts_check')
  ) or to_regclass('public.email_log_claim_token_idx') is not null
    or exists (select 1 from pg_trigger where tgrelid = to_regclass('public.games') and not tgisinternal)
    or exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where (n.nspname = 'pickem_private' and p.proname = 'guard_game_lifecycle')
        or (n.nspname = 'public' and p.proname in
          ('pickem_identity','recalculate_pickem_week','claim_pickem_email','finish_pickem_email'))
    ) then
    raise exception 'Phase 3 refused: unexpected migration objects or game triggers';
  end if;

  select string_agg(check_name, ', ' order by check_name) into failed
  from (
    with expected_tables(name, participant_access) as (
      values ('participants', 'directory'), ('seasons', 'read'), ('weeks', 'read'),
        ('teams', 'read'), ('games', 'read'), ('picks', 'read'),
        ('weekly_results', 'none'), ('season_standings', 'none'), ('email_log', 'none'),
        ('job_runs', 'none'), ('audit_log', 'none')
    ), tables as (
      select e.*, c.oid, c.relrowsecurity, c.relowner
      from expected_tables e
      left join pg_class c on c.oid = to_regclass('public.' || e.name) and c.relkind = 'r'
    ), expected_functions(signature, source_hashes, is_definer, participant_exec, service_exec, defaults) as (
      values
        ('pickem_private.active_participant_id()', array['fe2c6a6d427ba3aab96593e7755f3409'], true, true, false, 0),
        -- The reviewed browser-installed baseline adds three blank lines.
        ('public.submit_pick(bigint,bigint)',
         array['a2a2b0b1eadf7c8865cb02087023f41a', '5f209ec1c6d128e96710305743f6b11a'],
         true, true, false, 0)
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
        coalesce(md5(p.prosrc) = any(f.source_hashes) and p.prosecdef = f.is_definer
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
    )
    select check_name, passed from checks
  ) baseline
  where passed is distinct from true;
  if failed is not null then
    raise exception 'Phase 3 refused: baseline checks failed (%)', failed;
  end if;
end;
$preflight$;

-- Begin 20261125000100_pickem_game_lifecycle.sql
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
-- End 20261125000100_pickem_game_lifecycle.sql

-- Begin 20261125000200_pickem_scoring.sql
grant select on public.weekly_results, public.season_standings to authenticated;
create policy weekly_results_read on public.weekly_results for select to authenticated
  using ((select pickem_private.active_participant_id()) is not null);
create policy season_standings_read on public.season_standings for select to authenticated
  using ((select pickem_private.active_participant_id()) is not null);

create function public.recalculate_pickem_week(p_week_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  season_key bigint;
  target_week public.weeks;
  count_games integer;
  all_terminal boolean;
  roster uuid[];
begin
  select season_id into season_key from public.weeks where id = p_week_id;
  if not found then raise exception 'Unknown week'; end if;

  -- Serialize scoring for the season. Lock games before the week, as submit_pick does.
  perform 1 from public.seasons where id = season_key for no key update;
  perform 1 from public.games where week_id = p_week_id order by id for share;
  select * into target_week from public.weeks where id = p_week_id for update;
  if target_week.status not in ('active', 'complete')
     or target_week.season_id is distinct from season_key then
    raise exception 'Week is not eligible for scoring';
  end if;

  select count(*), bool_and(
    (status = 'final' and final_verified_at is not null)
    or (status = 'canceled' and cancellation_verified_at is not null)
  )
  into count_games, all_terminal
  from public.games where week_id = p_week_id;
  if count_games is distinct from target_week.expected_games or all_terminal is distinct from true then
    raise exception 'Every expected game must have a verified terminal result';
  end if;

  select array_agg(participant_id) into roster from public.weekly_results where week_id = p_week_id;
  if roster is null then
    select array_agg(id) into roster from public.participants where active;
  end if;
  if cardinality(roster) is distinct from 5 then raise exception 'Five participants required'; end if;

  with totals as (
    select r.participant_id,
      count(g.id) filter (where g.status = 'final')::int as eligible_games,
      count(g.id) filter (where g.status = 'final' and (
        (g.home_score > g.away_score and p.team_id = g.home_team_id)
        or (g.away_score > g.home_score and p.team_id = g.away_team_id)
      ))::int as points
    from unnest(roster) r(participant_id)
    cross join public.games g
    left join public.picks p on p.game_id = g.id and p.participant_id = r.participant_id
    where g.week_id = p_week_id
    group by r.participant_id
  )
  insert into public.weekly_results (week_id, participant_id, points, eligible_games, rank)
  select p_week_id, participant_id, points, eligible_games, rank() over (order by points desc)
  from totals
  on conflict (week_id, participant_id) do update set
    points = excluded.points, eligible_games = excluded.eligible_games,
    rank = excluded.rank, calculated_at = clock_timestamp();

  update public.weeks set status = 'complete' where id = p_week_id;

  with totals as (
    select wr.participant_id, sum(wr.points)::int as points, sum(wr.eligible_games)::int as eligible_games
    from public.weekly_results wr join public.weeks w on w.id = wr.week_id
    where w.season_id = season_key and w.status = 'complete'
    group by wr.participant_id
  )
  insert into public.season_standings (season_id, participant_id, points, eligible_games, rank)
  select season_key, participant_id, points, eligible_games, rank() over (order by points desc)
  from totals
  on conflict (season_id, participant_id) do update set
    points = excluded.points, eligible_games = excluded.eligible_games,
    rank = excluded.rank, calculated_at = clock_timestamp();
end;
$$;

revoke all on function public.recalculate_pickem_week(bigint) from public, anon, authenticated;
grant execute on function public.recalculate_pickem_week(bigint) to service_role;
-- End 20261125000200_pickem_scoring.sql

-- Begin 20261125000300_pickem_mail_claims.sql
alter table public.email_log
  add column claim_token uuid,
  add column attempts smallint not null default 0 check (attempts between 0 and 3);

create function public.claim_pickem_email(p_week_id bigint, p_participant_id uuid, p_kind text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  token uuid := gen_random_uuid();
  pacific_now timestamp := clock_timestamp() at time zone 'America/Los_Angeles';
  target_week public.weeks;
begin
  -- Match the scoring lock order.
  perform 1 from public.games where week_id = p_week_id order by id for share;
  select * into target_week from public.weeks where id = p_week_id for share;
  if not found or p_kind is null or p_kind not in ('reminder', 'results') then return null; end if;
  if not exists (select 1 from public.participants where id = p_participant_id and active) then
    return null;
  end if;

  if p_kind = 'reminder' then
    if target_week.status <> 'active' or extract(isodow from pacific_now) <> 3
       or pacific_now::time < time '12:00'
       or not exists (
         select 1 from public.games where week_id = p_week_id and status = 'scheduled'
           and picks_locked_at is null and started_at is null and kickoff_at > clock_timestamp()
       ) then return null; end if;
  elsif target_week.status <> 'complete'
    or (select count(*) from public.weekly_results where week_id = p_week_id) <> 5
    or not exists (select 1 from public.weekly_results
                   where week_id = p_week_id and participant_id = p_participant_id)
    or (select count(*) from public.games where week_id = p_week_id) <> target_week.expected_games
    or exists (
      select 1 from public.games where week_id = p_week_id
        and not ((status = 'final' and final_verified_at is not null)
          or (status = 'canceled' and cancellation_verified_at is not null))
    ) then return null;
  end if;

  insert into public.email_log (week_id, participant_id, kind, status, claim_token, attempts)
  values (p_week_id, p_participant_id, p_kind, 'claimed', token, 1)
  on conflict (week_id, participant_id, kind) do update
    set status = 'claimed', claim_token = token, attempts = public.email_log.attempts + 1,
      updated_at = clock_timestamp()
    where public.email_log.status = 'failed' and public.email_log.attempts < 3
      and public.email_log.updated_at < clock_timestamp() - interval '15 minutes'
  returning claim_token into token;
  return token;
end;
$$;

create function public.finish_pickem_email(p_claim uuid, p_status text, p_provider_message_id text default null)
returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  if p_claim is null or p_status is null or p_status not in ('accepted', 'failed', 'ambiguous') then return false; end if;
  if p_status = 'accepted' and nullif(btrim(p_provider_message_id), '') is null then return false; end if;
  update public.email_log set status = p_status, provider_message_id = p_provider_message_id,
    updated_at = clock_timestamp()
  where claim_token = p_claim and status = 'claimed';
  return found;
end;
$$;

create unique index email_log_claim_token_idx on public.email_log(claim_token) where claim_token is not null;
revoke all on function public.claim_pickem_email(bigint, uuid, text) from public, anon, authenticated;
revoke all on function public.finish_pickem_email(uuid, text, text) from public, anon, authenticated;
grant execute on function public.claim_pickem_email(bigint, uuid, text) to service_role;
grant execute on function public.finish_pickem_email(uuid, text, text) to service_role;
-- End 20261125000300_pickem_mail_claims.sql

insert into supabase_migrations.schema_migrations (version, name)
values ('20261125000100', 'pickem_game_lifecycle'), ('20261125000200', 'pickem_scoring'), ('20261125000300', 'pickem_mail_claims');

do $postconditions$
declare
  failed text;
begin
  select string_agg(check_name, ', ' order by check_name) into failed
  from (
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
  ) installed
  where passed is distinct from true;
  if failed is not null then
    raise exception 'Phase 3 rolled back: verification failed (%)', failed;
  end if;
end;
$postconditions$;

notify pgrst, 'reload schema';
commit;
