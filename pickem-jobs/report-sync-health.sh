#!/usr/bin/env bash
set -euo pipefail

title='Pick’em synchronization needs attention'
marker='<!-- pickem-sync-incident -->'
case "${SYNC_RESULT:-}" in cancelled) SYNC_RESULT=failure ;; success|failure) ;; *) exit 0 ;; esac

# Only this workflow's bot-authored, marked issue is eligible for deduplication.
number=$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues?state=open&per_page=100"   --jq '.[] | select(.user.login == "github-actions[bot]" and .title == "Pick’em synchronization needs attention" and ((.body // "") | startswith("<!-- pickem-sync-incident -->"))) | .number' |
  sed -n '1p')
if [[ -n "$number" && ! "$number" =~ ^[1-9][0-9]*$ ]]; then exit 1; fi

if [[ "$SYNC_RESULT" == failure && -z "$number" ]]; then
  {
    printf '%s\n\n' "$marker"
    printf '%s\n\n' 'A production NFL sync failed or found expiring or expired pick verification leases.'
    printf 'Review the sanitized workflow summary and run logs at %s/%s/actions/runs/%s.\n\n' \
      "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
    printf '%s\n' 'This issue stays open while the incident persists and closes after a successful automatic-selection sync.'
  } | gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" \
    --assignee "$GITHUB_REPOSITORY_OWNER" --body-file -
elif [[ "$SYNC_RESULT" == success && "${FULL_RUN:-}" == true && -n "$number" ]]; then
  gh issue close "$number" --repo "$GITHUB_REPOSITORY"
fi
