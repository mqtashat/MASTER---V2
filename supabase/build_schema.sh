#!/usr/bin/env bash
# يجمع ملفات الترحيل بالترتيب في supabase/schema.sql لتطبيقها دفعة واحدة في SQL Editor.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
{
  echo "-- ماستر: ملف قاعدة البيانات المجمّع — مولَّد آليًا من supabase/migrations، لا تعدّله يدويًا."
  for f in "$DIR"/migrations/*.sql; do
    echo; echo "-- >>> $(basename "$f")"; cat "$f"
  done
} > "$DIR/schema.sql"
echo "ok: supabase/schema.sql"
