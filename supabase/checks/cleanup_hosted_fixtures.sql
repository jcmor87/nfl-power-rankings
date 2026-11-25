-- Removes only the browser fixture created by create_preview_fixture.sql.
-- The preexisting temporary participant links and Auth accounts are preserved.
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
  fixture public.audit_log;
  season_key bigint;
  week_key bigint;
  team_keys bigint[];
  game_keys bigint[];
  test_ids uuid[];
  baseline jsonb := '{}'::jsonb;
  relation_name text;
  digest text;
  changed_tables text;
begin
  select * into strict fixture from public.audit_log where action = marker;
  season_key := (fixture.details->>'season_id')::bigint;
  week_key := (fixture.details->>'week_id')::bigint;
  select array_agg(value::bigint) into team_keys from jsonb_array_elements_text(fixture.details->'team_ids');
  select array_agg(value::bigint) into game_keys from jsonb_array_elements_text(fixture.details->'game_ids');
  select array_agg(value::uuid) into test_ids from jsonb_array_elements_text(fixture.details->'participant_ids');
  if cardinality(team_keys) is distinct from 6 or cardinality(game_keys) is distinct from 3
     or cardinality(test_ids) is distinct from 2
     or not exists (select 1 from public.seasons where id = season_key and nfl_year = 2999)
     or not exists (select 1 from public.weeks where id = week_key and season_id = season_key
                    and competition_phase = 'regular' and week_number = 1)
     or (select count(*) from public.teams where id = any(team_keys) and abbreviation in
       ('SYN-PH','SYN-PA','SYN-BH','SYN-BA','SYN-LH','SYN-LA') and name like 'Synthetic %') <> 6
     or (select count(*) from public.games where id = any(game_keys) and week_id = week_key
          and source = fixture_source and source_game_id in ('persistence','boundary','locked')
          and reference_game_id = fixture_source || ':' || source_game_id
          and home_team_id = any(team_keys) and away_team_id = any(team_keys)) <> 3
     or exists (select 1 from public.picks where game_id = any(game_keys)
                and not (participant_id = any(test_ids))) then
    raise exception 'Cleanup refused because the recorded browser fixture identities do not match';
  end if;

  -- Foreign keys reject cleanup if unanticipated related records exist.
  delete from public.picks where game_id = any(game_keys) and participant_id = any(test_ids);
  delete from public.games where id = any(game_keys) and source = fixture_source;
  delete from public.weeks where id = week_key and season_id = season_key;
  delete from public.seasons where id = season_key and nfl_year = 2999;
  delete from public.teams where id = any(team_keys);
  delete from public.audit_log where id = fixture.id and action = marker;

  foreach relation_name in array array['participants','seasons','weeks','teams','games','picks',
    'weekly_results','season_standings','email_log','job_runs','audit_log'] loop
    execute format(
      'select md5(coalesce(string_agg(to_jsonb(t)::text, chr(10) order by to_jsonb(t)::text collate "C"), '''')) from public.%I t',
      relation_name) into digest;
    baseline := baseline || jsonb_build_object(relation_name, digest);
  end loop;
  if baseline is distinct from fixture.details->'baseline' then
    select string_agg(key, ', ' order by key) into changed_tables
    from jsonb_each(baseline) where value is distinct from fixture.details->'baseline'->key;
    raise exception 'Cleanup rolled back because preexisting row digests differ in: %', changed_tables;
  end if;
end;
$$;

select 'Browser fixture removed. Existing competition rows and participant links verified unchanged.' as result;
commit;
