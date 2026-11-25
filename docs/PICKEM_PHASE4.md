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
- The base sync RPC adds missing teams and planned periods. The family automation RPC can then activate ready periods prospectively under the launch safeguards below. Stable provider IDs retain the same database game and picks on reschedule. Conflicting IDs or period moves are rejected before commit until source evidence supports a reconciliation design.
- Scheduled games from the automated feed need a current three-hour verification lease and remain subject to the database kickoff and permanent lock. Failed applied snapshots attempt an immediate hold. A total provider or DB outage stops new verification, so existing leases expire automatically. Existing verified results and permanent locks survive failures.
- Verified final scores, cancellations, and schedule changes create audit entries. An active complete period scores once all expected games are verified terminal. A corrected final recalculates weekly and season standings inside the same transaction. Duplicate snapshots do not duplicate matchups, picks, scores or change audit entries. Job runs are logged individually.
- The upgrade revokes `TRUNCATE`, `TRIGGER` and `REFERENCES` on Pick’em tables from the backend role and verifies their effective removal. Existing application RLS and participant permissions remain in place. The two sync RPCs are service-only.

## GitHub Actions and launch checklist

**Pickem NFL synchronization** supports manual dry runs and protected production sync. The scheduled trigger is hourly at minute 17 UTC. Both scheduled and manually dispatched writes require the repository variable `PICKEM_NFL_SYNC_ENABLED=true`, `main`, and the `pickem-production` environment. Dry runs remain available with the switch off. GitHub runs schedules from the default branch. [GitHub workflow events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)

### One-time owner setup

1. In **Settings → Environments → pickem-production**, keep deployments restricted to `main` with administrator bypass disabled. Keep `SUPABASE_SECRET_KEY` and `SUPABASE_URL` in the environment and `BALLDONTLIE_API_KEY` in the existing repository secret. The workflow no longer uses `PICKEM_SYNC_PERIODS`.
2. After the eight existing migrations pass verification, review and run the [family automation installer](../supabase/checks/install_pickem_family_automation.sql) once as postgres in Supabase SQL Editor. Check all three rows in the [read-only verifier](../supabase/checks/verify_pickem_family_automation.sql). The new RPC restricts family writes to 2026 regular-season Weeks 13–18 and postseason rounds 1, 2, 3 and 5. It reuses the existing sync and only activates fully corroborated, still-future slates when exactly five participants are active and Week 13 has opened or is the period being opened. If Week 13 misses its start, later periods stay planned pending an explicit scope decision.
3. After an approved merge, use **Actions → Pickem NFL synchronization → Run workflow**. Choose **dry-run**, then specify season, phase and week. After approving production writes, use **apply** on `main` with the period override blank for automatic selection. For troubleshooting, the optional **periods** input accepts up to four in-scope periods, such as `2026:regular:13,2026:postseason:5`. Historical dry runs remain unrestricted by the family start; apply overrides cannot backfill earlier competition weeks.
4. Keep **Settings → Secrets and variables → Actions → Variables → PICKEM_NFL_SYNC_ENABLED** unset or false until explicitly approved. Set it to `true` only after approving the automated rollout, the five approved participants and the Week 13 start. Set it false to stop new scheduled and manual production jobs. A running job can finish.
5. Keep GitHub Issues enabled and allow the GitHub Actions token to create and close issues. Watch for GitHub notifications from the owner-assigned **Pick’em synchronization needs attention** incident. GitHub notification delivery follows the owner’s account preferences. The workflow has no email transport and uses no paid monitoring service.

### Selection, failure handling and alerts

The hourly job loads one nflverse snapshot, selects periods within seven days of kickoff and follows unresolved active periods until scoring completes. Completed periods stay in the hourly correction window for two days after the last listed kickoff, then one eligible completed period is revisited in rotation at 12:17 UTC until 14 days after its last kickoff. A manual override can revisit older in-scope results. New postseason rounds wait for full matchup identities. Undetermined slots and feed lag before kickoff do not insert games. Existing active periods stay under strict reconciliation even if coverage goes missing.

The shared Actions concurrency group serializes manual and scheduled runs. GitHub may replace a pending run, and the database also serializes applies with its advisory lock. A failed period uses the existing hold RPC where its scope is known. When the database or discovery feed is unavailable, existing leases still expire and keep picks locked. Verified finals and permanent locks survive failures. Verified result changes invoke the existing scoring procedure.

The production run checks active scheduled games after sync and flags a missing, expired or within-one-hour lease when it affects a still-open pick window. A failed or unhealthy run opens one owner-assigned, bot-authored incident issue with a run link. Further failures leave the same issue open. A successful healthy automatic-selection run closes it. A targeted override leaves the issue open until the full check passes. No provider data, secret or response body goes in the issue. GitHub’s own workflow notifications are separate. Keep those preferences in mind if duplicate alerts arrive. A dropped trigger or a fully unavailable GitHub Actions service cannot produce a workflow-generated alert.

### Free-tier estimates

