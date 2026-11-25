# Install Pick’em from an iPad

Use Safari with two tabs, one for GitHub and one for the [Supabase dashboard](https://supabase.com/dashboard). Everything below runs in the browser. Use this procedure on the empty `nfl-family-pickem` project once you approve the reviewed SQL for installation. Installation creates an empty schema and leaves every competition week inactive.

## 1. Select the project and inspect it

1. Open **Supabase → nfl-family-pickem → SQL Editor**. Confirm the project name and project reference in the dashboard. If the sidebars are collapsed, rotate the iPad or use Safari’s **Request Desktop Website**.
2. Select **New query**. Paste and run this read-only preflight using the default `postgres` role. Keep the output for comparison.

```sql
select table_name, to_regclass('public.' || table_name) as existing_object
from unnest(array['participants','seasons','weeks','teams','games','picks',
                  'weekly_results','season_standings','email_log','job_runs','audit_log'])
     as names(table_name)
union all
select 'migration history', to_regclass('supabase_migrations.schema_migrations');

select to_regnamespace('pickem_private') as private_schema,
       to_regprocedure('public.submit_pick(bigint,bigint)') as submit_pick;
```

A fresh installation has no existing Pick’em objects. A migration history table may already exist. If it does, run the history query below and confirm neither Pick’em version appears before installing.

```sql
select version, name
from supabase_migrations.schema_migrations
where version in ('20261124000100','20261124000200')
order by version;
```

## 2. Apply both reviewed migrations as one transaction

1. Open a fresh **New query**. Paste this preamble into it.

```sql
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
select pg_advisory_xact_lock(20261124, 100);
```

2. Open [20261124000100_pickem_schema.sql](../supabase/migrations/20261124000100_pickem_schema.sql) from the reviewed PR. Use GitHub’s **Raw** view or **Copy raw file** button to copy the entire file. Paste it on a new line below the preamble.
3. Open [20261124000200_pickem_access.sql](../supabase/migrations/20261124000200_pickem_access.sql). Copy its entire raw content and paste it on a new line after the first migration.
4. Paste the footer below on a new line after the second migration. This records the same versions and names Supabase CLI expects. The `statements` column is left null for this browser install, so use the repository as the source of truth for migration content.

```sql
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text not null primary key
);
alter table supabase_migrations.schema_migrations
  add column if not exists statements text[],
  add column if not exists name text;

insert into supabase_migrations.schema_migrations (version, name)
values ('20261124000100', 'pickem_schema'),
       ('20261124000200', 'pickem_access');

notify pgrst, 'reload schema';
commit;
```

5. Check that the editor starts with `begin;`, ends with `commit;`, and contains both full files in order. Clear any text selection by tapping once in the editor, then tap **Run** once. Keep the tab open until execution completes. The schema, permissions, policies and history commit together. Run the verification in a separate query afterward.

If the editor reports an error, save the first error and its line number. A failed transaction cannot commit. If the editor reports an aborted transaction, use a fresh query to run `rollback;` on that connection if it is still open. After an error, tab closure or timeout, rerun the preflight and history checks before deciding whether to retry.

## 3. Verify the install and diagnose partial state

In a new SQL Editor query, paste and run the full [verification SQL](../supabase/checks/verify_pickem.sql). Expect the tables, policies and grants to match, both secured functions to pass, and Realtime to be clear. Run the two-version history query from Step 1 and expect both rows with the names above. SQL Editor’s owner role can bypass RLS. Use the [live API check](PICKEM_TEST_PLAN.md) separately to test participant access.

| Observed state | Safe next step |
| --- | --- |
| No Pick’em objects or history rows | Check the first error, correct the copy or settings and retry the complete transaction. |
| All checks pass and both versions are recorded | Installation is complete. Leave the query saved for reference. |
| All checks pass but one or both versions are missing | Compare the installed definitions to the reviewed SQL first. Once both migrations are independently confirmed, record only the missing versions in the existing ledger with the footer’s version/name values, or have a maintainer use `supabase migration repair --status applied <verified-version>` later. |
| Missing tables or functions, failed grants/RLS checks, or history entries without matching objects | If access is uncertain, pause the project through its dashboard if possible or disable the Data API under **Project Settings → Data API**. Keep enrollments and jobs paused. Preserve the errors and privately back up any data. Ask a maintainer to compare the catalog to the reviewed files and write a targeted repair. Leave existing records and history intact during diagnosis. |

When a maintainer later links the CLI, `supabase migration list` should show both versions locally and remotely. Use `supabase db push --dry-run` to confirm they will be skipped. CLI history repair changes ledger metadata only. Use it to reconcile verified schema state. Future changes should use new migration versions.

## 4. Configure password sign-in

1. In **Authentication → Sign In / Providers**, disable **Allow new users to sign up** and **Allow anonymous sign-ins**. Open **Email**, leave the provider enabled and disable unused providers.
2. In **Project Settings → Data API**, confirm the API exposes `public`. Keep `pickem_private` outside exposed schemas. Keep the Pick’em tables outside Realtime.
3. For eventual authorized enrollment, use **Authentication → Users → Add user → Create new user** with an approved address, a generated strong password and email confirmation after independently checking the address. Avoid **Invite user** during password setup. Keep addresses and passwords private and share credentials directly with the individual. Use synthetic accounts only in a separate disposable project for testing.
4. In **SQL Editor**, link each approved Auth user’s UUID to a unique seat 1–5. Replace the placeholders on the iPad, and repeat for each approved account. Keep real enrollments pending until authorized.

```sql
insert into public.participants (auth_user_id, display_name, seat, active)
values ('AUTH_USER_UUID'::uuid, 'APPROVED_DISPLAY_NAME', 1, true);
```

5. Password sign-in needs no SMTP or redirect link. For future passwordless sign-in or recovery, first validate custom SMTP using an owner-controlled test account, set **Authentication → URL Configuration → Site URL** to `https://jcmor87.github.io/nfl-power-rankings/pickem/`, and allow only the implemented callback URL. See the [owner setup guide](PICKEM_SETUP.md) for SMTP and credential handling.
