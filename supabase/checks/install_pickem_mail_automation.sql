-- Run as postgres in one Supabase SQL Editor query after the nine earlier migrations.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '45s';
set local search_path = pg_catalog, public;
select pg_advisory_xact_lock(20261124, 100);
do $baseline$
begin
  if not exists (select 1 from supabase_migrations.schema_migrations
    where version='20261125000700' and name='pickem_family_automation')
    or to_regprocedure('public.sync_pickem_family_period(jsonb)') is null
    or to_regprocedure('public.claim_pickem_email(bigint,uuid,text)') is null then
    raise exception 'Family automation and existing email claims must be installed';
  end if;
  if exists (select 1 from supabase_migrations.schema_migrations where version='20261125000800') then
    raise exception 'Mail automation migration already recorded';
  end if;
end;
$baseline$;

-- Begin 20261125000800_pickem_mail_automation.sql
alter table public.email_log
  add column delivery_status text check (delivery_status in ('delivered','bounced','blocked','unconfirmed')),
  add column delivery_checked_at timestamptz;

create function pickem_private.pickem_reminder_window(p_now timestamptz)
returns boolean language sql stable set search_path = ''
as $$
  select extract(isodow from p_now at time zone 'America/Los_Angeles') = 3
     and (p_now at time zone 'America/Los_Angeles')::time >= time '12:00'
$$;

create function pickem_private.pickem_mail_ready(p_week_id bigint, p_kind text, p_now timestamptz)
returns boolean language sql stable set search_path = ''
as $$
  select exists (
    select 1 from public.weeks w join public.seasons s on s.id = w.season_id
    where w.id = p_week_id and s.nfl_year = 2026 and
      ((w.competition_phase = 'regular' and w.week_number between 13 and 18)
        or (w.competition_phase = 'postseason' and w.week_number in (1,2,3,5)))
      and case p_kind
        when 'reminder' then w.status = 'active' and pickem_private.pickem_reminder_window(p_now)
          and exists (
            select 1 from public.games g where g.week_id = w.id and g.source = 'balldontlie'
              and g.status = 'scheduled' and g.started_at is null and g.picks_locked_at is null
              and g.reference_kickoff_at is not null and g.pick_deadline_at > p_now
              and g.schedule_verified_until > p_now
          )
        when 'results' then w.status = 'complete'
          and (select count(*) from public.weekly_results r where r.week_id = w.id) = 5
          and (select max(calculated_at) from public.weekly_results r where r.week_id = w.id) > p_now - interval '7 days'
          and (select count(*) from public.games g where g.week_id = w.id) = w.expected_games
          and not exists (select 1 from public.games g where g.week_id = w.id and not (
            (g.status = 'final' and g.final_verified_at is not null)
            or (g.status = 'canceled' and g.cancellation_verified_at is not null)
          ))
        else false end
  )
$$;

