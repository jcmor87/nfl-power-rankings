# Owner setup

The existing free Supabase project is `nfl-family-pickem`. Review the draft SQL before applying it. Phase 1 does not need live credentials or real competition participants. Complete the production steps only after their corresponding implementation and acceptance checks.

For the browser-only installation, follow [Install Pick’em from an iPad](PICKEM_IPAD_SETUP.md). That path records both migrations for future CLI use.

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

## Phase 5 owner setup on iPad

Keep both `PICKEM_NFL_SYNC_ENABLED` and `PICKEM_EMAIL_ENABLED` unset or `false` until you approve launch. Keep `PICKEM_EMAIL_TEST_ENABLED` unset except during the explicit mailbox test. Do the following from the GitHub and Supabase dashboards in Safari.

1. **Review the templates.** In the private Codespace, open the file explorer and preview the three HTML files under [email-previews](email-previews/). If the editor shows source, open the existing private website preview and append `/docs/email-previews/reminder.html`, `/docs/email-previews/confirmation.html` or `/docs/email-previews/results.html` to the preview’s origin. All names and scores are synthetic. Check portrait width, the app link and the movement labels.
2. **Create the free provider account.** In Brevo, select the Free plan and complete any account verification. Open **Settings → Senders, Domains & Dedicated IPs → Senders → Add a sender**. Enter **NFL Family Pick’em** and an existing mailbox you control. Use the code Brevo sends to that mailbox. A free mailbox can be rewritten to Brevo’s sending domain. Check the display name, From address and inbox placement during the owner mailbox test before approving family delivery. Create a dedicated API key under **Settings → SMTP & API → API Keys**. Store it in your private password manager when Brevo displays it.
3. **Add protected GitHub settings.** Open the repository’s **Settings → Environments → pickem-production**. Keep the deployment branch restricted to `main` and administrator bypass disabled. Add environment secrets `PICKEM_BREVO_API_KEY` and `PICKEM_BREVO_SENDER` (the verified owner mailbox address). Retain the existing `SUPABASE_SECRET_KEY` environment secret and `SUPABASE_URL` environment variable, using the exact project origin without a trailing slash. Under **Settings → Secrets and variables → Actions → Variables**, leave the three switches above unset or `false`. Workflow job gates read these repository variables. Ensure repository Issues are enabled and you receive notifications for assigned issues.
4. **Install the database update after approval.** Check that the prior nine migrations are present. In Supabase, open **SQL Editor → New query**. In GitHub open [install_pickem_mail_automation.sql](../supabase/checks/install_pickem_mail_automation.sql), select **Raw**, and copy the entire file. Paste it into the new query and tap **Run** once as `postgres`. The installer locks against other installers, runs in one transaction, and records version `20261125000800` with the name `pickem_mail_automation`. Open another new query, paste [verify_pickem_mail_automation.sql](../supabase/checks/verify_pickem_mail_automation.sql), and confirm that all four rows show `true`. If installation reports an error, run `rollback;` in the failed session if it stays open. Check the read-only verification from a fresh query. If the migration is already recorded and every check passes, installation is complete. If verification shows drift, halt and investigate before retrying. Preserve backups and the existing migration ledger.
5. **Prepare the browser configuration on the feature branch.** In Supabase **Connect** or **Project Settings → API Keys**, copy the project URL and the **publishable** key beginning `sb_publishable_`. In GitHub edit [pickem/config.mjs](../pickem/config.mjs) on `feature/nfl-family-pickem` using those two public values. Review the PR diff and rely on the existing branch approval process for publishing. GitHub Pages on `jcmor87.github.io` shows the email and password form and hides project connection and sample controls. The private preview keeps those controls. The production form remains disabled while its public settings are blank. Keep the navigation guard in the Power Rankings regeneration workflow and verify the **Family Pick’em** link and dashboard filters before release.
6. **Verify provider delivery after approving a test.** Once the workflow is available on `main`, leave competition delivery disabled. Go to **Actions → Pickem email → Run workflow**, select `main` and `dry-run` to check synthetic rendering with no external calls. For a separate live test to your own verified sender mailbox only, temporarily set the repository variable `PICKEM_EMAIL_TEST_ENABLED=true`, choose `test-sender` once, then reset the variable to `false`. The job sends a synthetic template to the verified sender mailbox and accesses no competition database. Check the Brevo transaction log and the inbox or spam folder. If the run reports uncertainty, inspect Brevo before dispatching another test. Confirm the Brevo account is activated for transactional delivery to external recipients and has no account-specific sandbox restrictions. A mailbox test to the sender alone does not establish delivery to other recipients.
7. **Enroll the family only after separate approval.** Verify the two temporary accounts are the documented test addresses at seats 1 and 2. If the preview fixture still exists, run [cleanup_hosted_fixtures.sql](../supabase/checks/cleanup_hosted_fixtures.sql) first. Run [remove_pickem_test_participants.sql](../supabase/checks/remove_pickem_test_participants.sql) once in the SQL Editor. The transaction requires both exact mappings and fails if existing rows reference them. Verify in **Table Editor → participants** that the mappings are gone and that imported games remain. Then delete only the two corresponding temporary Auth users in **Authentication → Users**. Follow the private password-based enrollment procedure above for John (seat 1), Christie (2), Justin (3), Catie (4) and Tim (5). Keep email/password signup disabled in Authentication settings, keep the verified addresses and user UUIDs private, and check that exactly five seats are active. Share generated passwords over a private channel. Have each person sign in and verify their display name. No GitHub accounts are required. For recovery, use the private admin procedure below.
8. **Approve launch.** Verify the live database migration checks, browser sign-in and privacy, owner test email, protected environment, incident notifications and a restorable private backup. Review the opening slate and confirm that its first pick deadline is still in the future. Approve a new full opening week and update competition scope under review if Week 13 has missed its first deadline. Only after explicit approval enable the NFL sync switch, verify the intended week and fresh leases, then enable the independent email switch.

