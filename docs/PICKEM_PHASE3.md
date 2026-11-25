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
4. With no synthetic game rows present, sign-in should show an empty competition. Try sample picks for an offline preview of the interface. The automated harness removes its fixtures when it exits. After it passes, use the [synthetic preview fixture](../supabase/checks/create_preview_fixture.sql) in SQL Editor if you want to exercise actual hosted saves on the private preview. It creates one upcoming and one locked game in the fictional year 2999. Sign in with each temporary account, verify the two states and change the upcoming pick. Use the cleanup in Section 5 to remove the preview fixture and temporary enrollment when finished.

## 4. Run hosted security validation privately

1. Verify the catalog and Auth settings first. Confirm seats 1 and 2 belong to the approved temporary accounts and every competition table apart from participants is empty. Confirm there are no other Auth users.
2. In the private Codespace, open a second terminal and run `bash tests/run-hosted.sh` from the repository root with Node 20 or later. Type the two passwords and project keys directly at the hidden prompts. Use a backend secret generated for the test if available and delete it afterward. Keep secrets out of chat, terminal commands, repository files, screenshots, and Actions logs.
3. For a connectivity-only check, run `bash tests/run-hosted.sh --preflight`. It uses the two API keys to check connectivity, anonymous denial, administrative Auth listing, the approved enrollments and empty competition tables. It does not prompt for passwords or create fixtures. The full run repeats the preflight and verifies both passwords before creating any synthetic records.
4. The runner checks that registration is disabled, signs in both participants, provisions one auto-confirmed unlinked synthetic account without inviting it, and exercises real Auth and REST. It creates only a clearly synthetic year 2999 fixture week, checks pick changes and disclosure, tests anonymous and unauthorized access, rejects late and invalid picks, and verifies that moving an expired kickoff cannot reopen it. It temporarily revokes seat 1 and restores it on cleanup. The recorded boundary is an API-observed crossing. Byte-exact equality with PostgreSQL’s clock cannot be isolated through HTTP timing.
5. Leave the terminal open until cleanup passes. Failures show the stage, HTTP method, endpoint path, response status or an allowlisted network error code. Share those lines if needed. They omit credentials, identifiers in Auth user paths, query strings, and response bodies. Transient reads may retry twice. Writes are never resent after a lost response. Cleanup looks up exact fixture selectors and checks the original account and competition state before declaring success. A terminated process or continued outage can leave unresolved fixtures. If cleanup cannot be verified, use the recovery guidance below before rerunning. The hosted run requires private owner input.

## 5. Clean up and enroll after approval

1. After hosted testing is finished, run [cleanup SQL](../supabase/checks/cleanup_hosted_fixtures.sql) in the owner’s SQL Editor. It is scoped to the specified synthetic season, source-tagged games, exact synthetic teams and the two approved account-to-seat mappings. It aborts on other seasons, participants, or unexpected dependent data. It removes the participant rows even if the harness removed all fixtures.
2. Open **Authentication → Users** and delete the exact temporary accounts only after the SQL succeeds. If a run was interrupted, see whether an unlinked `synthetic-…@example.com` exists and delete only the address associated with the test run. Never delete a linked Auth account before its participant foreign key is removed. Stop and delete the private preview environment.
3. When actual enrollment is approved, create five individually confirmed Email users through **Authentication → Users → Add user → Create new user**. Use strong separate passwords, share privately, and assign seats 1–5 using the [iPad guide](PICKEM_IPAD_SETUP.md#4-configure-password-sign-in). Public registration stays off.

## 6. GitHub configuration and production gates

- [ ] Hosted security suite passes, temporary accounts are removed, and only the five approved seats are enrolled.
- [ ] Test layouts on iPhone and iPad Safari and desktop. Test existing dashboard filters and the link both ways.
- [ ] Confirm how the weekly dashboard is regenerated. The feature branch adds a navigation link and a read-only pull-request workflow that runs the [executable guard](../tests/check-navigation.sh). After the workflow is on the default branch, require pull requests and the **navigation** status check in the `main` ruleset, restrict direct pushes and bypass, and make the existing publisher preserve the link or reinsert it during generation. This safeguard depends on enabling those settings. The current publishing job and production branch are untouched.
- [ ] Confirm a free data provider using its authorized key, including kickoff changes, final/canceled signals, correction propagation and record identity across reschedules. No real week should be activated until coverage and expected matchups are verified. See [data decision](PICKEM_NFLVERSE.md).
- [ ] Approve the scoring proposals and selected eligible full week, validate correction handling, and rehearse backup recovery privately.
- [ ] For future production deployment, the Supabase project URL and publishable key are the only public configuration. Set `SUPABASE_URL` as an Actions variable if jobs require it. Store `SUPABASE_SECRET_KEY`, `BALLDONTLIE_API_KEY`, and the chosen mail transport credential (for example `SMTP_USERNAME` and `SMTP_PASSWORD`) in **Settings → Secrets and variables → Actions** only when a reviewed workflow consumes them. Keep recipients in Auth or backend-only configuration. For SMTP, follow the [owner setup guide](PICKEM_SETUP.md). The current repository activates no schedule or sending transport.
- [ ] Verify delivery to an owner-controlled test mailbox, provider acceptance and retries, then obtain explicit approval for merge and production schedules.
