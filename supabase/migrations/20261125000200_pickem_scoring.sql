grant select on public.weekly_results, public.season_standings to authenticated;
create policy weekly_results_read on public.weekly_results for select to authenticated
  using ((select pickem_private.active_participant_id()) is not null);
create policy season_standings_read on public.season_standings for select to authenticated
  using ((select pickem_private.active_participant_id()) is not null);

create function public.recalculate_pickem_week(p_week_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  season_key bigint;
  target_week public.weeks;
  count_games integer;
  all_terminal boolean;
  roster uuid[];
begin
  select season_id into season_key from public.weeks where id = p_week_id;
  if not found then raise exception 'Unknown week'; end if;

  -- Serialize scoring for the season. Lock games before the week, as submit_pick does.
  perform 1 from public.seasons where id = season_key for no key update;
  perform 1 from public.games where week_id = p_week_id order by id for share;
  select * into target_week from public.weeks where id = p_week_id for update;
  if target_week.status not in ('active', 'complete')
     or target_week.season_id is distinct from season_key then
    raise exception 'Week is not eligible for scoring';
  end if;

  select count(*), bool_and(
    (status = 'final' and final_verified_at is not null)
    or (status = 'canceled' and cancellation_verified_at is not null)
  )
  into count_games, all_terminal
  from public.games where week_id = p_week_id;
  if count_games is distinct from target_week.expected_games or all_terminal is distinct from true then
    raise exception 'Every expected game must have a verified terminal result';
  end if;

  select array_agg(participant_id) into roster from public.weekly_results where week_id = p_week_id;
  if roster is null then
    select array_agg(id) into roster from public.participants where active;
  end if;
  if cardinality(roster) is distinct from 5 then raise exception 'Five participants required'; end if;

  with totals as (
    select r.participant_id,
      count(g.id) filter (where g.status = 'final')::int as eligible_games,
      count(g.id) filter (where g.status = 'final' and (
        (g.home_score > g.away_score and p.team_id = g.home_team_id)
        or (g.away_score > g.home_score and p.team_id = g.away_team_id)
      ))::int as points
    from unnest(roster) r(participant_id)
    cross join public.games g
    left join public.picks p on p.game_id = g.id and p.participant_id = r.participant_id
    where g.week_id = p_week_id
    group by r.participant_id
  )
  insert into public.weekly_results (week_id, participant_id, points, eligible_games, rank)
  select p_week_id, participant_id, points, eligible_games, rank() over (order by points desc)
  from totals
  on conflict (week_id, participant_id) do update set
    points = excluded.points, eligible_games = excluded.eligible_games,
    rank = excluded.rank, calculated_at = clock_timestamp();

  update public.weeks set status = 'complete' where id = p_week_id;

  with totals as (
    select wr.participant_id, sum(wr.points)::int as points, sum(wr.eligible_games)::int as eligible_games
    from public.weekly_results wr join public.weeks w on w.id = wr.week_id
    where w.season_id = season_key and w.status = 'complete'
    group by wr.participant_id
  )
  insert into public.season_standings (season_id, participant_id, points, eligible_games, rank)
  select season_key, participant_id, points, eligible_games, rank() over (order by points desc)
  from totals
  on conflict (season_id, participant_id) do update set
    points = excluded.points, eligible_games = excluded.eligible_games,
    rank = excluded.rank, calculated_at = clock_timestamp();
end;
$$;

revoke all on function public.recalculate_pickem_week(bigint) from public, anon, authenticated;
grant execute on function public.recalculate_pickem_week(bigint) to service_role;
