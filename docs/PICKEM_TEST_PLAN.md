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
