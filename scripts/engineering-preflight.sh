#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

printf '%s\n' 'Nabuuma V3.5 engineering preflight'
printf '%s\n' 'Repository: '"$ROOT"
printf '%s\n' 'Branch: '"$(git branch --show-current)"
printf '%s\n'

printf '%s\n' '1/3 — Recovered production migration history'
bash scripts/check-migration-history.sh

printf '%s\n'

printf '%s\n' '2/3 — Unstaged diff whitespace check'
git diff --check
printf '%s\n' 'PASS: unstaged diff has no whitespace errors'

printf '%s\n'
printf '%s\n' '3/3 — Staged diff whitespace check'
git diff --cached --check
printf '%s\n' 'PASS: staged diff has no whitespace errors'

printf '%s\n'
printf '%s\n' 'Preflight passed. This is a static/local preflight only.'
printf '%s\n' 'It does not run PostgreSQL tests, hosted CI, staging checks, or production verification.'
