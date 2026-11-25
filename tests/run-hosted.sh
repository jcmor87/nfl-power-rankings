#!/usr/bin/env bash
set +x
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v node >/dev/null || ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) < 20 ? 1 : 0)'; then
  printf '%s\n' 'FAIL configuration · Node.js 20 or later is required.' >&2
  exit 1
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --preflight ) ]]; then
  printf '%s\n' 'Usage: bash tests/run-hosted.sh [--preflight]' >&2
  exit 1
fi
read -r -p 'Hosted project origin (https://PROJECT.supabase.co): ' PICKEM_TEST_URL
read -r -p 'Retype the project origin after verifying the SQL checks: ' PICKEM_TEST_CONFIRM_ORIGIN
if ! [[ "$PICKEM_TEST_URL" =~ ^https://[a-z0-9-]+\.supabase\.co/?$ ]]; then
  printf '%s\n' 'FAIL configuration · Enter a hosted Supabase project origin without an API path.' >&2
  exit 1
fi
read -r -s -p 'Publishable API key: ' PICKEM_TEST_PUBLIC_KEY; printf '\n'
read -r -s -p 'Backend secret key for this test run: ' PICKEM_TEST_SERVICE_KEY; printf '\n'
if [[ "${1:-}" != --preflight ]]; then
  IFS= read -r -s -p 'Password for temporary seat 1: ' PICKEM_TEST_PASSWORD_1; printf '\n'
  IFS= read -r -s -p 'Password for temporary seat 2: ' PICKEM_TEST_PASSWORD_2; printf '\n'
  export PICKEM_TEST_PASSWORD_1 PICKEM_TEST_PASSWORD_2
fi
export PICKEM_TEST_EMAIL_1=pickem-test1@example.com
export PICKEM_TEST_EMAIL_2=pickem-test2@example.com
export PICKEM_TEST_URL PICKEM_TEST_CONFIRM_ORIGIN PICKEM_TEST_PUBLIC_KEY PICKEM_TEST_SERVICE_KEY
exec node supabase-live.mjs --hosted-existing "$@"
