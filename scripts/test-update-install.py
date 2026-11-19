#!/usr/bin/env python3
"""Настоящая установка Sparkle только в изолированной тестовой копии."""
import functools,http.server,json,os,pathlib,plistlib,socket,subprocess,threading,time,uuid,xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parents[1]; base=root/'.build/updater/e2e';base.mkdir(parents=True,exist_ok=True)
for name in ['installed-marker','waiting-marker']:
    (base/name).unlink(missing_ok=True)
framework=root/'.build/sparkle'
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(base)))
threading.Thread(target=server.serve_forever,daemon=True).start()
port=server.server_port
# Одноразовый тестовый ключ; рабочий ключ проекта не используется и не экспортируется.
key_file=base/'test-private-key'
key_source=base/'test-key.swift'
key_source.write_text('import Foundation\nimport CryptoKit\nlet k=Curve25519.Signing.PrivateKey()\ntry k.rawRepresentation.base64EncodedString().write(toFile:CommandLine.arguments[1],atomically:true,encoding:.utf8)\nprint(k.publicKey.rawRepresentation.base64EncodedString())\n')
public_key=subprocess.check_output(['swift',str(key_source),str(key_file)],text=True).strip()
key_file.chmod(0o600)
old=base/'current/Runvoice.app'; new=base/'next/Runvoice.app'
for app in [old,new]:
    (app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
    (app/'Contents/Frameworks').mkdir(exist_ok=True)
    subprocess.run(['ditto',str(framework/'Sparkle.framework'),str(app/'Contents/Frameworks/Sparkle.framework')],check=True)
args=['swiftc','-F',str(framework),'-framework','Sparkle','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',str(root/'app/Core/UpdateCoordinator.swift'),str(root/'app/App/SparkleUpdateBackend.swift'),str(root/'tests/updates/Probe.swift'),'-o',str(old/'Contents/MacOS/Probe')]
# Top-level Swift requires main.swift when there are multiple source files.
main=base/'main.swift';main.write_text((root/'tests/updates/Probe.swift').read_text().replace('#filePath',json.dumps(str(root/'tests/updates/Probe.swift'))))
args[args.index(str(root/'tests/updates/Probe.swift'))]=str(main)
subprocess.run(args,check=True)
subprocess.run(['ditto',str(old/'Contents/MacOS/Probe'),str(new/'Contents/MacOS/Probe')],check=True)
meta={'CFBundleIdentifier':'ai.opencode.runvoice.update-test.'+uuid.uuid4().hex,'CFBundleExecutable':'Probe','CFBundleName':'Runvoice Update Test','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1.0','LSMinimumSystemVersion':'15.0','SUPublicEDKey':public_key,'SUFeedURL':f'http://127.0.0.1:{port}/appcast.xml','SUEnableAutomaticChecks':False,'SUAutomaticallyUpdate':False,'SURequireSignedFeed':True,'SUVerifyUpdateBeforeExtraction':True,'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True,'NSAllowsArbitraryLoads':True}}
for app,v in [(old,'1.0'),(new,'2.0')]:
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(meta,CFBundleVersion=v,CFBundleShortVersionString=v)))
    subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
archive=base/'update.zip'
subprocess.run(['ditto','-c','-k','--keepParent',str(new),str(archive)],check=True)
def sign(p):return subprocess.check_output([str(framework/'bin/sign_update'),'--ed-key-file',str(key_file),'-p',str(p)],text=True).strip()
sig=sign(archive)
feed=base/'appcast.xml'
feed.write_text(f'''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Test</title><item><title>Test 2.0</title><sparkle:version>2.0</sparkle:version><sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion><enclosure url="http://127.0.0.1:{port}/update.zip" length="{archive.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{sig}"/></item></channel></rss>''')
sign(feed)
private=base/'home';private.mkdir(exist_ok=True)
(private/'preserved-data').write_text('settings/models/history remain here')
with (base/'probe.log').open('w') as log:
    process=subprocess.Popen([str(old/'Contents/MacOS/Probe')],env=dict(os.environ,CFFIXED_USER_HOME=str(private)),stdout=log,stderr=log)
    try:
        deadline=time.monotonic()+150
        while not (base/'installed-marker').exists() and time.monotonic()<deadline:time.sleep(.25)
        assert (base/'installed-marker').exists(), 'Update/relaunch failed: see '+str(base/'probe.log')
        assert (base/'waiting-marker').exists(), 'Busy gate was not exercised'
        assert plistlib.loads((old/'Contents/Info.plist').read_bytes())['CFBundleVersion']=='2.0'
        assert (private/'preserved-data').read_text()=='settings/models/history remain here'
        subprocess.run(['codesign','--verify','--deep','--strict',str(old)],check=True)
    finally:
        if process.poll() is None:process.terminate()
        process.wait(timeout=10);server.shutdown()
# Отдельно проверяем отказ подписи повреждённого архива, не запуская установку.
corrupt=base/'corrupt.zip';corrupt.write_bytes(archive.read_bytes()+b'corrupt')
failed=subprocess.run([str(framework/'bin/sign_update'),'--ed-key-file',str(key_file),'--verify',str(corrupt),sig],capture_output=True)
assert failed.returncode!=0
print('OK: Sparkle installed/relaunched isolated 1.0 -> 2.0, waited for idle, preserved data, rejected damaged archive')
