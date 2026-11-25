-- For the private visual check after the automated test and before fixture cleanup.
begin;
do $$
declare
  season_key bigint;
  week_key bigint;
  home bigint;
  away bigint;
  third bigint;
  fixture_source text := 'synthetic-' || gen_random_uuid();
begin
  if (select count(*) from public.participants p join auth.users u on u.id = p.auth_user_id
      where p.active and ((p.seat = 1 and u.email = 'pickem-test1@example.com')
         or (p.seat = 2 and u.email = 'pickem-test2@example.com'))) <> 2
    or (select count(*) from public.participants) <> 2
    or exists (select 1 from public.seasons)
    or exists (select 1 from public.teams) then
    raise exception 'Expected only the two active temporary accounts and no competition data';
  end if;

  insert into public.seasons (nfl_year) values (2999) returning id into season_key;
  insert into public.weeks (season_id, week_number, status, expected_games)
    values (season_key, 1, 'active', 2) returning id into week_key;
  insert into public.teams (abbreviation, name) values ('SYN-A','Synthetic Home') returning id into home;
  insert into public.teams (abbreviation, name) values ('SYN-B','Synthetic Away') returning id into away;
  insert into public.teams (abbreviation, name) values ('SYN-C','Synthetic Third') returning id into third;
  insert into public.games (week_id, home_team_id, away_team_id, source, source_game_id, kickoff_at, status)
    values (week_key, home, away, fixture_source, 'privacy', clock_timestamp() + interval '45 minutes', 'scheduled'),
      (week_key, home, third, fixture_source, 'boundary', clock_timestamp() - interval '1 minute', 'scheduled');
end;
$$;
commit;