### Password recovery without email

Verify the participant’s identity privately. In **Authentication → Users** copy that existing account’s UUID. Use a trusted private terminal (for example your private Codespace through Safari), with shell tracing disabled. The following prompted values stay out of shell history. Generate a unique new password in a password manager. Enter the project URL exactly as `https://PROJECT.supabase.co` and use the backend secret from the secure Supabase dashboard. Use this only for the existing verified account and deliver the new password privately.

```bash
set +x
read -r -p 'Project URL: ' RESET_URL
read -r -p 'Existing Auth user UUID: ' RESET_USER
read -rs -p 'Supabase secret key: ' RESET_KEY; printf '\n'
read -rs -p 'New password: ' RESET_PASSWORD; printf '\n'
RESET_URL="$RESET_URL" RESET_USER="$RESET_USER" RESET_KEY="$RESET_KEY" RESET_PASSWORD="$RESET_PASSWORD" node --input-type=module <<'JS'
const { RESET_URL: url, RESET_USER: user, RESET_KEY: key, RESET_PASSWORD: password } = process.env;
try {
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url) ||
      !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(user) ||
      !/^sb_secret_[a-z0-9_-]+$/i.test(key) || password.length < 16) throw new Error();
  const response = await fetch(url + '/auth/v1/admin/users/' + user, {
    method: 'PUT', redirect: 'error', signal: AbortSignal.timeout(12000),
    headers: { apikey: key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ password }),
  });
  if (!response.ok) throw new Error();
  console.log('Password updated. Verify sign-in privately.');
} catch {
  console.error('Password update not confirmed. Check the Auth dashboard privately.');
  process.exitCode = 1;
}
JS
unset RESET_URL RESET_USER RESET_KEY RESET_PASSWORD
```

For suspected compromise, set the participant mapping inactive while investigating and verify existing sessions are revoked or expired before re-enabling. Keep the same Auth UUID and participant link to preserve picks and history. Passwordless sign-in and self-serve recovery can follow after a separate approved Auth SMTP setup.
