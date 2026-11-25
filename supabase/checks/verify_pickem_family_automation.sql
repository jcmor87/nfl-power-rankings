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
);
