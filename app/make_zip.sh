#!/usr/bin/env bash
# يولّد ملف ZIP لكود التطبيق (دون node_modules وdist) للرفع إلى Google AI Studio.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist-zip"; mkdir -p "$OUT"; rm -f "$OUT/master-app.zip"
cd "$ROOT/app"
python3 - "$OUT/master-app.zip" <<'PY'
import os, sys, zipfile
skip = {'node_modules', 'dist', '.env', '.env.local'}
with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as z:
    for base, dirs, files in os.walk('.'):
        dirs[:] = [d for d in dirs if d not in skip]
        for f in files:
            if f in skip or f == 'make_zip.sh':
                continue
            p = os.path.join(base, f)
            z.write(p, os.path.relpath(p, '.'))
PY
echo "ok: dist-zip/master-app.zip"
