-- Run after installing Phase 4 in a disposable Supabase-compatible database.
begin;

do $$
declare
  directory jsonb;
  regular jsonb;
  playoff jsonb;
  schedule jsonb;
  game_id bigint;
  period_id bigint;
  playoff_id bigint;
  season_key bigint;
  home_team bigint;
  away_team bigint;
  participant_ids uuid[] := array[]::uuid[];
  auth_ids uuid[] := array[]::uuid[];
  user_id uuid;
  participant_id uuid;
  i integer;
  past timestamptz := clock_timestamp() - interval '2 hours';
  future timestamptz := clock_timestamp() + interval '2 days';
  updates_before integer;
begin
  select jsonb_agg(jsonb_build_object('code',code,'name','Synthetic ' || code,'providerId',n) order by n)
  into directory
  from unnest(string_to_array('ARI ATL BAL BUF CAR CHI CIN CLE DAL DEN DET GB HOU IND JAX KC LA LAC LV MIA MIN NE NO NYG NYJ PHI PIT SEA SF TB TEN WAS',' '))
    with ordinality as t(code,n);

  select jsonb_agg(jsonb_build_object('provider_id', (100+idx)::text, 'reference_id', 'fixture-'||idx,
    'home',directory->(idx*2)->>'code','away',directory->(idx*2+1)->>'code',
    'status','scheduled','kickoff_at',future,'observed_at',past) order by idx)
  into schedule from generate_series(0,2) idx;
  regular := jsonb_build_object('season',2999,'phase','regular','week',1,'teams',directory,'games',schedule);
  perform public.sync_pickem_nfl_week(regular);
  select count(*) into updates_before from public.audit_log;
  perform public.sync_pickem_nfl_week(regular);
  assert (select count(*) from public.games) = 3;
  assert (select count(*) from public.teams) = 32;
  assert (select count(*) from public.audit_log) = updates_before;
  select w.id,w.season_id into period_id,season_key from public.weeks w where w.competition_phase='regular';
  assert (select status from public.weeks where id=period_id) = 'planned';

  begin
    perform public.sync_pickem_nfl_week(jsonb_set(regular,'{games}',schedule - 2));
    raise exception 'Incomplete snapshot accepted' using errcode='XX000';
  exception when raise_exception then null;
  end;
  begin
    perform public.sync_pickem_nfl_week(jsonb_set(regular,'{games,1,provider_id}','"100"'));
    raise exception 'Duplicate ID accepted' using errcode='XX000';
  exception when raise_exception then null;
  end;

  select jsonb_agg(jsonb_build_object('provider_id',(200+idx)::text,'reference_id','playoff-'||idx,
    'home',directory->(idx*2)->>'code','away',directory->(idx*2+1)->>'code',
    'status','scheduled','kickoff_at',future,'observed_at',past) order by idx)
  into schedule from generate_series(0,5) idx;
  playoff := jsonb_build_object('season',2999,'phase','postseason','week',1,'teams',directory,'games',schedule);
  perform public.sync_pickem_nfl_week(playoff);
  select id into playoff_id from public.weeks where competition_phase='postseason';
  assert playoff_id <> period_id;
  assert (select status from public.weeks where id=playoff_id) = 'planned';

  for i in 1..5 loop
    user_id := gen_random_uuid();
    insert into auth.users(id) values (user_id);
    insert into public.participants(auth_user_id,display_name,seat,active)
      values (user_id,'Synthetic '||i,i,true) returning id into participant_id;
    participant_ids := array_append(participant_ids,participant_id);
    auth_ids := array_append(auth_ids,user_id);
  end loop;
  select id,home_team_id,away_team_id into game_id,home_team,away_team
    from public.games where source_game_id='100';
  update public.weeks set status='active' where id=period_id;

  perform public.invalidate_pickem_nfl_week(2999,'regular',1);
  perform set_config('request.jwt.claim.sub',auth_ids[1]::text,true);
  execute 'set local role authenticated';
  begin
    perform public.submit_pick(game_id,home_team);
    raise exception 'Accepted stale schedule pick' using errcode='XX000';
  exception when invalid_parameter_value then null;
  end;
  execute 'reset role';
  perform public.sync_pickem_nfl_week(regular);

  for i in 1..3 loop
    perform set_config('request.jwt.claim.sub',auth_ids[i]::text,true);
    execute 'set local role authenticated';
    perform public.submit_pick(game_id,case when i=3 then away_team else home_team end);
    assert (select count(*) from public.picks) = 1;
    execute 'reset role';
  end loop;

  update public.games set kickoff_at=past where id=game_id;
  regular := jsonb_set(regular,'{games,0}',regular#>'{games,0}' ||
    jsonb_build_object('status','postponed','kickoff_at',null,'observed_at',past + interval '10 minutes'));
  perform public.sync_pickem_nfl_week(regular);
  assert (select status from public.games where id=game_id) = 'postponed';
  regular := jsonb_set(regular,'{games,0}',regular#>'{games,0}' ||
    jsonb_build_object('status','scheduled','kickoff_at',future,'observed_at',past + interval '20 minutes'));
  perform public.sync_pickem_nfl_week(regular);
  assert (select id from public.games where source_game_id='100') = game_id;
  assert (select picks_locked_at from public.games where id=game_id) is not null;
  execute 'set local role authenticated';
  begin
    perform public.submit_pick(game_id,home_team);
    raise exception 'Reschedule reopened an expired game' using errcode='XX000';
  exception when invalid_parameter_value then null;
  end;
  execute 'reset role';

  regular := jsonb_set(regular,'{games,0}',regular#>'{games,0}' ||
    jsonb_build_object('status','final','kickoff_at',past,'observed_at',past + interval '30 minutes','home_score',14,'away_score',7));
  regular := jsonb_set(regular,'{games,1}',regular#>'{games,1}' ||
    jsonb_build_object('status','final','kickoff_at',past,'observed_at',past + interval '30 minutes','home_score',7,'away_score',7));
  regular := jsonb_set(regular,'{games,2}',regular#>'{games,2}' ||
    jsonb_build_object('status','canceled','kickoff_at',null,'observed_at',past + interval '30 minutes'));
  perform public.sync_pickem_nfl_week(regular);
  assert (select status from public.weeks where id=period_id) = 'complete';
  assert (select count(*) from public.weekly_results where week_id=period_id and points=1 and rank=1) = 2;
  assert (select count(*) from public.weekly_results where week_id=period_id and points=0 and eligible_games=2) = 3;
  assert (select count(*) from public.games where cancellation_verified_at is not null) = 1;
  execute 'set local role authenticated';
  assert (select count(*) from public.picks) = 3;
  execute 'reset role';

  regular := jsonb_set(regular,'{games,0}',regular#>'{games,0}' ||
    jsonb_build_object('observed_at',past + interval '40 minutes','home_score',6));
  perform public.sync_pickem_nfl_week(regular);
  perform public.sync_pickem_nfl_week(regular);
  begin
    perform public.sync_pickem_nfl_week(jsonb_set(regular,'{games,0,observed_at}',to_jsonb(past)));
    raise exception 'Stale provider observation accepted' using errcode='XX000';
  exception when raise_exception then null;
  end;
  begin
    perform public.sync_pickem_nfl_week(jsonb_set(regular,'{games,0,provider_id}','"900"'));
    raise exception 'Changed game identity accepted' using errcode='XX000';
  exception when raise_exception then null;
  end;
  assert (select count(*) from public.audit_log where action='nfl_score_correction') = 1;
  assert (select points from public.season_standings standings where season_id=season_key
    and standings.participant_id=participant_ids[3]) = 1;

  update public.weeks set status='active' where id=playoff_id;
  select id,home_team_id into game_id,home_team from public.games where source_game_id='200';
  perform set_config('request.jwt.claim.sub',auth_ids[3]::text,true);
  execute 'set local role authenticated';
  perform public.submit_pick(game_id,home_team);
  execute 'reset role';
  for i in 0..5 loop
    playoff := jsonb_set(playoff,array['games',i::text],playoff#>array['games',i::text] ||
      jsonb_build_object('status','final','kickoff_at',past,'observed_at',past + interval '30 minutes','home_score',14,'away_score',7));
  end loop;
  perform public.sync_pickem_nfl_week(playoff);
  assert (select points from public.season_standings standings where season_id=season_key
    and standings.participant_id=participant_ids[3]) = 2;

  assert not has_function_privilege('anon','public.sync_pickem_nfl_week(jsonb)','EXECUTE');
  assert not has_function_privilege('authenticated','public.sync_pickem_nfl_week(jsonb)','EXECUTE');
  assert has_function_privilege('service_role','public.sync_pickem_nfl_week(jsonb)','EXECUTE');
  assert not has_table_privilege('service_role','public.games','TRUNCATE,TRIGGER,REFERENCES');
end;
$$;

rollback;
