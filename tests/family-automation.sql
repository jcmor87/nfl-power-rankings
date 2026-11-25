-- Disposable database, with all migrations installed.
begin;
do $$
declare
  directory jsonb;
  snapshot jsonb;
  opening jsonb;
  postseason jsonb;
  future timestamptz := clock_timestamp() + interval '2 days';
  participant uuid;
  member integer;
begin
  select jsonb_agg(jsonb_build_object('code',code,'name','Synthetic '||code,'providerId',n) order by n)
  into directory
  from unnest(string_to_array('ARI ATL BAL BUF CAR CHI CIN CLE DAL DEN DET GB HOU IND JAX KC LA LAC LV MIA MIN NE NO NYG NYJ PHI PIT SEA SF TB TEN WAS',' '))
    with ordinality as t(code,n);
  snapshot := jsonb_build_object('season',2026,'phase','regular','week',14,'teams',directory,'games',
    jsonb_build_array(jsonb_build_object('provider_id','140','reference_id','fixture-14','home','ARI','away','ATL',
      'status','scheduled','kickoff_at',future,'reference_kickoff_at',future,'observed_at',now())));
  opening := jsonb_set(snapshot,'{week}','13');
  opening := jsonb_set(opening,'{games,0,provider_id}','"130"');
  opening := jsonb_set(opening,'{games,0,reference_id}','"fixture-13"');

  begin
    perform public.sync_pickem_family_period(jsonb_set(snapshot,'{week}','12'));
    raise exception 'Pre-start week was accepted' using errcode='XX000';
  exception when raise_exception then null;
  end;
  assert not exists (select 1 from public.weeks where week_number=12);

  for member in 1..4 loop
    participant := gen_random_uuid();
    insert into auth.users(id) values (participant);
    insert into public.participants(auth_user_id,display_name,seat,active)
      values(participant,'Synthetic '||member,member,true);
  end loop;
  perform public.sync_pickem_family_period(opening);
  assert (select status from public.weeks where week_number=13) = 'planned';

  participant := gen_random_uuid();
  insert into auth.users(id) values (participant);
  insert into public.participants(auth_user_id,display_name,seat,active)
    values(participant,'Synthetic 5',5,true);

  perform public.sync_pickem_family_period(snapshot);
  assert (select status from public.weeks where week_number=14) = 'planned';
  perform public.sync_pickem_family_period(opening);
  assert (select status from public.weeks where week_number=13) = 'active';
  perform public.sync_pickem_family_period(snapshot);
  assert (select status from public.weeks where week_number=14) = 'active';

  postseason := jsonb_set(jsonb_set(snapshot,'{phase}','"postseason"'),'{week}','5');
  postseason := jsonb_set(postseason,'{games,0}',postseason#>'{games,0}' ||
    jsonb_build_object('reference_id','fixture-super-bowl','provider_id','500'));
  perform public.sync_pickem_family_period(postseason);
  assert (select status from public.weeks where competition_phase='postseason' and week_number=5) = 'active';

  snapshot := jsonb_set(snapshot,'{week}','15');
  snapshot := jsonb_set(snapshot,'{games,0}',snapshot#>'{games,0}' ||
    jsonb_build_object('reference_id','fixture-15','provider_id','150',
      'kickoff_at',now()-interval '1 hour','reference_kickoff_at',now()-interval '1 hour'));
  perform public.sync_pickem_family_period(snapshot);
  assert (select status from public.weeks where week_number=15) = 'planned';
  assert not has_function_privilege('anon','public.sync_pickem_family_period(jsonb)','EXECUTE');
  assert not has_function_privilege('authenticated','public.sync_pickem_family_period(jsonb)','EXECUTE');
  assert has_function_privilege('service_role','public.sync_pickem_family_period(jsonb)','EXECUTE');
end;
$$;
rollback;
