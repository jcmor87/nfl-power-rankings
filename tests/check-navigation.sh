#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test -s pickem/index.html
test -s pickem/app.mjs
test -s pickem/styles.css
grep -Fq 'id="pickem-link" href="./pickem/"' index.html
grep -Fq 'function applyFilter(' index.html
