#!/usr/bin/env python3
"""Изолированный ASR/API на синтетической речи и уже установленных моделях."""
from pathlib import Path
import json, os, plistlib, socket, subprocess, sys
root = Path(__file__).resolve().parents[1]
out = root / '.build/local-api/real'
app = out / 'APIProbe.app'
(app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
resources = app / 'Contents/Resources'
resources.mkdir(exist_ok=True)
actual = root / 'dist/Runvoice-arm64.app/Contents/Resources'
for name in ['RunvoiceASR', 'warmup.wav', 'whisper']:
    link = resources / name
    if not link.exists(): link.symlink_to(actual / name)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'ai.opencode.runvoice.api-probe','CFBundleExecutable':'APIProbe','CFBundleName':'Runvoice API Probe','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'15.0'}))
support = Path.home() / 'Library/Application Support/Runvoice'
model = json.loads((support / 'settings.json').read_text())['whisperModelPath']
home = out / 'home'
models = home / 'Library/Application Support/Runvoice/models'
models.mkdir(parents=True, exist_ok=True)
fluid = support / 'models/nemotron'
if fluid.exists() and not (models / 'nemotron').exists(): (models / 'nemotron').symlink_to(fluid)
audio = root / '.build/release-final/speech.wav'
if not audio.exists():
    subprocess.run(['say','-v','Milena','-r','155','-o',str(out/'speech.aiff'),'Начало записи. Раз два три четыре. Пять шесть семь восемь.'],check=True)
    subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(out/'speech.aiff'),str(out/'speech.wav')],check=True)
    audio = out / 'speech.wav'
sources = sorted(str(p) for p in (root/'app').rglob('*.swift') if p.name not in ['main.swift','AppDelegate.swift'])
executable = app/'Contents/MacOS/APIProbe'
subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(root/'.build/clang-module-cache'),*sources,str(root/'tests/api/RealEngine.swift'),'-o',str(executable)],check=True)
def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0))
        return str(sock.getsockname()[1])
env = dict(os.environ,CFFIXED_USER_HOME=str(home))
subprocess.run([str(executable),str(audio),model,free_port(),free_port(),free_port(),str(out/'benchmark.json')],env=env,check=True,timeout=360)
