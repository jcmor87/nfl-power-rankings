-- Compare these results with the migration files before hosted testing.
select version, name, coalesce(cardinality(statements), 0) as recorded_statement_count
from supabase_migrations.schema_migrations
where version in ('20261124000100','20261124000200','20261125000100','20261125000200','20261125000300')
order by version;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public' and tablename in ('participants','seasons','weeks','teams','games',
  'picks','weekly_results','season_standings','email_log','job_runs','audit_log')
order by tablename;

select table_name, ordinal_position, column_name, data_type, is_nullable, column_default, is_identity
from information_schema.columns
where table_schema = 'public' and table_name in ('participants','seasons','weeks','teams','games',
  'picks','weekly_results','season_standings','email_log','job_runs','audit_log')
order by table_name, ordinal_position;

select c.relname as table_name, x.conname, pg_get_constraintdef(x.oid) as definition
from pg_constraint x join pg_class c on c.oid = x.conrelid
where c.relnamespace = 'public'::regnamespace and c.relname in ('participants','seasons','weeks','teams','games',
  'picks','weekly_results','season_standings','email_log','job_runs','audit_log')
order by c.relname, x.conname;

select tablename, policyname, roles, cmd, qual, with_check
from pg_policies where schemaname = 'public'
order by tablename, policyname;

select grantee, table_name, privilege_type
from information_schema.table_privileges
where table_schema = 'public' and grantee in ('PUBLIC','anon','authenticated','service_role')
order by grantee, table_name, privilege_type;

select grantee, table_name, column_name, privilege_type
from information_schema.column_privileges
where table_schema = 'public' and table_name = 'participants'
  and grantee in ('PUBLIC','anon','authenticated')
order by grantee, column_name;

select n.nspname as schema_name, p.proname, pg_get_functiondef(p.oid) as definition,
  has_function_privilege('anon', p.oid, 'execute') as anon_execute,
  has_function_privilege('authenticated', p.oid, 'execute') as participant_execute,
  has_function_privilege('service_role', p.oid, 'execute') as service_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public','pickem_private') and p.proname in ('active_participant_id',
  'submit_pick','pickem_identity','guard_game_lifecycle','recalculate_pickem_week',
  'claim_pickem_email','finish_pickem_email')
order by n.nspname, p.proname;

select tgname, pg_get_triggerdef(oid) as definition
from pg_trigger
where tgrelid = to_regclass('public.games') and not tgisinternal;
