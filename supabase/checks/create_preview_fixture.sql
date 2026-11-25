-- Run the entire file in one Supabase SQL Editor query as postgres.
-- Only the private browser fixture is written. Keep automated sync disabled.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local timezone = 'UTC';

lock table public.participants, public.seasons, public.weeks, public.teams, public.games,
  public.picks, public.weekly_results, public.season_standings, public.email_log,
  public.job_runs, public.audit_log in share row exclusive mode;

do $$
declare
  fixture_source constant text := 'pickem-browser-preview-v1';
  marker constant text := 'pickem_browser_preview_v1';
  base_time timestamptz := clock_timestamp();
  season_key bigint;
  week_key bigint;
  team_keys bigint[];
  game_keys bigint[];
  test_ids uuid[];
  baseline jsonb := '{}'::jsonb;
  relation_name text;
  digest text;
begin
  select array_agg(p.id order by p.seat) into test_ids
  from public.participants p join auth.users u on u.id = p.auth_user_id
  where p.active and ((p.seat = 1 and u.email = 'pickem-test1@example.com')
                   or (p.seat = 2 and u.email = 'pickem-test2@example.com'));
  if cardinality(test_ids) is distinct from 2
     or (select count(*) from public.participants where active) <> 2 then
    raise exception 'Browser fixture requires the two approved temporary accounts to be the only active participants';
  end if;
  if exists (select 1 from public.weeks where status = 'active') then
    raise exception 'Browser fixture requires no other active competition period';
  end if;
  if exists (select 1 from public.seasons where nfl_year = 2999)
     or exists (select 1 from public.games where source = fixture_source)
     or exists (select 1 from public.teams where abbreviation in
       ('SYN-PH','SYN-PA','SYN-BH','SYN-BA','SYN-LH','SYN-LA'))
     or exists (select 1 from public.audit_log where action = marker) then
    raise exception 'A browser fixture or reserved fixture identity already exists';
  end if;

  -- Snapshot every existing row as a digest. No private row payload is retained.
  foreach relation_name in array array['participants','seasons','weeks','teams','games','picks',
    'weekly_results','season_standings','email_log','job_runs','audit_log'] loop
    execute format(
      'select md5(coalesce(string_agg(to_jsonb(t)::text, chr(10) order by to_jsonb(t)::text collate "C"), '''')) from public.%I t',
      relation_name) into digest;
    baseline := baseline || jsonb_build_object(relation_name, digest);
  end loop;

  insert into public.seasons (nfl_year) values (2999) returning id into season_key;
  insert into public.weeks (season_id, competition_phase, week_number, status, expected_games)
    values (season_key, 'regular', 1, 'active', 3) returning id into week_key;
  with new_teams as (
    insert into public.teams (abbreviation, name) values
      ('SYN-PH','Synthetic Persistence Home'), ('SYN-PA','Synthetic Persistence Away'),
      ('SYN-BH','Synthetic Boundary Home'), ('SYN-BA','Synthetic Boundary Away'),
      ('SYN-LH','Synthetic Locked Home'), ('SYN-LA','Synthetic Locked Away')
    returning id, abbreviation
  )
  select array_agg(id order by array_position(
    array['SYN-PH','SYN-PA','SYN-BH','SYN-BA','SYN-LH','SYN-LA'], abbreviation))
  into team_keys from new_teams;

  with new_games as (
    insert into public.games (week_id, home_team_id, away_team_id, source, source_game_id,
      reference_game_id, kickoff_at, reference_kickoff_at, schedule_verified_until, provider_updated_at, status)
    select week_key, f.home, f.away, fixture_source, f.game_key,
      fixture_source || ':' || f.game_key, f.deadline, f.deadline, base_time + interval '2 hours',
      base_time, 'scheduled'
    from (values
      ('persistence', team_keys[1], team_keys[2], base_time + interval '90 minutes'),
      ('boundary', team_keys[3], team_keys[4], base_time + interval '20 minutes'),
      ('locked', team_keys[5], team_keys[6], base_time - interval '1 minute')
    ) f(game_key,home,away,deadline)
    returning id
  )
  select array_agg(id order by id) into game_keys from new_games;

  insert into public.audit_log(action, details) values (marker, jsonb_build_object(
    'baseline', baseline, 'season_id', season_key, 'week_id', week_key,
    'team_ids', team_keys, 'game_ids', game_keys, 'participant_ids', test_ids
  ));
end;
$$;

select 'Browser fixture created. Use 2999 · Week 1 in the private preview.' as result;
commit;
