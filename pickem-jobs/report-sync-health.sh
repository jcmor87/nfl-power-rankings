#!/usr/bin/env bash
set -euo pipefail

title='Pick’em synchronization needs attention'
marker='<!-- pickem-sync-incident -->'
reason='A production NFL sync failed or found expiring or expired pick verification leases.'
resolution='This issue stays open while the incident persists and closes after a successful automatic-selection sync.'
if [[ "${INCIDENT_SCOPE:-}" == email ]]; then
  title='Pick’em email needs attention'
  marker='<!-- pickem-email-incident -->'
  reason='A production email job failed or found a delivery that needs reconciliation.'
  resolution='This issue closes after a successful production email check.'
fi
case "${SYNC_RESULT:-}" in cancelled) SYNC_RESULT=failure ;; success|failure) ;; *) exit 0 ;; esac

# Only this workflow's bot-authored, marked issue is eligible for deduplication.
number=$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues?state=open&per_page=100"   --jq '.[] | select(.user.login == "github-actions[bot]" and .title == "'"$title"'" and ((.body // "") | startswith("'"$marker"'"))) | .number' |
  sed -n '1p')
if [[ -n "$number" && ! "$number" =~ ^[1-9][0-9]*$ ]]; then exit 1; fi

if [[ "$SYNC_RESULT" == failure && -z "$number" ]]; then
  {
    printf '%s\n\n' "$marker"
    printf '%s\n\n' "$reason"
    printf 'Review the sanitized workflow summary and run logs at %s/%s/actions/runs/%s.\n\n' \
      "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
    printf '%s\n' "$resolution"
  } | gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" \
    --assignee "$GITHUB_REPOSITORY_OWNER" --body-file -
elif [[ "$SYNC_RESULT" == success && "${FULL_RUN:-}" == true && -n "$number" ]]; then
  gh issue close "$number" --repo "$GITHUB_REPOSITORY"
fi
