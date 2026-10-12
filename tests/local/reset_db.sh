#!/usr/bin/env bash
# إعادة إنشاء قاعدة الاختبار المحلية وتطبيق المحاكاة ثم الترحيلات بالترتيب.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="${PGHOST:-/tmp}"; PORT="${PGPORT:-54322}"; DB="${PGDATABASE:-master_test}"
psql -h "$HOST" -p "$PORT" -U postgres -qAt -c "set client_min_messages=warning" -c "drop database if exists $DB with (force)" -c "create database $DB" >/dev/null
for f in "$ROOT"/tests/local/00_supabase_stub.sql "$ROOT"/supabase/migrations/*.sql; do
  PGOPTIONS="-c client_min_messages=warning" psql -h "$HOST" -p "$PORT" -U postgres -d "$DB" -q -v ON_ERROR_STOP=1 -f "$f" >/dev/null
done
echo "ok: $DB"
