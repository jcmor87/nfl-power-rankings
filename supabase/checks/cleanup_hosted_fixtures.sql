-- Optional recovery after the automated test cleanup, before any real enrollment.
-- Auth users remain for deletion in the Dashboard once this transaction succeeds.
begin;
set local lock_timeout = '5s';

do $$
declare
  test_ids uuid[];
  fixture_season bigint;
begin
  if exists (select 1 from public.seasons where nfl_year <> 2999) then
    raise exception 'Cleanup refused because another season exists';
  end if;
  select array_agg(p.id) into test_ids
  from public.participants p join auth.users u on u.id = p.auth_user_id
  where (p.seat = 1 and u.email = 'pickem-test1@example.com')
     or (p.seat = 2 and u.email = 'pickem-test2@example.com');

  if exists (select 1 from public.participants where not coalesce(id = any(test_ids), false)) then
    raise exception 'Cleanup refused because another participant exists';
  end if;

  select id into fixture_season from public.seasons where nfl_year = 2999;
  if exists (
    select 1 from public.games g join public.weeks w on w.id = g.week_id
    where w.season_id = fixture_season and
      (g.source !~ '^synthetic-[0-9a-f-]{36}$' or g.source_game_id not in ('privacy', 'boundary'))
  ) then raise exception 'Unexpected games in synthetic season'; end if;

  if exists (select 1 from public.weekly_results)
    or exists (select 1 from public.season_standings)
    or exists (select 1 from public.email_log)
    or exists (select 1 from public.audit_log)
    or exists (select 1 from public.job_runs) then
    raise exception 'Unexpected dependent records; review them before cleanup';
  end if;

  delete from public.picks p using public.games g, public.weeks w
  where p.game_id = g.id and g.week_id = w.id and w.season_id = fixture_season
    and p.participant_id = any(test_ids);
  delete from public.games g using public.weeks w where g.week_id = w.id and w.season_id = fixture_season;
  delete from public.weeks where season_id = fixture_season and week_number = 1;
  delete from public.seasons where id = fixture_season;
  delete from public.teams where (abbreviation, name) in (
    ('SYN-A','Synthetic Home'), ('SYN-B','Synthetic Away'), ('SYN-C','Synthetic Third'));
  delete from public.participants where id = any(test_ids);
end;
$$;

commit;
