# Pick’em operations

Phase 1 does not install jobs. Before enabling them, verify source permission, expected game counts and each verified kickoff. Keep newly imported weeks planned until the owner approves the full start week. Hold results for missing, suspended, postponed, unknown or unverified games. Treat a cancellation as terminal only after official confirmation.

Use a DST-aware Wednesday noon schedule in `America/Los_Angeles`. If the runner may start late, use a Pacific-time gate with catch-up and a unique delivery claim. GitHub scheduled jobs have timing and default-branch constraints. Verify current free-tier behavior before enabling them. When all games are final or canceled, atomically recompute results and claim the results emails by week, recipient and type. Reconcile ambiguous SMTP outcomes with provider evidence before retrying. Preserve game identity and past verification evidence across corrections. Recompute scores and audit any correction with the previous and replacement result. The owner should decide whether a corrected email is warranted.

## Private backups and recovery

1. Keep the migration sources and remote migration version list together. Before launch and before major changes, use a trusted local machine and the connection information in the Supabase **Connect** dialog. Keep the database password in the interactive prompt or an appropriately protected local PostgreSQL credential store.
2. Run the following as the database owner with a connection URL supplied through your private environment and a separate local password prompt or credential store. Confirm the file is written to a private directory outside the checkout. The archive contains application records, including Auth UUID links.

```sh
umask 077
pg_dump --dbname="$PICKEM_DB_URL" --schema=public --schema=pickem_private \
  --no-owner --format=custom --file=pickem.dump
pg_restore --list pickem.dump
```

3. Encrypt the archive with an owner-controlled key and retain it in private storage. Keep a separately encrypted record of seat-to-account mapping. The dump excludes the managed Auth schema and therefore needs existing or re-established Auth accounts. Preserve identity separately using the documented [Supabase backup and restore procedure](https://supabase.com/docs/guides/platform/migrating-within-supabase) if continuity of Auth UUIDs is required. Verify dashboard backup availability for the actual plan.
4. Rehearse recovery in a disposable, isolated Supabase environment with jobs and email disabled. Apply the migrations to recreate schema, privileges and policies. Restore compatible Auth identities first. If provisioning replacement accounts, restore participant records with the new UUIDs using a reviewed data mapping while preserving participant IDs and seat assignments. Restore application data with `pg_restore --data-only --exit-on-error --single-transaction --dbname="$RECOVERY_DB_URL" pickem.dump` only after required Auth UUIDs exist. A rehearsal with replacement identities requires preparing the remapped data before load. Compare counts, maximum IDs and next sequence values, then run participant isolation and pick-deadline checks.
5. For production recovery, pause scheduled jobs and pick writes, take a backup of the current state, and use the tested recovery path. Reconcile accepted and ambiguous email claims before resuming automation. Reapply Auth, redirect, API and SMTP settings as needed and retest the client after switching endpoints. Keep archives and connection strings outside Git and Actions logs.

## Phase 3 scoring and email infrastructure

The scoring RPC requires exactly five participants and a complete expected set of verified finals or verified cancellations. It retains the first scored roster when recalculating that week. Recompute and upsert the entire weekly result and season standings in one transaction. Equal points share rank and weekly wins. Weekly movement compares rank with the most recent earlier completed week. The frontend shows completed results only.

Proposals requiring owner approval are zero points for a tied NFL game, with that game retained in eligible-game counts; no points and no eligible game for a verified cancellation; and regular-season-only participation. An unsubmitted pick earns zero. A postponement after the original cutoff stays locked even if the kickoff moves forward. A pre-kickoff postponement can reopen only if the verified replacement time is installed before the prior cutoff and the game has never started or otherwise locked.

Reconcile a corrected official result and invoke the scoring RPC in the same trusted transaction. Preserve the existing game ID and original observed start. Use the approved expected fixture set when checking completeness. Canceled games still count toward that fixture set. Any overhaul of terminal status after a week is published requires a controlled reconciliation and owner review of earlier disclosures and emails.

For a future scheduler, pass the explicit competition week to the mail worker. Run Wednesday at 12:00 America/Los_Angeles with a same-Wednesday catch-up. The database checks local weekday/time and whether picks remain open. A results run may occur on any day once all expected games are terminal and scoring is complete. Recheck on later days for postponed games. Send using one claim per recipient/week/kind. Retry only an unequivocal failed delivery after the 15-minute cooldown, up to three attempts. A held claim or ambiguous response requires reconciliation. Provider acceptance, with a provider message identifier, is the recorded success condition. Keep the actual SMTP transport and schedules disabled until approved. The renderer and injected delivery transport have synthetic tests.
