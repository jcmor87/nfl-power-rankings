# Hosted integration and launch handoff

## 1. Compare the hosted installation

1. In Safari open **Supabase → nfl-family-pickem → SQL Editor**. Before adding Phase 3, run the full [original installation check](../supabase/checks/verify_pickem.sql). Expect all rows to pass.
2. Open [catalog inspection SQL](../supabase/checks/inspect_pickem.sql). Paste one query at a time to see every result in SQL Editor. Compare columns, keys and checks with the [schema migration](../supabase/migrations/20261124000100_pickem_schema.sql) and policies, grants and function bodies with the [access migration](../supabase/migrations/20261124000200_pickem_access.sql). Check there are no extra API write grants or policies. The two original history rows should have the version and file suffix listed there. Browser installation deliberately stores no statement array. SQL formatting and qualified identifiers shown by PostgreSQL’s deparser can differ without a schema difference. Pause testing if an object, behavior, or privilege differs.
3. In **Authentication → Sign In / Providers**, check that **Allow new users to sign up** and **Allow anonymous sign-ins** are off and **Email** is enabled. Confirm the configured Site URL and keep **Invites** and email delivery unused. Keep `pickem_private` out of the Data API exposed schemas.
4. The owner reported the original structural checks passed. This branch cannot inspect hosted function bodies, grants or history independently without running the comparison above in the project.

## 2. Apply the reviewed Phase 3 migrations from Safari

