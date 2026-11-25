-- Run in one Supabase SQL Editor query as postgres after all eight earlier migrations.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '45s';
set local search_path = pg_catalog, public;
select pg_advisory_xact_lock(20261124, 100);

do $baseline$
begin
  if not exists (select 1 from supabase_migrations.schema_migrations
    where version='20261125000600' and name='pickem_kickoff_evidence')
    or to_regprocedure('public.sync_pickem_nfl_week(jsonb)') is null then
    raise exception 'The kickoff evidence migration must be installed';
  end if;
  if exists (select 1 from supabase_migrations.schema_migrations where version='20261125000700') then
    raise exception 'Family automation migration already recorded';
  end if;
end;
$baseline$;

-- Begin 20261125000700_pickem_family_automation.sql
create function public.sync_pickem_family_period(p_snapshot jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  phase text := p_snapshot->>'phase';
  round_number integer := (p_snapshot->>'week')::integer;
  activation_time timestamptz;
begin
  if (p_snapshot->>'season') is distinct from '2026' or not coalesce(
    (phase = 'regular' and round_number between 13 and 18)
    or (phase = 'postseason' and round_number in (1,2,3,5)), false
  ) then
    raise exception 'Period is outside the 2026 family competition';
  end if;

  perform public.sync_pickem_nfl_week(p_snapshot);

  -- Activation is prospective. A missed launch week cannot be bypassed by
  -- activating later periods or retroactively adding historical results.
  activation_time := clock_timestamp();
  update public.weeks w set status = 'active'
  from public.seasons s
  where s.id = w.season_id and s.nfl_year = 2026
    and w.competition_phase = phase and w.week_number = round_number and w.status = 'planned'
    and (select count(*) from public.participants where active) = 5
    and ((phase = 'regular' and round_number = 13) or exists (
      select 1 from public.weeks opening
      where opening.season_id = w.season_id and opening.competition_phase = 'regular'
        and opening.week_number = 13 and opening.status in ('active','complete')
    ))
    and (select count(*) from public.games where week_id = w.id) = w.expected_games
    and not exists (
      select 1 from public.games g where g.week_id = w.id and (
        g.status <> 'scheduled' or g.source <> 'balldontlie' or g.started_at is not null
        or g.picks_locked_at is not null or g.reference_kickoff_at is null
        or g.pick_deadline_at is null or g.pick_deadline_at <= activation_time
        or g.schedule_verified_until is null or g.schedule_verified_until <= activation_time
      )
    );
end;
$$;
revoke all on function public.sync_pickem_family_period(jsonb) from public, anon, authenticated;
grant execute on function public.sync_pickem_family_period(jsonb) to service_role;
-- End 20261125000700_pickem_family_automation.sql

insert into supabase_migrations.schema_migrations(version,name)
values ('20261125000700','pickem_family_automation');

do $installed$
begin
  if exists (
    select 1 from (
      -- Read-only. Every check must pass.
      select 'Migration recorded' as check_name, exists (
        select 1 from supabase_migrations.schema_migrations
        where version = '20261125000700' and name = 'pickem_family_automation'
      ) as passed
      union all
      select 'Family sync is service-only with an empty search path', coalesce((
        select p.prosecdef and 'search_path=""' = any(p.proconfig)
          and p.proowner = (select relowner from pg_class where oid = 'public.weeks'::regclass)
          and not has_function_privilege('anon',p.oid,'EXECUTE')
          and not has_function_privilege('authenticated',p.oid,'EXECUTE')
          and has_function_privilege('service_role',p.oid,'EXECUTE')
        from pg_proc p where p.oid = to_regprocedure('public.sync_pickem_family_period(jsonb)')
      ),false)
      union all
      select 'Competition RLS remains enabled', (
        select count(*)=3 and bool_and(c.relrowsecurity)
        from pg_class c where c.oid in ('public.weeks'::regclass,'public.games'::regclass,'public.picks'::regclass)
      )
    ) checks where passed is distinct from true
  ) then raise exception 'Family automation verification failed'; end if;
end;
$installed$;

notify pgrst, 'reload schema';
commit;
