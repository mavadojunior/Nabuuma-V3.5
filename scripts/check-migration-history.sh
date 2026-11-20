#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/docs/PRODUCTION_MIGRATION_RECOVERY_MANIFEST_2026-11-14.csv"
MIGRATIONS="$ROOT/supabase/migrations"

python3 - "$ROOT" "$MANIFEST" "$MIGRATIONS" <<'PY'
import csv
import hashlib
import re
import sys
from pathlib import Path

root, manifest_path, migrations_path = map(Path, sys.argv[1:])
with manifest_path.open(newline='') as handle:
    rows = list(csv.DictReader(handle))

expected = {}
for row in rows:
    version = row['version']
    name = row['name']
    if not re.fullmatch(r'\d{14}', version) or not re.fullmatch(r'[A-Za-z0-9_]+', name):
        raise SystemExit(f'Invalid manifest identity: {version}_{name}')
    if version in expected:
        raise SystemExit(f'Duplicate manifest version: {version}')
    expected[version] = row

if len(expected) != 69:
    raise SystemExit(f'Expected 69 recovered production migrations, found {len(expected)}')

active = sorted(migrations_path.glob('*.sql'))
local = {}
for path in active:
    match = re.fullmatch(r'(\d{14})_(.+)\.sql', path.name)
    if not match:
        raise SystemExit(f'Invalid active migration filename: {path.name}')
    version, name = match.groups()
    if version in local:
        raise SystemExit(f'Duplicate active migration timestamp: {version}')
    local[version] = (name, path)

for version, row in expected.items():
    if version not in local:
        raise SystemExit(f'Missing recovered migration: {version}_{row["name"]}.sql')
    name, path = local[version]
    if name != row['name']:
        raise SystemExit(f'Name mismatch for {version}: {name} != {row["name"]}')
    data = path.read_bytes()
    if len(data) != int(row['size_bytes']):
        raise SystemExit(f'Size mismatch for {path.name}')
    digest = hashlib.sha256(data).hexdigest()
    if digest != row['sha256']:
        raise SystemExit(f'SHA-256 mismatch for {path.name}')

latest_remote = max(expected)
pending = sorted(version for version in local if version not in expected)
old_pending = [version for version in pending if version <= latest_remote]
if old_pending:
    raise SystemExit('Unapplied migrations must be newer than production: ' + ', '.join(old_pending))

print(f'PASS: {len(expected)} recovered production migrations match the checked-in manifest.')
print(f'Latest production migration: {latest_remote}')
print('Pending local migrations: ' + (', '.join(pending) if pending else 'none'))
PY
