-- Run only in a disposable migrated database as owner.
begin;
do $$
declare
  season_key bigint;
  week_key bigint;
  historical bigint;
  home bigint;
  away bigint;
  game bigint;
  cancellation bigint;
  roster uuid[] := '{}';
  participant uuid;
  work jsonb;
  claim uuid;
  revision timestamptz;
begin
  assert not pickem_private.pickem_reminder_window('2026-03-04 19:59:59Z');
  assert pickem_private.pickem_reminder_window('2026-03-04 20:00:00Z');
  assert not pickem_private.pickem_reminder_window('2026-03-11 18:59:59Z');
  assert pickem_private.pickem_reminder_window('2026-03-11 19:00:00Z');
  assert pickem_private.pickem_reminder_window('2026-10-28 19:00:00Z');
  assert not pickem_private.pickem_reminder_window('2026-11-04 19:00:00Z');
  assert pickem_private.pickem_reminder_window('2026-11-04 20:00:00Z');
  assert not pickem_private.pickem_reminder_window('2026-11-05 20:00:00Z');
  assert not has_function_privilege('authenticated','public.pickem_mail_work()','execute');
  assert not has_function_privilege('anon','public.pickem_mail_work()','execute');

  for i in 1..5 loop
    insert into auth.users (id,email,email_confirmed_at)
    values (gen_random_uuid(), 'mail-test-' || i || '@example.invalid', now()) returning id into participant;
    insert into public.participants (auth_user_id,display_name,seat,active)
    values (participant, 'Synthetic participant ' || i, i, true) returning id into participant;
    roster := array_append(roster,participant);
  end loop;
  insert into public.seasons (nfl_year) values (2026) returning id into season_key;
  insert into public.weeks (season_id,competition_phase,week_number,status,expected_games)
  values (season_key,'postseason',5,'active',2) returning id into week_key;
  insert into public.weeks (season_id,competition_phase,week_number,status,expected_games)
  values (season_key,'regular',12,'active',1) returning id into historical;
  insert into public.teams (abbreviation,name) values ('MH','Mail Home') returning id into home;
  insert into public.teams (abbreviation,name) values ('MA','Mail Away') returning id into away;
  insert into public.games (week_id,home_team_id,away_team_id,source,source_game_id,status,
    home_score,away_score,started_at,final_verified_at)
  values (week_key,home,away,'mail-fixture','final','final',24,21,now(),now()) returning id into game;
  insert into public.games (week_id,home_team_id,away_team_id,source,source_game_id,status)
  values (week_key,away,home,'mail-fixture','postponed','postponed') returning id into cancellation;
  insert into public.games (week_id,home_team_id,away_team_id,source,source_game_id,status,
    home_score,away_score,started_at,final_verified_at)
  values (historical,home,away,'mail-fixture','historical','final',7,0,now(),now());
  perform public.recalculate_pickem_week(historical);
  assert public.pickem_mail_work()='[]'::jsonb;
  assert public.claim_pickem_mail_job(week_key,roster[1],'results',null) is null;
  insert into public.picks (participant_id,game_id,team_id,updated_at) values (roster[1],game,home,now()),(roster[2],game,home,now());
  update public.games set status='canceled',cancellation_verified_at=now() where id=cancellation;
  assert public.pickem_mail_work()='[]'::jsonb;
  perform public.recalculate_pickem_week(week_key);

  work := public.pickem_mail_work();
  assert jsonb_array_length(work)=1;
  assert work#>>'{0,phase}'='postseason' and work#>>'{0,week}'='5';
  assert work#>>'{0,gameCount}'='1' and jsonb_array_length(work#>'{0,finals}')=1;
  assert jsonb_array_length(work#>'{0,recipients}')=5;
  assert jsonb_array_length(work#>'{0,history}')=5;
  revision := (work#>>'{0,revision}')::timestamptz;
  assert public.claim_pickem_mail_job(week_key,roster[1],'results',revision-interval '1 second') is null;
  update auth.users set email_confirmed_at=null where id=(select auth_user_id from public.participants where id=roster[1]);
  assert public.claim_pickem_mail_job(week_key,roster[1],'results',revision) is null;
  update auth.users set email_confirmed_at=now() where id=(select auth_user_id from public.participants where id=roster[1]);
  claim := public.claim_pickem_mail_job(week_key,roster[1],'results',revision);
  assert claim is not null;
  assert public.claim_pickem_mail_job(week_key,roster[1],'results',revision) is null;
  assert public.finish_pickem_email(claim,'ambiguous',null);
  assert public.claim_pickem_mail_job(week_key,roster[1],'results',revision) is null;
end;
$$;
rollback;
