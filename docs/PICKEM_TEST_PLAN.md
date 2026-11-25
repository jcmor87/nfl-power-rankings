# Pick’em test plan

Use synthetic accounts, games and test recipients in disposable environments. Production service configuration and delivery require owner approval. Keep test rows out of the live competition.

## Phase 1 verification

- Apply both migrations on clean PostgreSQL 17 with Supabase-style database roles and a stub `auth.uid()`. Use actual Supabase Auth and PostgREST before launch.
- Confirm anonymous and inactive or unlinked identities cannot read competition records or submit picks. Verify the directory exposes only ID and display name.
- Confirm an active participant can update their own pick before kickoff, receives one stored row, and cannot use direct writes, an invalid team, a planned week, a postponed game or a game at or after database kickoff.
- Confirm an active participant sees a peer selection only after verification of the final game. Check that participant-facing aggregate and operational access is disabled.
- Normalize captured scheduled, final and canceled ESPN samples. Reject invalid, duplicate and empty observations. Verify the dashboard source and deployment configuration are preserved.

## Remaining launch tests

- Repeat database authorization through the actual API and check concurrent submissions around kickoff. Alter browser time and verify the deadline remains unchanged. Verify the planned-to-active transition and postponed-game reopening workflow.
- Exercise password sign-in and, if configured, an invite or magic-link exchange using an owner-controlled account. Check signup failure, logout, revocation and service interruption.
- Verify one point per correct pick, missing picks and ties at zero, cancellations excluded, shared weekly winners, provisional standings, idempotent rescoring and official score corrections without double-counting.
- Verify expected matchup completeness, postponements and recovery after stale, partial or unavailable feed responses.
- Verify DST scheduling, retries, concurrent claims and ambiguous email outcomes. Send a formatted test email only to an owner-controlled recipient and verify acceptance and inbox receipt.
- Verify credentials and private data are absent from commits, built files and logs. Confirm realtime, aggregates and API responses cannot reveal unpublished picks. Restore a private backup in a disposable environment.
- Test iPhone, iPad and desktop layouts, all Power Rankings filters, and navigation persistence when the rankings dashboard is regenerated.

## Repeatable Supabase Auth and REST integration

Use a separate, disposable Supabase project with no existing Auth accounts or Pick’em records, or an isolated local Supabase stack. Apply both reviewed migrations. Disable public signup and anonymous sign-ins and keep Email enabled. No competition mail or SMTP is needed. The harness provisions confirmed accounts through the Auth Admin API and uses their actual password sessions for verification.

Run [tests/supabase-live.mjs](../tests/supabase-live.mjs) with Node.js 20+ from a trusted shell or private runner. Provide these environment variables through the runner or a protected local environment. Keep values out of source control and logs.

| Variable | Value |
| --- | --- |
| `PICKEM_TEST_URL` | Disposable project URL |
| `PICKEM_TEST_CONFIRM_ORIGIN` | The same project origin without a trailing slash |
| `PICKEM_TEST_PUBLIC_KEY` | Project publishable key or legacy anon key |
| `PICKEM_TEST_SERVICE_KEY` | Backend secret key or legacy service-role key |

```sh
node tests/supabase-live.mjs
```

The harness refuses a nonempty project, creates two linked synthetic participants plus one unlinked identity, and cleans up its records and Auth users in reverse order. The synthetic week exists only in the disposable environment. If execution is interrupted before cleanup, inspect the disposable project and clear only the listed fixtures or discard that disposable project before rerunning.

The suite checks API write denial, restricted columns, pick privacy during scheduled and in-progress states and unverified finals, disclosure after verified final, immediate revocation with the existing access token, and concurrent upserts. It submits a pick before kickoff and repeats immediately after crossing the observed server deadline. Network timing cannot assert exact microsecond equality with the database clock.

November 24, 2026 verification used disposable PostgreSQL 17, Supabase Auth (GoTrue 2.185.0), and PostgREST 13.0.7. Auth tokens came from password sign-in. The hosted Supabase gateway and the owner’s project were outside this test run.

## Phase 3 local results

Applied all five migrations on local PostgreSQL 17 alongside GoTrue 2.185.0 and PostgREST 13.0.7. Ran the API harness against that stack in clean-fixture and existing-account modes. The existing-account run verified the signup-disabled response for the synthetic project, actual password sessions, own-pick query shape, privacy, mutation denial, late-pick rejection, the reschedule lock, immediate revocation and cleanup.

Run `node --test tests/phase3.test.mjs` for provider normalization and mail tests. Run [scoring.sql](../tests/scoring.sql) as owner in a disposable migrated test database for shared ranks, missed/tied/canceled games, postponement gating, idempotent rescoring and corrections, and mail claim retries. Its fixtures roll back. These tests passed locally. The manual preview fixture and cleanup also executed locally and retained the two Auth accounts for separate deletion.

DOM checks passed for the app sections, Pacific kickoff formatting, own-pick saves, mocked sign-in/revocation response/logout, and the Power Rankings league/conference/division filters. Native iPhone/iPad layouts and the owner’s hosted gateway remain launch checks. No email transport was exercised.

## Frontend empty-competition regression

Run `npm ci --prefix tests` and `npm test --prefix tests`. The DOM tests exercise initial load and polling with empty PostgREST arrays, unsupported browser convenience APIs, malformed successful responses, rendering exceptions and denied identities. Diagnostics show the operation and a fixed error category. They omit response bodies, exception messages and signed-in identity data.

The optional live test uses `PICKEM_FRONTEND_LOCAL_ORIGIN` with a loopback-only Auth/REST gateway backed by a disposable migrated database. Provision confirmed fixtures `synthetic-1@example.com` and `synthetic-2@example.com`, using passwords `Local-fixture-password-1!` and `Local-fixture-password-2!` only in that disposable environment. Link them to active seats 1 and 2 with display names `Synthetic A` and `Synthetic B`. Leave the seasons, weeks and games empty. The test signs in and out as each account using actual API responses. Native iPad Safari verification still requires the private preview.

## Hosted runner transport regression

Run `node --test tests/supabase-requests.test.mjs`. The tests cover project origin and key validation, opaque API-key and bearer headers, sanitized network/status reporting, bounded GET retries and mutation reconciliation without replay. From a private terminal, `bash tests/run-hosted.sh --preflight` runs only the read-only hosted checks.
