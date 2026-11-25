-- Run as postgres in SQL Editor. Every row in the result should pass.
with expected_tables(name, participant_access) as (
  values ('participants', 'directory'), ('seasons', 'read'), ('weeks', 'read'),
    ('teams', 'read'), ('games', 'read'), ('picks', 'read'),
    ('weekly_results', 'none'), ('season_standings', 'none'), ('email_log', 'none'),
    ('job_runs', 'none'), ('audit_log', 'none')
), tables as (
  select e.*, c.oid, c.relrowsecurity
  from expected_tables e
  left join pg_class c on c.oid = to_regclass('public.' || e.name) and c.relkind = 'r'
), table_checks as (
  select name, oid is not null as present, coalesce(relrowsecurity, false) as rls,
    coalesce((
      select case when t.participant_access = 'none' then count(*) = 0
             else count(*) = 1 and bool_and(
               p.policyname = t.name || '_read' and p.cmd = 'SELECT'
               and p.roles = array['authenticated']::name[]
               and p.qual like '%pickem_private.active_participant_id()%'
               and (t.name <> 'picks' or (p.qual like '%final_verified_at IS NOT NULL%'
                 and p.qual like '%status%final%'))
             ) end
      from pg_policies p where p.schemaname = 'public' and p.tablename = t.name
    ), false) as policies,
    coalesce(
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
      and has_table_privilege('service_role', oid, 'DELETE'), false
    ) as grants
  from tables t
), expected_functions(signature) as (
  values ('public.submit_pick(bigint,bigint)'), ('pickem_private.active_participant_id()')
)
select name as object, present and rls and policies and grants as passed,
  jsonb_build_object('present', present, 'rls', rls, 'policies', policies, 'grants', grants) as checks
from table_checks
union all
select f.signature,
  coalesce(p.prosecdef and 'search_path=""' = any(p.proconfig)
    and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and not has_function_privilege('anon', p.oid, 'EXECUTE'), false),
  jsonb_build_object('present', p.oid is not null, 'security_definer', p.prosecdef, 'settings', p.proconfig)
from expected_functions f
left join pg_proc p on p.oid = to_regprocedure(f.signature)
union all
select 'private schema usage',
  coalesce(has_schema_privilege('authenticated', to_regnamespace('pickem_private'), 'USAGE')
    and not has_schema_privilege('anon', to_regnamespace('pickem_private'), 'USAGE'), false),
  '{}'::jsonb
union all
select 'Realtime',
  not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
    and schemaname = 'public' and tablename in (select name from expected_tables)),
  '{}'::jsonb
order by object;
