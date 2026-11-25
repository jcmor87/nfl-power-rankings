-- Read-only. Every check must pass.
select 'Mail migration recorded' as check_name, exists (
  select 1 from supabase_migrations.schema_migrations
  where version='20261125000800' and name='pickem_mail_automation'
) as passed
union all
select 'Service-only mail APIs owned by the table owner with empty search paths', (
  select count(*)=2 and coalesce(bool_and(p.prosecdef and 'search_path=""'=any(p.proconfig)
    and p.proowner=(select relowner from pg_class where oid='public.email_log'::regclass)
    and not has_function_privilege('anon',p.oid,'EXECUTE')
    and not has_function_privilege('authenticated',p.oid,'EXECUTE')
    and has_function_privilege('service_role',p.oid,'EXECUTE')),false)
  from pg_proc p where p.oid in (to_regprocedure('public.pickem_mail_work()'),
    to_regprocedure('public.claim_pickem_mail_job(bigint,uuid,text,timestamptz)'))
)
union all
select 'Private mail scheduling helpers are inaccessible to participant roles', (
  select count(*)=2 and coalesce(bool_and(not has_function_privilege('anon',p.oid,'EXECUTE')
    and not has_function_privilege('authenticated',p.oid,'EXECUTE')),false)
  from pg_proc p where p.oid in (to_regprocedure('pickem_private.pickem_reminder_window(timestamptz)'),
    to_regprocedure('pickem_private.pickem_mail_ready(bigint,text,timestamptz)'))
)
union all
select 'Email ledger has protected tracking columns and RLS', (
  select relrowsecurity and not has_table_privilege('anon',oid,'SELECT')
    and not has_table_privilege('authenticated',oid,'SELECT')
    and has_table_privilege('service_role',oid,'SELECT') and has_table_privilege('service_role',oid,'UPDATE')
    and exists (select 1 from pg_constraint where conrelid=pg_class.oid
      and conname='email_log_delivery_status_check' and convalidated)
    and (select count(*)=2 from pg_attribute where attrelid=pg_class.oid and not attisdropped
      and (attname='delivery_status' and atttypid='text'::regtype
        or attname='delivery_checked_at' and atttypid='timestamptz'::regtype))
  from pg_class where oid='public.email_log'::regclass
);
