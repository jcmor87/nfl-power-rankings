# Phase 4 · NFL data synchronization

## Provider evidence and launch limits

The owner’s authenticated BALLDONTLIE checks received NFL team records from the Teams endpoint and found 16 scheduled games in 2026 Week 12, 14 in Week 13, and 13 completed games in Week 11. The owner observed numerical final scores including overtime, 13 games in the 2025 postseason, and 15 finals plus one canceled game with null scores in 2022 Week 17. The provider’s postseason response uses weeks 1, 2, 3 and 5 for Wild Card, Divisional Round, Conference Championships and Super Bowl. The adapter queries the documented season/week and regular-season filters. It uses the owner-verified `postseason=true` request for postseason and filters the complete paginated inventory to the chosen round. Provider access uses the documented Authorization header. [NFL API reference](https://nfl.balldontlie.io/)

BALLDONTLIE lists Teams and Games on the free tier at five requests per minute. Its terms allow application use subject to Section 6 and third-party rights, and prohibit operating a substitute data API. Use the project’s authorized free key for this private competition and keep it out of the frontend. The provider makes no uptime, finality or correction guarantee. [Provider terms](https://www.balldontlie.io/terms.html)

The sync cross-checks the published [nflverse schedule release](https://github.com/nflverse/nflverse-data/releases/tag/schedules), distributed under its repository’s [CC BY 4.0 license](https://github.com/nflverse/nflverse-data/blob/main/LICENSE.md). It matches the full period by home and away team, compares UTC kickoff instants after converting the CSV’s Eastern wall time, and checks both numerical scores for a provider final. Postseason also uses fixed round counts. nflverse is a separate publication. Independent upstream score provenance and dataset-specific third-party rights remain unverified. No ESPN scraping or automated requests are included.

A fresh public CSV download parsed successfully. It contained 16 and 14 scheduled rows in Weeks 12 and 13, all 13 scored Week 11 rows, 6/4/2/1 scored postseason rows for 2025, and 15 scored 2022 Week 17 rows. BUF–CIN was absent. The CSV has no explicit cancellation or suspension state. An omitted matchup cannot corroborate cancellation. In that case the entire batch is rejected, affected scheduled games are held on an authorized write run, and the period stays incomplete. The reconciliation code can accept explicit corroboration from another permitted adapter once one is qualified. Live postponement, changed provider IDs, cross-week reassignment and correction propagation remain launch gates. Same-period rescheduling with a stable identity and a score correction with a newer timestamp were tested using synthetic data.

## Private iPad dry run

1. Open your private Codespace in Safari and check out `feature/nfl-family-pickem`. Use Node.js 22.21+ or Node.js 24. No Supabase key or database connection is needed. Leave this terminal private.
2. From the repository root, enter the provider key directly at the hidden terminal prompt. The subshell discards it after the command completes.

```bash
(
  set +x
  IFS= read -r -s -p 'BALLDONTLIE key: ' BALLDONTLIE_API_KEY
  printf '\n'
  export BALLDONTLIE_API_KEY
  node pickem-jobs/sync-nfl.mjs --season=2026 --phase=regular --week=12
)
```

3. Repeat with Week 13 or with `--season=2025 --phase=postseason --week=5` to sample the Super Bowl. Dry runs report aggregate counts and any kickoff disagreements with both source times and the chosen deadline. An incomplete, malformed or contradictory snapshot returns a nonzero exit and no write. If outbound connections require the environment’s HTTP proxy, Node.js 22.21+/24 supports `NODE_USE_ENV_PROXY=1`. Use it only in that environment. [Node CLI documentation](https://nodejs.org/api/cli.html#node_use_env_proxy1)
4. Keep `--apply` out of all validation commands. It is deliberately explicit and requires a matching `SUPABASE_URL` and `PICKEM_SYNC_CONFIRM_ORIGIN`, a backend `SUPABASE_SECRET_KEY`, and year 2026 or later. It sends one atomic snapshot RPC for the requested period. On a failed apply it attempts the separate idempotent schedule hold without replaying the write.

## Database upgrade and operating model

Review [the combined installer](../supabase/checks/install_pickem_phase4.sql) before any hosted execution. The installer checks the five Phase 3 versions and catalog, applies the two ordered Phase 4 migrations, verifies the result, records both versions and reloads PostgREST in one transaction. Run [the read-only verifier](../supabase/checks/verify_pickem_phase4.sql) separately and expect all 80 rows to pass. No Phase 4 migration was run against hosted Supabase for this PR.

- A period is uniquely identified by season, competition phase and week or round. Existing rows default to regular season. The database and frontend keep postseason distinct and cumulative standings include both phases.
- Sync adds missing teams and planned periods. It never activates a period. Stable provider IDs retain the same database game and picks on reschedule. Conflicting IDs or period moves are rejected before commit until source evidence supports a reconciliation design.
- Scheduled games from the automated feed need a current three-hour verification lease and remain subject to the database kickoff and permanent lock. Failed applied snapshots attempt an immediate hold. A total provider or DB outage stops new verification, so existing leases expire automatically. Existing verified results and permanent locks survive failures.
- Verified final scores, cancellations, and schedule changes create audit entries. An active complete period scores once all expected games are verified terminal. A corrected final recalculates weekly and season standings inside the same transaction. Duplicate snapshots do not duplicate matchups, picks, scores or change audit entries. Job runs are logged individually.
- The upgrade revokes `TRUNCATE`, `TRIGGER` and `REFERENCES` on Pick’em tables from the backend role and verifies their effective removal. Existing application RLS and participant permissions remain in place. The two sync RPCs are service-only.

## GitHub Actions and launch checklist

A manual **dry run** workflow is included. GitHub requires workflow dispatch definitions on the default branch for dispatch. Keep using the private Codespace before approval. Put no Supabase credential in the dry-run workflow. If and when the owner approves a rollout, configure `BALLDONTLIE_API_KEY` as an Actions secret. A separate protected write environment would also use `SUPABASE_SECRET_KEY`; project URL and the confirmation origin can be its variables. Restrict write jobs to the approved repository and branch.

The planned production cadence is an hourly coordinated job for the current approved period, with a separate offseason or upcoming-week dry run. A normal sync uses two BALLDONTLIE requests at least 15.1 seconds apart. The same pacing applies to pages and retries. One shared concurrency group should serialize jobs using the same key. The client honors bounded Retry-After and stops after three attempts per page. The workflow has no schedule and cannot apply. GitHub-hosted standard runners are free for public repositories. An hourly run is at most 744 starts per 31-day month or 3,720 runner minutes at the configured five-minute timeout. Recheck the budget before any move to private visibility. [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

- [ ] Verify the owner-key dry runs on both an upcoming week and a historical scored period.
- [ ] Qualify explicit independent cancellation evidence and validate upstream provenance and terms. Validate changed start times, cross-period moves, provider ID stability and score corrections over time.
- [ ] Review and explicitly approve applying Phase 4 to hosted Supabase. Verify all 80 hosted checks and rerun the hosted security suite before enrollment or activation.
- [ ] Verify planned periods stay hidden from participants and check the postseason labels in the private preview. Confirm outage holds, audit entries and scoring in a disposable project.
- [ ] Approve the next eligible full week and confirm its official kickoff times, expected matchups and all five seats. Approve a separate write workflow and any production schedule.
- [ ] Leave email delivery disabled until its separate acceptance checks pass.

Week 12 opens November 25 at 5:00 p.m. Pacific. The unresolved production gates make it unsuitable unless all are cleared before that kickoff. If the deadline passes, recommend Week 13 if readiness is established before its first kickoff, December 3 at 5:15 p.m. Pacific. Week 13 also requires owner approval. [Official Week 12 schedule](https://www.nfl.com/schedules/2026/by-week/week-12) · [Official Week 13 schedule](https://www.nfl.com/schedules/2026/by-week/week-13)

## Kickoff evidence and official week assignments

The two feeds must identify the same home and away teams in the requested period. When their kickoff instants are identical, the decision is `exact`. A disagreement of up to 15 minutes uses the earlier instant solely as a conservative pick deadline. The original BALLDONTLIE timestamp stays in `kickoff_at`, nflverse stays in `reference_kickoff_at`, and the database derives `pick_deadline_at` and `kickoff_reconciliation`. The frontend labels a disagreement and displays both reported kickoff times and the separate deadline. Dry-run output and database change audits retain both timestamps and the decision. Differences above 15 minutes, missing timestamps, mismatched matchups and conflicting final scores stop the sync. Cancellations still require explicit independent evidence.

The 2026 regular-season matchup table comes from the NFL’s official By Week schedule. We compared all 272 matchup assignments across all 18 weeks with the published nflverse release. For 2026 regular-season syncs the code requires the selected week’s official matchup set, an exact match from nflverse, and the same matchups from BALLDONTLIE before any database write. This uses published fixtures and makes no extra NFL request during a sync. An official cross-week reassignment requires updated official schedule evidence, and the importer rejects a remap while that is unresolved. The owner previously ran the two-provider dry runs for Weeks 11 and 12. Rerun the chosen launch week on the updated branch to apply the official check to authenticated BALLDONTLIE data. [Official 2026 NFL schedule release](https://media.nfl.com/football-information/2026/news/2026-nfl-schedule-announced)

### Install the incremental kickoff migration

Dry runs need no database migration. Before a future authorized write or a frontend preview that loads game data, verify Phase 4, then run the complete [kickoff evidence installer](../supabase/checks/install_pickem_kickoff_evidence.sql) once as postgres in the Supabase SQL Editor. It verifies the installed baseline versions and function bodies, applies migration `20261125000600` atomically, records the version, and reloads PostgREST. Run [kickoff evidence verification](../supabase/checks/verify_pickem_kickoff_evidence.sql) separately and expect 17 passing rows. The older Phase 4 verifier is for the pre-upgrade state.

The migration preserves existing games, picks and locks. Existing scheduled BALLDONTLIE games need fresh paired evidence before accepting new picks. A future reschedule cannot clear a permanent lock or reopen a previously passed earlier deadline. The three-hour schedule verification lease, failure holds and RLS remain enforced.
