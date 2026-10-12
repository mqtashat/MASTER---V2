#!/usr/bin/env python3
"""فحص الروابط الداخلية في ملفات Markdown.

الاستخدام: python3 tools/check_links.py
يتجاهل الروابط الخارجية ومجلد docs/90-archive (نسخ مجمدة بروابطها الأصلية).
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINK = re.compile(r'\]\(([^)#\s]+)(?:#[^)]*)?\)')
bad = 0; total = 0
for root, dirs, files in os.walk(ROOT):
    # node_modules تبعيات خارجية غير متتبعة في git
    dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules') and not os.path.join(root, d).endswith(os.path.join('docs', '90-archive'))]
    for f in files:
        if not f.endswith('.md'): continue
        p = os.path.join(root, f)
        fence = False
        for n, line in enumerate(open(p, encoding='utf-8'), 1):
            if line.lstrip().startswith(('```', '~~~')):
                fence = not fence
            if fence: continue
            for t in LINK.findall(line):
                if re.match(r'^[a-z]+:', t): continue
                total += 1
                if not os.path.exists(os.path.normpath(os.path.join(root, t))):
                    bad += 1
                    print(f'{os.path.relpath(p, ROOT)}:{n}: رابط مكسور → {t}')
print(f'الروابط الداخلية: {total}، المكسورة: {bad}')
sys.exit(1 if bad else 0)