create function public.pickem_mail_work()
returns jsonb language sql stable security definer set search_path = ''
as $$
  with roster as (
    select p.id, p.display_name as name, u.email
    from public.participants p join auth.users u on u.id = p.auth_user_id
    where p.active and u.email_confirmed_at is not null and nullif(btrim(u.email),'') is not null
  ), target as (
    select w.*, k.kind
    from public.weeks w cross join (values ('reminder'),('results')) k(kind)
    where pickem_private.pickem_mail_ready(w.id,k.kind,statement_timestamp())
      and (select count(*) from public.email_log e where e.week_id=w.id
        and e.kind=k.kind and e.status='accepted') < 5
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'weekId',w.id,'week',w.week_number,'phase',w.competition_phase,'kind',w.kind,
    'revision',(select max(calculated_at) from public.weekly_results r where r.week_id=w.id),
    'gameCount',(select count(*) from public.games g where g.week_id=w.id and g.status <> 'canceled'),
    'recipients',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'email',r.email,
      'completed',(select count(*) from public.picks p join public.games g on g.id=p.game_id
        where p.participant_id=r.id and g.week_id=w.id and g.status <> 'canceled'),
      'deadline',(select min(g.pick_deadline_at) from public.games g where g.week_id=w.id and g.source='balldontlie'
        and g.status='scheduled' and g.started_at is null and g.picks_locked_at is null
        and g.reference_kickoff_at is not null and g.pick_deadline_at > statement_timestamp()
        and g.schedule_verified_until > statement_timestamp()
        and not exists (select 1 from public.picks p where p.game_id=g.id and p.participant_id=r.id)),
      'delivery',(select e.status from public.email_log e where e.week_id=w.id and e.kind=w.kind and e.participant_id=r.id),
      'attempts',coalesce((select e.attempts from public.email_log e where e.week_id=w.id and e.kind=w.kind and e.participant_id=r.id),0),
      'staleClaim',coalesce((select e.status='claimed' and e.updated_at < statement_timestamp()-interval '20 minutes'
        from public.email_log e where e.week_id=w.id and e.kind=w.kind and e.participant_id=r.id),false)
    ) order by r.name) from roster r),'[]'::jsonb),
    'history',case when w.kind='results' then coalesce((
      select jsonb_agg(jsonb_build_object('id',r.participant_id,'points',r.points,'weekId',h.id,'rank',r.rank,
        'order',h.week_number + case when h.competition_phase='postseason' then 18 else 0 end))
      from public.weekly_results r join public.weeks h on h.id=r.week_id
      where h.season_id=w.season_id and h.status='complete'
        and (h.competition_phase='postseason' or h.week_number>=13)
        and h.week_number + case when h.competition_phase='postseason' then 18 else 0 end
          <= w.week_number + case when w.competition_phase='postseason' then 18 else 0 end
    ),'[]'::jsonb) else '[]'::jsonb end,
    'finals',case when w.kind='results' then coalesce((
      select jsonb_agg(jsonb_build_object('home',ht.abbreviation,'away',at.abbreviation,
        'homeScore',g.home_score,'awayScore',g.away_score,
        'winner',case when g.home_score > g.away_score then g.home_team_id
          when g.away_score > g.home_score then g.away_team_id end,
        'picks',coalesce((select jsonb_object_agg(p.participant_id::text,p.team_id)
           from public.picks p where p.game_id=g.id),'{}'::jsonb)))
      from public.games g join public.teams ht on ht.id=g.home_team_id join public.teams at on at.id=g.away_team_id
      where g.week_id=w.id and g.status='final' and g.final_verified_at is not null
    ),'[]'::jsonb) else '[]'::jsonb end
  ) order by w.id,w.kind),'[]'::jsonb) from target w
$$;

create function public.claim_pickem_mail_job(p_week_id bigint, p_participant_id uuid, p_kind text, p_revision timestamptz)
returns uuid language plpgsql security definer set search_path = ''
as $$
begin
  perform 1 from public.games where week_id=p_week_id order by id for share;
  perform 1 from public.weeks where id=p_week_id for share;
  if not found or not pickem_private.pickem_mail_ready(p_week_id,p_kind,clock_timestamp())
    or (select count(*) from public.participants p join auth.users u on u.id=p.auth_user_id
       where p.active and u.email_confirmed_at is not null and nullif(btrim(u.email),'') is not null) <> 5
    or not exists (select 1 from public.participants p join auth.users u on u.id=p.auth_user_id
       where p.id=p_participant_id and p.active and u.email_confirmed_at is not null
         and nullif(btrim(u.email),'') is not null)
    or (p_kind='results' and p_revision is distinct from (
      select max(calculated_at) from public.weekly_results where week_id=p_week_id
    )) then return null; end if;
  return public.claim_pickem_email(p_week_id,p_participant_id,p_kind);
end;
$$;

revoke all on function pickem_private.pickem_reminder_window(timestamptz),
  pickem_private.pickem_mail_ready(bigint,text,timestamptz) from public, anon, authenticated;
revoke all on function public.pickem_mail_work(), public.claim_pickem_mail_job(bigint,uuid,text,timestamptz)
  from public, anon, authenticated;
grant execute on function public.pickem_mail_work(), public.claim_pickem_mail_job(bigint,uuid,text,timestamptz)
  to service_role;
-- End 20261125000800_pickem_mail_automation.sql

insert into supabase_migrations.schema_migrations(version,name)
values ('20261125000800','pickem_mail_automation');

do $installed$
begin
  if exists (
    select 1 from (
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
      )
    ) checks where passed is distinct from true
  ) then
    raise exception 'Mail automation verification failed';
  end if;
end;
$installed$;
notify pgrst, 'reload schema';
commit;
