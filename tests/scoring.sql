-- Run against a disposable migrated PostgreSQL/Supabase database as owner.
begin;

do $$
declare
  season_key bigint;
  first_week bigint;
  second_week bigint;
  home bigint;
  away bigint;
  other bigint;
  last_game bigint;
  first_game bigint;
  roster uuid[] := array[]::uuid[];
  auth_id uuid;
  participant uuid;
  claim uuid;
  i integer;
begin
  for i in 1..5 loop
    auth_id := gen_random_uuid();
    insert into auth.users (id) values (auth_id);
    insert into public.participants (auth_user_id, display_name, seat, active)
    values (auth_id, 'SQL fixture ' || i, i, true) returning id into participant;
    roster := array_append(roster, participant);
  end loop;
  insert into public.seasons (nfl_year) values (2998) returning id into season_key;
  insert into public.weeks (season_id, week_number, status, expected_games)
    values (season_key, 1, 'active', 3) returning id into first_week;
  insert into public.weeks (season_id, week_number, status, expected_games)
    values (season_key, 2, 'active', 1) returning id into second_week;
  insert into public.teams (abbreviation, name) values ('TST-H', 'Home') returning id into home;
  insert into public.teams (abbreviation, name) values ('TST-A', 'Away') returning id into away;
  insert into public.teams (abbreviation, name) values ('TST-C', 'Other') returning id into other;

  insert into public.games (week_id, home_team_id, away_team_id, source, source_game_id,
    status, home_score, away_score, started_at, final_verified_at)
  values (first_week, home, away, 'scoring-fixture','win','final', 14, 7, now(), now())
  returning id into first_game;
  insert into public.games (week_id, home_team_id, away_team_id, source, source_game_id,
    status, home_score, away_score, started_at, final_verified_at)
  values (first_week, home, other, 'scoring-fixture','tie','final', 7, 7, now(), now());
  insert into public.games (week_id, home_team_id, away_team_id, source, source_game_id, status)
  values (first_week, away, other, 'scoring-fixture','cancellation','postponed') returning id into last_game;

  insert into public.picks (participant_id, game_id, team_id, updated_at)
  values (roster[1], first_game, home, now()), (roster[2], first_game, home, now()),
    (roster[3], first_game, away, now());
  begin
    perform public.recalculate_pickem_week(first_week);
    raise exception 'Allowed scoring with postponement' using errcode = 'XX000';
  exception when raise_exception then null;
  end;
  assert public.claim_pickem_email(first_week, roster[1], 'results') is null;
  update public.games set status = 'canceled', cancellation_verified_at = now() where id = last_game;
  perform public.recalculate_pickem_week(first_week);
  perform public.recalculate_pickem_week(first_week);
  assert (select count(*) from public.weekly_results where week_id = first_week and rank = 1 and points = 1) = 2;
  assert (select count(*) from public.weekly_results where week_id = first_week and eligible_games = 2 and points = 0) = 3;

  insert into public.games (week_id, home_team_id, away_team_id, source, source_game_id,
    status, home_score, away_score, started_at, final_verified_at)
  values (second_week, home, away, 'scoring-fixture','second','final', 14, 7, now(), now())
  returning id into last_game;
  insert into public.picks (participant_id, game_id, team_id, updated_at)
  values (roster[1], last_game, home, now());
  perform public.recalculate_pickem_week(second_week);
  assert (select points from public.season_standings where season_id = season_key and participant_id = roster[1]) = 2;
  update public.games set home_score = 6 where id = first_game;
  perform public.recalculate_pickem_week(first_week);
  assert (select points from public.season_standings where season_id = season_key and participant_id = roster[1]) = 1;
  assert (select points from public.season_standings where season_id = season_key and participant_id = roster[3]) = 1;

  claim := public.claim_pickem_email(first_week, roster[1], 'results');
  assert claim is not null;
  assert public.claim_pickem_email(first_week, roster[1], 'results') is null;
  assert not public.finish_pickem_email(claim, 'accepted', null);
  assert public.finish_pickem_email(claim, 'failed', null);
  assert public.claim_pickem_email(first_week, roster[1], 'results') is null;
  update public.email_log set updated_at = now() - interval '16 minutes' where claim_token = claim;
  claim := public.claim_pickem_email(first_week, roster[1], 'results');
  assert claim is not null;
  assert public.finish_pickem_email(claim, 'ambiguous', null);
  assert public.claim_pickem_email(first_week, roster[1], 'results') is null;
end;
$$;

rollback;