Follow the [transaction steps in the iPad install guide](PICKEM_IPAD_SETUP.md#2-apply-both-reviewed-migrations-as-one-transaction). Use a fresh query, the same preamble, and paste the three new migration files in this order. The original two files are already installed.

1. [Game lifecycle](../supabase/migrations/20261125000100_pickem_game_lifecycle.sql)
2. [Scoring](../supabase/migrations/20261125000200_pickem_scoring.sql)
3. [Email claims](../supabase/migrations/20261125000300_pickem_mail_claims.sql)

Paste this footer in place of the initial-install footer and run once, with no selection in the editor.

```sql
insert into supabase_migrations.schema_migrations (version, name) values
  ('20261125000100','pickem_game_lifecycle'),
  ('20261125000200','pickem_scoring'),
  ('20261125000300','pickem_mail_claims');
notify pgrst, 'reload schema';
commit;
```

Repeat the catalog inspection. Expect all five migration versions, 11 RLS tables, eight read policies, the game lifecycle trigger, and the revised `submit_pick`. `pickem_identity` is callable by signed-in users and only returns that user’s active participant UUID and server time. Scoring and email claim functions are callable by the service role. The original-only verification deliberately expects six policies and no results grants, so use it before upgrading. A failed transaction or uncertain response calls for the read-only history and catalog checks before any retry.

## 3. Open a private preview on an iPad

1. On GitHub, open PR #1, select its `feature/nfl-family-pickem` branch and open **Code → Codespaces → Create codespace on feature/nfl-family-pickem** if your account has included free usage. Keep the preview private. If Codespaces is unavailable within your free allowance, use a privately controlled static server or an authorized maintainer's private development environment. Keep GitHub Pages on `main`.
2. In the browser Codespaces terminal, run `python3 -m http.server 8000 --bind 0.0.0.0` from the repository root. In **Ports**, forward 8000 and confirm **Visibility → Private** before opening its address. Append `/pickem/` to that private address.
3. In Supabase, open **Connect** for the project URL and **Project Settings → API Keys** for the **Publishable key** beginning with `sb_publishable_`. On the private preview, expand **Supabase connection** and paste both values. Enter a temporary account password directly in the sign-in form. The preview holds the access token in memory, checks the active participant via RPC, clears state on logout or expiry and does not store credentials in browser storage. Passwordless authentication remains a future enhancement.
4. For authenticated browser testing with imported NFL data present, follow [Hosted browser fixture and cleanup](#5-hosted-browser-fixture-and-cleanup). Keep the preview private.

## 4. Run hosted security validation privately

1. This automated harness requires an empty competition database. Use the browser fixture below for the hosted database with imported NFL rows. For the automated harness, verify the catalog and Auth settings first. Confirm seats 1 and 2 belong to the approved temporary accounts and every competition table apart from participants is empty. Confirm there are no other Auth users.
2. In the private Codespace, open a second terminal and run `bash tests/run-hosted.sh` from the repository root with Node 20 or later. Type the two passwords and project keys directly at the hidden prompts. Use a backend secret generated for the test if available and delete it afterward. Keep secrets out of chat, terminal commands, repository files, screenshots, and Actions logs.
3. For a connectivity-only check, run `bash tests/run-hosted.sh --preflight`. It uses the two API keys to check connectivity, anonymous denial, administrative Auth listing, the approved enrollments and empty competition tables. It does not prompt for passwords or create fixtures. The full run repeats the preflight and verifies both passwords before creating any synthetic records.
4. The runner checks that registration is disabled, signs in both participants, provisions one auto-confirmed unlinked synthetic account without inviting it, and exercises real Auth and REST. It creates only a clearly synthetic year 2999 fixture week, checks pick changes and disclosure, tests anonymous and unauthorized access, rejects late and invalid picks, and verifies that moving an expired kickoff cannot reopen it. It temporarily revokes seat 1 and restores it on cleanup. The recorded boundary is an API-observed crossing. Byte-exact equality with PostgreSQL’s clock cannot be isolated through HTTP timing.
5. Leave the terminal open until cleanup passes. Failures show the stage, HTTP method, endpoint path, response status or an allowlisted network error code. Share those lines if needed. They omit credentials, identifiers in Auth user paths, query strings, and response bodies. Transient reads may retry twice. Writes are never resent after a lost response. Cleanup looks up exact fixture selectors and checks the original account and competition state before declaring success. A terminated process or continued outage can leave unresolved fixtures. If cleanup cannot be verified, inspect the runner’s synthetic run tag before rerunning. The browser fixture cleanup only handles its own recorded fixture. The hosted run requires private owner input.

## 5. Hosted browser fixture and cleanup

Run this test with the private Codespaces port, production automation disabled, Week 13 **planned**, and the two existing temporary test participants as the only active seats. Avoid unrelated data edits and sync runs until cleanup finishes. The fixture has its own synthetic season, week, teams and games. The three games use paired synthetic kickoff evidence and leases that outlast their deadlines, so the test exercises the pick deadline without relying on an expiring lease or labeling the fixture as provider data.

1. In Supabase, select **nfl-family-pickem → SQL Editor → New query** and use the default **postgres** role. On the current PR branch, open [create_preview_fixture.sql](../supabase/checks/create_preview_fixture.sql), select **Raw**, and copy the entire file. Paste it into the query and tap **Run** once. Confirm there is no SQL error. The transaction records a digest of the existing competition rows before inserting the fixture.
2. Open the private preview at **/pickem/** and sign in as the temporary seat 1 account. Select **2999 · Week 1**. It contains **Synthetic Persistence**, **Synthetic Boundary**, and **Synthetic Locked** matchups. The persistence game accepts picks for about 90 minutes, the boundary game for about 20 minutes, and the locked game’s deadline has already passed. The app shows kickoff in Pacific time.
3. Pick a team in the persistence game. Wait for **Pick saved**, choose the other team, and wait for confirmation again. Sign out, sign back in as seat 1, and confirm the changed pick is still selected and counted.
4. Sign out and sign in as seat 2. Its persistence game should show no selected team and reveal no seat 1 choice. Pick a different team and wait for confirmation. Sign out and return as seat 1 to confirm the original choice is still selected, with no disclosure of seat 2’s choice. This is the browser-level check. The privacy policy itself is covered by the hosted security tests.
5. Confirm both buttons on **Synthetic Locked** are disabled. If there is time before **Synthetic Boundary** kicks off, save a choice there, leave the tab open through the displayed deadline, and confirm the saved choice stays visible while both buttons disable. Reload and confirm the game stays locked. If the boundary time has passed before testing it, complete cleanup and create a fresh fixture for the crossing test.
6. Sign both temporary sessions out. In **SQL Editor → New query**, paste the entire raw [cleanup_hosted_fixtures.sql](../supabase/checks/cleanup_hosted_fixtures.sql) and tap **Run** once. It deletes only the recorded fixture picks, games, week, season, teams and marker. It commits only if the remaining rows match the original digests. It preserves Week 13, the NFL rows and both temporary accounts. If a digest or fixture identity check fails, the transaction rolls back and the fixture remains. Keep automation disabled and inspect the named mismatch before retrying.
7. Reopen the private preview and confirm **2999 · Week 1** is gone. In the Supabase **Table Editor**, confirm 2026 Week 13 is still planned and still has 14 games. Stop the private preview when finished. Temporary enrollments can be removed separately after review. Do not delete linked Auth accounts while their participant rows remain.

When actual enrollment is approved, create five individually confirmed Email users through **Authentication → Users → Add user → Create new user** and assign seats 1–5 using the [iPad guide](PICKEM_IPAD_SETUP.md#4-configure-password-sign-in). Keep public registration off.

## 6. GitHub configuration and production gates

- [ ] Hosted security suite passes, temporary accounts are removed, and only the five approved seats are enrolled.
- [ ] Test layouts on iPhone and iPad Safari and desktop. Test existing dashboard filters and the link both ways.
- [ ] Confirm how the weekly dashboard is regenerated. The feature branch adds a navigation link and a read-only pull-request workflow that runs the [executable guard](../tests/check-navigation.sh). After the workflow is on the default branch, require pull requests and the **navigation** status check in the `main` ruleset, restrict direct pushes and bypass, and make the existing publisher preserve the link or reinsert it during generation. This safeguard depends on enabling those settings. The current publishing job and production branch are untouched.
- [ ] Confirm a free data provider using its authorized key, including kickoff changes, final/canceled signals, correction propagation and record identity across reschedules. No real week should be activated until coverage and expected matchups are verified. See [data decision](PICKEM_NFLVERSE.md).
- [ ] Approve the scoring proposals and selected eligible full week, validate correction handling, and rehearse backup recovery privately.
- [ ] For future production deployment, the Supabase project URL and publishable key are the only public configuration. Set `SUPABASE_URL` as an Actions variable if jobs require it. Store `SUPABASE_SECRET_KEY`, `BALLDONTLIE_API_KEY`, and the chosen mail transport credential (for example `SMTP_USERNAME` and `SMTP_PASSWORD`) in **Settings → Secrets and variables → Actions** only when a reviewed workflow consumes them. Keep recipients in Auth or backend-only configuration. For SMTP, follow the [owner setup guide](PICKEM_SETUP.md). The current repository activates no schedule or sending transport.
- [ ] Verify delivery to an owner-controlled test mailbox, provider acceptance and retries, then obtain explicit approval for merge and production schedules.
