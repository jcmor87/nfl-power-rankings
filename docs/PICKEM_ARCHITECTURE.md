# NFL Family Pick’em architecture

## Repository and deployment

On November 24, 2026, the live Power Rankings page returned HTTP 200. The GitHub Pages API reported a built site with HTTPS enforced, publishing from the root of `main`. The baseline repository contains `README.md` and `index.html`. The dashboard uses a responsive three-column grid with narrower layouts at CSS breakpoints. Its inline script derives division membership from navigation links, toggles team rows for league, AFC, NFC and division choices, and restores the selection from the URL hash. No workflow is tracked in the repository. The owner should identify any external Tuesday publishing job before adding a Pick’em navigation link in a later phase.

The draft adds database migrations and an offline adapter. It introduces no Pages route, workflow or production deployment. The future static client lives at `/nfl-power-rankings/pickem/`, uses Supabase Auth and calls `submit_pick` with the game and selected team IDs. A separate trusted job will verify schedules and results, reconcile scoring and deliver email.

## Source checks

Spot checks on November 24, 2026 used ESPN’s [NFL scoreboard endpoint](https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard). Requests with `dates=<season>&seasontype=2&week=<week>&limit=100` returned HTTP 200 for the cases below.

| Request | Observed response |
| --- | --- |
| No parameters | 2026 Week 11, 13 finals |
| 2026 Week 12 | 16 scheduled games, earliest November 25 at 5:00 p.m. Pacific |
| 2026 Week 13 | 14 scheduled games, earliest December 3 at 5:15 p.m. Pacific |
| 2025 Week 1 | 16 finals with string scores |
| 2022 Week 17 | 15 finals and one cancellation |
| 2026 Week 99 | No season, week or events, despite HTTP 200 |

Events provide season, season type, week, provider event ID, competition date with timezone offset, time validity, home and away team IDs, and a status object with name, state and completed flag. Scheduled games can carry zero placeholders for scores. Treat provider IDs as source-scoped. Keep a canonical matchup identity and reconcile cross-provider IDs before switching feeds. For postponements and suspensions, retain the same canonical game and its history, keep picks locked while unresolved, and only reopen an unstarted game after the new kickoff is verified. This probe did not capture a live postponement or a historical correction over time. Corrections need a reconciliation job that compares previously stored finals, audits the change and recalculates affected results.

The [Disney Terms of Use](https://disneytermsofuse.com/english/) restrict automated access and extraction of covered products. Public reachability gives no license or uptime guarantee. No authorization to poll ESPN was established. Keep ESPN out of automated production jobs absent documented permission.

The [official NFL schedule](https://www.nfl.com/schedules/) was reachable. The tested direct Week 13 URL redirected to the general schedule, so the response did not establish an official machine-readable week feed. Use official schedules and game centers for manual verification pending an authorized feed. The [nflverse schedule CSV](https://github.com/nflverse/nfldata/blob/master/data/games.csv) was reachable and matched every ESPN event ID and kickoff instant for the two sampled 2026 weeks when its displayed times were interpreted as Eastern. Shared identifiers may reflect shared upstream sources. The CSV has no explicit per-game status field, so a blank score is insufficient to distinguish unplayed, postponed or canceled games. Confirm dataset-specific terms, provenance, freshness and status coverage before relying on it in production. See [nflverse data documentation](https://nflverse.nflverse.com/).

`pickem-data/espn.mjs` accepts a captured payload and requested season/week. It emits normalized observations with source and team identifiers, kickoff, status and scores. It rejects invalid identity, mixed weeks, duplicate games and empty responses. Invalid or tentative kickoff is null and unrecognized status is unknown. Implement other providers against the same observation shape. The caller must verify completeness against an expected matchup list, reconcile provider identities, and independently confirm finals before setting `final_verified_at`. No network calls or writes are part of the adapter.

## Database

- `participants` links five numbered seats to Supabase Auth users. Stable participant UUIDs preserve history independently of login identity.
- `seasons`, `weeks`, `teams` and `games` hold league structure, expected game counts, source identifiers and verification state. Competition weeks start as planned.
- `picks` enforces one row per participant and game. The RPC locks the game and checks database time after acquiring its locks.
- `weekly_results` and `season_standings` reserve storage for deterministic scoring and shared ranks. Participant read access remains disabled pending scoring and disclosure tests.
- `email_log` reserves a unique claim per week, recipient and message type. `job_runs` and `audit_log` are service-only operational records.

Later scoring must award one point per correct winner, zero for missed or tied games, and exclude canceled games. Reconcile complete expected matchup sets before finalizing weeks. Keep scoring provisional for incomplete weeks, retain historical results, and recompute from canonical games and picks when an official result changes.

Week 12 is the upcoming full-week candidate as of November 24. If production readiness misses its first kickoff, obtain explicit approval for the next eligible full week and reverify its schedule before activation.

## Phase 2 source follow-up

The direct NFL weekly schedule route and nflverse’s published release were subsequently validated for 2026 Weeks 12 and 13. The [nflverse evaluation](PICKEM_NFLVERSE.md) records the licensing basis, historical schedule and score samples, status gaps and manual official fallback.

## Phase 5 email processing

A protected GitHub Actions workflow polls the service-only mail planning RPC after the hourly NFL synchronization. The database gates reminders in Pacific time and results on completed verified scoring. A transactional claim reserves each period, message kind and recipient. The worker renders HTML and plain text, submits the message to Brevo and records provider acceptance and observed delivery events separately. The private preview supports synthetic data. The production GitHub Pages sign-in uses only the project origin and publishable key.
