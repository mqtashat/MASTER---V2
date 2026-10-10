#!/usr/bin/env python3
"""التحقق من أن كل سطر غير فارغ في الملفات الأصلية موجود في الهيكل الجديد.

الاستخدام: python3 tools/verify_coverage.py [مسار نسخة الملفات الأصلية]
الافتراضي: docs/90-archive/v0.1.64-original (النسخة المجمدة داخل هذا المستودع).

المقارنة تتجاهل المسافات الطرفية ومسارات الروابط (لأنها حُدّثت للهيكل الجديد)،
ويُستثنى العنوان الرئيسي (# ) لكل ملف لأنه استُبدل بعنوان الملف الجديد.
يُبحث في الملفات السارية فقط، أي خارج docs/80-sources وdocs/90-archive.
"""
import os, re, sys, filecmp

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORIG = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'docs', '90-archive', 'v0.1.64-original')

def norm(l):
    return re.sub(r'\]\([^)]*\)', ']()', l).strip()

present = set()
for root, dirs, files in os.walk(ROOT):
    dirs[:] = [d for d in dirs if d != '.git']
    rel = os.path.relpath(root, ROOT)
    if rel.startswith(os.path.join('docs', '80-sources')) or rel.startswith(os.path.join('docs', '90-archive')):
        continue
    for f in files:
        if f.endswith('.md'):
            for l in open(os.path.join(root, f), encoding='utf-8'):
                present.add(norm(l))

files = ['README.md'] + sorted('docs/' + f for f in os.listdir(os.path.join(ORIG, 'docs')) if f.endswith('.md'))
missing = 0; checked = 0
for f in files:
    for n, l in enumerate(open(os.path.join(ORIG, f), encoding='utf-8'), 1):
        if not l.strip() or l.startswith('# '): continue
        checked += 1
        if norm(l) not in present:
            missing += 1
            print(f'مفقود: {f}:{n}: {l.strip()[:120]}')

# المصادر والأرشيف: تطابق بايت ببايت إن توفرت المجلدات الأصلية
pairs = [('docs/sources', 'docs/80-sources'), ('docs/history', 'docs/90-archive')]
diff = 0
for a, b in pairs:
    src = os.path.join(ORIG, a)
    if not os.path.isdir(src): continue
    for f in os.listdir(src):
        if not filecmp.cmp(os.path.join(src, f), os.path.join(ROOT, b, f), shallow=False):
            diff += 1; print(f'اختلاف: {a}/{f}')

print(f'الأسطر المفحوصة: {checked}، المفقودة: {missing}، ملفات مصدر مختلفة: {diff}')
sys.exit(1 if missing or diff else 0)
