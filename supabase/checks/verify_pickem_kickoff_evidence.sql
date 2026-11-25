-- Every row should have passed = true. Read-only.
select 'Migration · ' || e.version as check_name, exists (
    select 1 from supabase_migrations.schema_migrations m where m.version = e.version and m.name = e.name
  ) as passed
  from (values ('20261124000100','pickem_schema'), ('20261124000200','pickem_access'), ('20261125000100','pickem_game_lifecycle'), ('20261125000200','pickem_scoring'), ('20261125000300','pickem_mail_claims'), ('20261125000400','pickem_nfl_periods'), ('20261125000500','pickem_nfl_sync'), ('20261125000600','pickem_kickoff_evidence')) e(version,name)
union all
select 'Function · ' || f.signature as check_name, coalesce(
    md5(p.prosrc) = f.source_hash and p.prosecdef = f.is_definer
    and 'search_path=""' = any(p.proconfig)
    and p.proowner = (select relowner from pg_class where oid = 'public.picks'::regclass)
    and not has_function_privilege('anon',p.oid,'EXECUTE')
    and has_function_privilege('authenticated',p.oid,'EXECUTE') = f.auth_execute
    and (not f.require_service or has_function_privilege('service_role',p.oid,'EXECUTE')), false) as passed
  from (values
    ('pickem_private.guard_game_lifecycle()', '8b6c58940541e6921dfc44b32cfafc12', false, false, false),
    ('public.submit_pick(bigint,bigint)', '3fadf571e43aafc87810d90e9f260126', true, true, false),
    ('public.sync_pickem_nfl_week(jsonb)', '96bfb2ebdfb9d1e21c4741619500dd6f', true, false, true)
  ) f(signature,source_hash,is_definer,auth_execute,require_service)
  left join pg_proc p on p.oid = to_regprocedure(f.signature)
union all
select 'Column · ' || e.column_name, exists (
  select 1 from pg_attribute a where a.attrelid = 'public.games'::regclass and a.attname = e.column_name
    and a.atttypid = e.column_type::regtype and a.attnum > 0 and not a.attisdropped
    and a.attgenerated::text = e.generated
)
from (values ('reference_kickoff_at','timestamptz',''), ('pick_deadline_at','timestamptz','s'),
  ('kickoff_reconciliation','text','s')) e(column_name,column_type,generated)
union all
select 'Constraint · games_kickoff_evidence_tolerance', exists (
  select 1 from pg_constraint where conrelid = 'public.games'::regclass
    and conname = 'games_kickoff_evidence_tolerance' and contype = 'c' and convalidated
)
union all
select 'Lifecycle trigger remains enabled', exists (
  select 1 from pg_trigger where tgrelid = 'public.games'::regclass
    and tgfoid = 'pickem_private.guard_game_lifecycle()'::regprocedure
    and tgname = 'guard_game_lifecycle' and tgenabled = 'O' and tgtype = 23
)
union all
select 'Game and pick RLS and anonymous denial', (
  select count(*) = 2 and bool_and(c.relrowsecurity and
    not has_any_column_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,REFERENCES') and
    not has_table_privilege('anon',c.oid,'DELETE,TRUNCATE,TRIGGER'))
  from pg_class c where c.oid in ('public.games'::regclass,'public.picks'::regclass)
)
order by check_name;