Estimates assume hourly checks, a 31-day month, one page per provider query, and no manual runs or retries. A typical active hour covers one to three periods. The ceiling below assumes all ten eligible periods overlap.

| Service | Typical daily / monthly | All-ten-period ceiling |
| --- | --- | --- |
| BALLDONTLIE | 48–96 / 1,488–2,976 requests | 264 / 8,184 requests |
| Supabase | 72–120 / 2,232–3,720 API calls | 288 / 8,928 calls |
| GitHub Actions | 24 / 744 hourly runs, up to two standard jobs per run | Up to 312 runner minutes per day or 9,672 per month at the configured timeouts |

BALLDONTLIE uses one Teams call plus one Games call per selected period and skips both if none are due. The shared client spaces requests 15.1 seconds apart, at most four starts in a rolling minute, within the documented free limit of five. Pagination and retries increase totals, and pacing still applies. The public workflow uses standard Ubuntu runners, free at the repository’s current visibility. [BALLDONTLIE tiers](https://nfl.balldontlie.io/#account-tiers) · [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

Supabase performs two reads and one atomic write or hold per selected period. The season scope is at most 109 games and 545 picks for five players. Updates reuse game rows. At three periods every hour, expect at most 2,232 routine job-log rows a month. At a planning allowance of 1 KiB per row that is roughly 2.2 MiB before other tables and database overhead; the hosted footprint was not measured. Supabase documents 500 MB of database storage, 5 GB egress and unlimited API requests on Free. Review database size if repeated outages or extended retention grow the operational log. [Supabase Free limits](https://supabase.com/pricing)

- [ ] Verify the owner-key dry runs on both an upcoming week and a historical scored period.
- [ ] Qualify explicit independent cancellation evidence and validate upstream provenance and terms. Validate changed start times, cross-period moves, provider ID stability and score corrections over time.
- [x] Owner applied all eight hosted migrations and passed hosted verification and security tests.
- [ ] Verify planned periods stay hidden from participants and check the postseason labels in the private preview. Confirm outage holds, audit entries and scoring in a disposable project.
- [ ] Approve the competition period and confirm expected matchups and all five seats before activation. Approve merge, the family automation migration and enabling the master switch separately.
- [ ] Leave email delivery disabled until its separate acceptance checks pass.

Week 12 opens November 25 at 5:00 p.m. Pacific. The unresolved production gates make it unsuitable unless all are cleared before that kickoff. If the deadline passes, recommend Week 13 if readiness is established before its first kickoff, December 3 at 5:15 p.m. Pacific. Week 13 also requires owner approval. [Official Week 12 schedule](https://www.nfl.com/schedules/2026/by-week/week-12) · [Official Week 13 schedule](https://www.nfl.com/schedules/2026/by-week/week-13)

## Kickoff evidence and official week assignments

The two feeds must identify the same home and away teams in the requested period. When their kickoff instants are identical, the decision is `exact`. A disagreement of up to 15 minutes uses the earlier instant solely as a conservative pick deadline. The original BALLDONTLIE timestamp stays in `kickoff_at`, nflverse stays in `reference_kickoff_at`, and the database derives `pick_deadline_at` and `kickoff_reconciliation`. The frontend labels a disagreement and displays both reported kickoff times and the separate deadline. Dry-run output and database change audits retain both timestamps and the decision. Differences above 15 minutes, missing timestamps, mismatched matchups and conflicting final scores stop the sync. Cancellations still require explicit independent evidence.

The 2026 regular-season matchup table comes from the NFL’s official By Week schedule. We compared all 272 matchup assignments across all 18 weeks with the published nflverse release. For 2026 regular-season syncs the code requires the selected week’s official matchup set, an exact match from nflverse, and the same matchups from BALLDONTLIE before any database write. This uses published fixtures and makes no extra NFL request during a sync. An official cross-week reassignment requires updated official schedule evidence, and the importer rejects a remap while that is unresolved. The owner previously ran the two-provider dry runs for Weeks 11 and 12. Rerun the chosen launch week on the updated branch to apply the official check to authenticated BALLDONTLIE data. [Official 2026 NFL schedule release](https://media.nfl.com/football-information/2026/news/2026-nfl-schedule-announced)

### Install the incremental kickoff migration

Dry runs need no database migration. Before a future authorized write or a frontend preview that loads game data, verify Phase 4, then run the complete [kickoff evidence installer](../supabase/checks/install_pickem_kickoff_evidence.sql) once as postgres in the Supabase SQL Editor. It verifies the installed baseline versions and function bodies, applies migration `20261125000600` atomically, records the version, and reloads PostgREST. Run [kickoff evidence verification](../supabase/checks/verify_pickem_kickoff_evidence.sql) separately and expect 17 passing rows. The older Phase 4 verifier is for the pre-upgrade state.

The migration preserves existing games, picks and locks. Existing scheduled BALLDONTLIE games need fresh paired evidence before accepting new picks. A future reschedule cannot clear a permanent lock or reopen a previously passed earlier deadline. The three-hour schedule verification lease, failure holds and RLS remain enforced.
