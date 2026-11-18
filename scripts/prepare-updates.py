#!/usr/bin/env python3
"""Готовит подписанные ZIP/appcast для ручной загрузки в GitHub Release."""
import argparse, hashlib, html, os, pathlib, plistlib, re, subprocess, tempfile, xml.etree.ElementTree as ET
root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--notes', type=pathlib.Path, required=True, help='Текст описания текущего релиза')
parser.add_argument('--key-file', type=pathlib.Path, help='Файл ключа вне репозитория; в CI используется SPARKLE_PRIVATE_KEY')
args = parser.parse_args()
def run(*cmd): return subprocess.check_output([str(c) for c in cmd],text=True).strip()
temporary_key = None
key_file = args.key_file
if os.environ.get('SPARKLE_PRIVATE_KEY'):
    temporary_key = tempfile.TemporaryDirectory(prefix='runvoice-sign-')
    key_file = pathlib.Path(temporary_key.name)/'key'
    key_file.write_text(os.environ['SPARKLE_PRIVATE_KEY'])
    key_file.chmod(0o600)
if key_file:
    key = run('swift', root/'scripts/update-key.swift', key_file)
    signing = ['--ed-key-file', str(key_file)]
else:
    key = run(root/'.build/sparkle/bin/generate_keys','--account','ai.opencode.runvoice.updates','-p')
    signing = ['--account','ai.opencode.runvoice.updates']
expected = plistlib.loads((root/'app/Info.plist').read_bytes())['SUPublicEDKey']
if key != expected: raise SystemExit('Закрытый ключ не соответствует открытому ключу Runvoice')
ns='http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle',ns)
out=root/'dist/updates';out.mkdir(exist_ok=True)
notes=args.notes.read_text()
for arch in ['arm64','intel']:
    app=root/f'dist/Runvoice-{arch}.app'
    meta=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    version=meta['CFBundleVersion'];display=meta['CFBundleShortVersionString']
    if meta.get('SUPublicEDKey') != expected: raise SystemExit('В приложении другой ключ обновлений')
    if not re.fullmatch(r'\d+(\.\d+)*',version): raise SystemExit('Некорректный номер сборки')
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    archive=out/f'Runvoice-{display}-{arch}-update.zip'
    with tempfile.TemporaryDirectory(prefix='runvoice-update-') as staging:
        staged=pathlib.Path(staging)/'Runvoice.app'
        subprocess.run(['ditto',str(app),str(staged)],check=True)
        subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',str(staged),str(archive)],check=True)
    signature=run(root/'.build/sparkle/bin/sign_update',*signing,'-p',archive)
    subprocess.run([str(root/'.build/sparkle/bin/sign_update'),*signing,'--verify',str(archive),signature],check=True)
    rss=ET.Element('rss',version='2.0');channel=ET.SubElement(rss,'channel')
    ET.SubElement(channel,'title').text='Runvoice'
    item=ET.SubElement(channel,'item');ET.SubElement(item,'title').text=f'Runvoice {display}'
    ET.SubElement(item,f'{{{ns}}}version').text=version
    ET.SubElement(item,f'{{{ns}}}shortVersionString').text=display
    ET.SubElement(item,f'{{{ns}}}minimumSystemVersion').text=meta['LSMinimumSystemVersion']
    ET.SubElement(item,'description').text='<pre>'+html.escape(notes)+'</pre>'
    ET.SubElement(item,'enclosure',url=f'https://github.com/A11oW/runvoice/releases/download/v{display}/{archive.name}',length=str(archive.stat().st_size),type='application/octet-stream',attrib={f'{{{ns}}}edSignature':signature})
    feed=out/f'appcast-{arch}.xml'
    ET.ElementTree(rss).write(feed,encoding='utf-8',xml_declaration=True)
    # Подписываем также ленту; архивы всегда проходят обязательную EdDSA-проверку Sparkle.
    run(root/'.build/sparkle/bin/sign_update',*signing,feed)
    (out/(archive.name+'.sha256')).write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+'  '+archive.name+'\n')
print('Файлы подготовлены в dist/updates/. Тег релиза: v'+display)
print('Загрузите оба ZIP, SHA-256 и appcast-*.xml в один стабильный GitHub Release, назначенный Latest.')

if temporary_key: temporary_key.cleanup()
