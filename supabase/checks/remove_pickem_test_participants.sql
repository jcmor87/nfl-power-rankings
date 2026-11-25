-- Run only after cleanup_hosted_fixtures.sql and after verifying both temporary identities.
begin;
set local lock_timeout = '5s';
select pg_advisory_xact_lock(20261124, 100);
do $cleanup$
declare
  removed integer;
begin
  if exists (select 1 from public.seasons where nfl_year=2999) then
    raise exception 'Remove the synthetic preview fixture first';
  end if;

  delete from public.participants p using auth.users u
  where p.auth_user_id=u.id
    and ((p.seat=1 and u.email='pickem-test1@example.com')
      or (p.seat=2 and u.email='pickem-test2@example.com'));
  get diagnostics removed = row_count;
  if removed <> 2 then raise exception 'Expected the two documented temporary accounts at seats 1 and 2'; end if;
end;
$cleanup$;
commit;
