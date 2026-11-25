#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
read -r -p 'Hosted project origin (https://PROJECT.supabase.co): ' PICKEM_TEST_URL
[[ "$PICKEM_TEST_URL" =~ ^https://[a-z0-9-]+\.supabase\.co$ ]] || exit 1
read -r -p 'Retype the project origin after verifying the SQL checks: ' PICKEM_TEST_CONFIRM_ORIGIN
[[ "$PICKEM_TEST_CONFIRM_ORIGIN" == "$PICKEM_TEST_URL" ]] || exit 1
read -r -s -p 'Publishable API key: ' PICKEM_TEST_PUBLIC_KEY; printf '\n'
read -r -s -p 'Backend secret key for this test run: ' PICKEM_TEST_SERVICE_KEY; printf '\n'
read -r -s -p 'Password for temporary seat 1: ' PICKEM_TEST_PASSWORD_1; printf '\n'
read -r -s -p 'Password for temporary seat 2: ' PICKEM_TEST_PASSWORD_2; printf '\n'
export PICKEM_TEST_EMAIL_1=pickem-test1@example.com
export PICKEM_TEST_EMAIL_2=pickem-test2@example.com
export PICKEM_TEST_URL PICKEM_TEST_CONFIRM_ORIGIN PICKEM_TEST_PUBLIC_KEY PICKEM_TEST_SERVICE_KEY
export PICKEM_TEST_PASSWORD_1 PICKEM_TEST_PASSWORD_2
exec node supabase-live.mjs --hosted-existing
