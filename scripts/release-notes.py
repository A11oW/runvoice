#!/usr/bin/env python3
"""Извлекает описание выпуска из единственного журнала изменений."""
import pathlib, plistlib, re
root=pathlib.Path(__file__).resolve().parents[1]
version=plistlib.loads((root/'app/Info.plist').read_bytes())['CFBundleShortVersionString']
text=(root/'CHANGELOG.md').read_text()
match=re.search(r'^## \['+re.escape(version)+r'\][^\n]*\n(.*?)(?=^## |\Z)',text,re.M|re.S)
if not match:raise SystemExit('В CHANGELOG отсутствует раздел выпуска из Info.plist')
print(match.group(1).strip())
