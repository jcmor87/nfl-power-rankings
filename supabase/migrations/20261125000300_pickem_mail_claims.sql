alter table public.email_log
  add column claim_token uuid,
  add column attempts smallint not null default 0 check (attempts between 0 and 3);

create function public.claim_pickem_email(p_week_id bigint, p_participant_id uuid, p_kind text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  token uuid := gen_random_uuid();
  pacific_now timestamp := clock_timestamp() at time zone 'America/Los_Angeles';
  target_week public.weeks;
begin
  -- Match the scoring lock order.
  perform 1 from public.games where week_id = p_week_id order by id for share;
  select * into target_week from public.weeks where id = p_week_id for share;
  if not found or p_kind is null or p_kind not in ('reminder', 'results') then return null; end if;
  if not exists (select 1 from public.participants where id = p_participant_id and active) then
    return null;
  end if;

  if p_kind = 'reminder' then
    if target_week.status <> 'active' or extract(isodow from pacific_now) <> 3
       or pacific_now::time < time '12:00'
       or not exists (
         select 1 from public.games where week_id = p_week_id and status = 'scheduled'
           and picks_locked_at is null and started_at is null and kickoff_at > clock_timestamp()
       ) then return null; end if;
  elsif target_week.status <> 'complete'
    or (select count(*) from public.weekly_results where week_id = p_week_id) <> 5
    or not exists (select 1 from public.weekly_results
                   where week_id = p_week_id and participant_id = p_participant_id)
    or (select count(*) from public.games where week_id = p_week_id) <> target_week.expected_games
    or exists (
      select 1 from public.games where week_id = p_week_id
        and not ((status = 'final' and final_verified_at is not null)
          or (status = 'canceled' and cancellation_verified_at is not null))
    ) then return null;
  end if;

  insert into public.email_log (week_id, participant_id, kind, status, claim_token, attempts)
  values (p_week_id, p_participant_id, p_kind, 'claimed', token, 1)
  on conflict (week_id, participant_id, kind) do update
    set status = 'claimed', claim_token = token, attempts = public.email_log.attempts + 1,
      updated_at = clock_timestamp()
    where public.email_log.status = 'failed' and public.email_log.attempts < 3
      and public.email_log.updated_at < clock_timestamp() - interval '15 minutes'
  returning claim_token into token;
  return token;
end;
$$;

create function public.finish_pickem_email(p_claim uuid, p_status text, p_provider_message_id text default null)
returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  if p_claim is null or p_status is null or p_status not in ('accepted', 'failed', 'ambiguous') then return false; end if;
  if p_status = 'accepted' and nullif(btrim(p_provider_message_id), '') is null then return false; end if;
  update public.email_log set status = p_status, provider_message_id = p_provider_message_id,
    updated_at = clock_timestamp()
  where claim_token = p_claim and status = 'claimed';
  return found;
end;
$$;

create unique index email_log_claim_token_idx on public.email_log(claim_token) where claim_token is not null;
revoke all on function public.claim_pickem_email(bigint, uuid, text) from public, anon, authenticated;
revoke all on function public.finish_pickem_email(uuid, text, text) from public, anon, authenticated;
grant execute on function public.claim_pickem_email(bigint, uuid, text) to service_role;
grant execute on function public.finish_pickem_email(uuid, text, text) to service_role;
