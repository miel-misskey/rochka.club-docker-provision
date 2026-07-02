#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Stage 0: pre-flight — 旧DBのスキーマ / 適用済みマイグレーションを取得
# ─────────────────────────────────────────────────────────────
set -euo pipefail

OLD_SSH="${OLD_SSH:-ssh -i $HOME/.ssh/miel-servers -o StrictHostKeyChecking=accept-new root@118.27.110.132}"
OLD_DB="${OLD_DB:-mk1}"
OUT="${OUT:-$(dirname "$0")/tmp}"
mkdir -p "$OUT"

echo "==> dump old schema-only -> $OUT/old-schema.sql"
$OLD_SSH "sudo -u postgres pg_dump --schema-only --no-owner '$OLD_DB'" > "$OUT/old-schema.sql"

echo "==> dump applied migrations -> $OUT/old-migrations.txt"
$OLD_SSH "sudo -u postgres psql -tAqd '$OLD_DB' -c 'select name from migrations order by name;'" > "$OUT/old-migrations.txt"

echo "==> dump public columns -> $OUT/old-columns.txt"
$OLD_SSH "sudo -u postgres psql -tAqd '$OLD_DB' -c \"select table_name||'.'||column_name||' '||data_type from information_schema.columns where table_schema='public' order by table_name, ordinal_position;\"" > "$OUT/old-columns.txt"

mig=$(wc -l < "$OUT/old-migrations.txt" | tr -d ' ')
col=$(wc -l < "$OUT/old-columns.txt" | tr -d ' ')
echo
echo "migrations applied: $mig (vanilla v12.119.2 ~= 154)"
echo "public columns:     $col"
echo "review: no fork-only migration names; matches upstream misskey@12.119.2 migration dir before Stage 1"
