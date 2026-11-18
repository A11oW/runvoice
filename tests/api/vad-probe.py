"""Реальный VAD на синтетических сигналах, без микрофона и скачивания весов."""
import json, math, pathlib, random, struct, subprocess, wave
root = pathlib.Path(__file__).resolve().parents[2]
out = root / '.build/api-filter'
out.mkdir(parents=True, exist_ok=True)
audio = root / '.build/release-final/speech.wav'
if not audio.exists(): audio = root / '.build/local-api/real/speech.wav'
with wave.open(str(audio)) as f:
    speech = f.readframes(f.getnframes())
def pcm(values): return struct.pack('<'+'h'*len(values), *values)
rng = random.Random(42)
noise = pcm([int(rng.gauss(0, 25)) for _ in range(16000)])
click = pcm([24000 if i in range(7000,7010) else 0 for i in range(16000)])
values = struct.unpack('<'+'h'*(len(speech)//2), speech)
quiet = pcm([int(v*.1) for v in values])
fixtures = {'silence':bytes(32000),'noise':noise,'click':click,'speech':speech,'quiet_speech':quiet,'speech_with_pauses':bytes(32000)+speech+bytes(32000),'silence_after_speech':bytes(32000)}
for word in ['да','нет']:
    source = out/f'{word}.aiff'; target = out/f'{word}.wav'
    subprocess.run(['say','-v','Milena','-o',str(source),word],check=True)
    subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(source),str(target)],check=True)
    with wave.open(str(target)) as f: fixtures[word] = f.readframes(f.getnframes())
report = []
for label in ['arm64','intel']:
    folder = root/f'dist/Runvoice-{label}.app/Contents/Resources/whisper'
    process = subprocess.Popen([str(folder/'bin/runvoice-vad'),str(folder/'models/ggml-silero-v5.1.2.bin')],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
    try:
        assert json.loads(process.stdout.readline())['ready']
        for name,data in fixtures.items():
            process.stdin.write(struct.pack('<I',len(data))+data);process.stdin.flush()
            segments = json.loads(process.stdout.readline())['segments']
            samples = struct.unpack('<'+'h'*(len(data)//2),data)
            accepted = []
            for start,end in segments:
                above = 0
                for i in range(start,end,320):
                    frame = samples[i:min(end,i+320)]
                    rms = math.sqrt(sum((v/32768)**2 for v in frame)/len(frame))
                    if rms >= 10**(-55/20): above += len(frame)
                if above >= 1280: accepted.append([start,end])
            passed = bool(accepted)
            expected = name not in ['silence','noise','click','silence_after_speech']
            report.append(dict(architecture=label,fixture=name,accepted=passed,segments=segments))
            assert passed == expected, (label,name,segments)
    finally:
        process.stdin.close();process.wait(timeout=10)
(out/'vad-probe.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
print(f'OK: {len(report)} real VAD signal/short speech checks on arm64 and x86_64')
