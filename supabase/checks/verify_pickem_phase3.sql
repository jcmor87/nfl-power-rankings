-- Read-only verification after installing Phase 3.
-- For required checks, passed must be true. For service privilege findings,
-- privilege_present reports effective access and does not affect installation.
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
select 'required check' as result_type, check_name, passed,
  null::boolean as privilege_present
from checks
union all
select 'service privilege', 'service_role ' || p.name || ' · ' || t.name, null::boolean,
  case when p.name = 'REFERENCES' then has_any_column_privilege('service_role', t.oid, p.name)
       else has_table_privilege('service_role', t.oid, p.name) end
from tables t
cross join (values ('TRUNCATE'), ('TRIGGER'), ('REFERENCES')) p(name)
order by result_type, check_name;
