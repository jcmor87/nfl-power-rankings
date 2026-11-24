# Owner setup

The existing free Supabase project is `nfl-family-pickem`. Review the draft SQL before applying it. Phase 1 does not need live credentials or real competition participants. Complete the production steps only after their corresponding implementation and acceptance checks.

## 1. Configure Auth

1. Open [Supabase Dashboard](https://supabase.com/dashboard), select `nfl-family-pickem`, and confirm the project name and project reference in project settings.
2. In **Authentication → Sign In / Providers**, turn off **Allow new users to sign up** and **Allow anonymous sign-ins**. Keep Email enabled for owner-provisioned accounts. Leave unused identity providers disabled.
3. Under **Authentication → URL Configuration**, set **Site URL** to the eventual client URL, `https://jcmor87.github.io/nfl-power-rankings/pickem/`, before enabling email links. Add the exact callback URL there once the frontend implements its callback. Add a localhost callback only to the project used for local testing and only if needed. Avoid wildcard redirect rules.
4. In project API settings, keep the exposed schemas limited to those the project needs. Keep `pickem_private` out of the exposed list. Leave Pick’em tables out of the `supabase_realtime` publication.

## 2. Apply reviewed migrations

Use the [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) from the repository root. Run these on your own computer from the reviewed PR branch. Replace the project reference locally. The CLI login and database password prompts are for your terminal.

```sh
git fetch origin
git switch --track origin/feature/nfl-family-pickem
# Run supabase init only if the checkout has no supabase/config.toml.
supabase init
supabase login
supabase link --project-ref "YOUR_PROJECT_REF"
supabase migration list
supabase db push --dry-run
supabase db push
supabase migration list
```

If the feature branch already exists locally, use `git switch feature/nfl-family-pickem`. Verify the dry run targets the intended project and lists just `20261124000100` and `20261124000200` on a fresh database. After pushing, both versions should appear in local and remote migration history. Keep CLI scratch files and credentials out of Git. In **Table Editor**, confirm the eleven tables exist and RLS is enabled. In **SQL Editor**, an owner can run the inspection below. An owner query bypasses RLS and cannot establish participant isolation.

```sql
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('participants', 'seasons', 'weeks', 'teams', 'games', 'picks',
                    'weekly_results', 'season_standings', 'email_log', 'job_runs', 'audit_log')
order by tablename;
```

## 3. Enroll the five accounts before launch

1. Choose five approved participants and assign seats 1–5. For password-based access, go to **Authentication → Users → Add user → Create new user**. Enter the participant’s email and a unique strong password and confirm the email only after verifying the address with the participant. Share passwords privately and have users replace them once the client supports password changes. Participant accounts need no GitHub login.
2. Copy each Auth user UUID from the dashboard. Enter the following in **SQL Editor** and repeat for each approved participant, using distinct seats. Keep names, UUIDs and addresses within owner-controlled systems.

```sql
insert into public.participants (auth_user_id, display_name, seat, active)
values ('<AUTH_USER_UUID>'::uuid, '<DISPLAY_NAME>', 1, true);
```

3. Verify five active seats in the dashboard. To revoke access, set `active = false`. Before deleting a linked Auth user, set both `active = false` and `auth_user_id = null` on their row to retain historical results. Reusing a seat for a different person would misattribute history. A roster change therefore needs a separately designed enrollment change.
4. With public signup disabled and verified custom SMTP, use the dashboard’s **Invite user** for new accounts and link the created Auth UUID as above. The eventual client should request magic links with `shouldCreateUser: false`. Validate pickup and callback with an owner-controlled address before enrolling through email. For password accounts without SMTP, handle lost credentials privately via the Auth Admin password update flow until recovery email is available.

## 4. Configure email when the client and sending job are ready

Supabase’s built-in mail service is restricted and rate-limited. Use owner-provisioned passwords as the free baseline. For passwordless or self-service recovery, use an existing free SMTP option only after validating delivery. With an eligible Google account, enable two-step verification, then create a [Google app password](https://support.google.com/accounts/answer/185833) if the account offers that option. In Supabase **Authentication → Emails → SMTP Settings**, enable custom SMTP, enter the verified sender name and address, and use the provider’s settings. For Gmail the host is `smtp.gmail.com`, with port 465 for implicit TLS or 587 for STARTTLS, the full account email as username and the app password as password. Verify a full invite or magic-link round trip with an owner-controlled address. Follow [Supabase custom SMTP guidance](https://supabase.com/docs/guides/auth/auth-smtp). No purchases are needed for the password fallback.

Competition emails use a separate future sender job. Configure one test recipient you control and validate provider acceptance, formatting and idempotency before enabling any scheduled delivery. Provider acceptance means that the provider took responsibility for the message. Inbox placement requires separate verification.

## 5. Configure GitHub Actions when the workflow exists

Go to **Settings → Secrets and variables → Actions**. Add secrets through **New repository secret** only when a reviewed workflow consumes them. Proposed names below form the contract for that future workflow.

| Name | Location and purpose |
| --- | --- |
| `SUPABASE_URL` | Actions variable for the project URL from the Supabase Connect dialog |
| `SUPABASE_SECRET_KEY` | Actions secret for the backend key from Supabase project API Keys, using a client that supports the chosen key type |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM` | Actions variables for the competition email sender |
| `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_TEST_RECIPIENT` | Actions secrets for provider credentials and the owner-controlled test address |

Use only the project URL and publishable key in the future static client. Store the database password in your password manager for the local CLI. Keep private values out of chat, source files, PR descriptions and logs. The Phase 1 PR needs no GitHub secrets.

## 6. Launch gates

Pass the test plan, select a permitted data source, confirm every game and deadline for the selected week, make and test a private backup, and approve the PR and launch week explicitly. If the first kickoff passes before readiness, seek approval for the next eligible full week. Set up the verified schedule/score and Wednesday noon Pacific jobs only after their test runs succeed. Enable results emails after the week completion and duplicate-delivery safeguards pass.
