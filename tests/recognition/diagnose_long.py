#!/usr/bin/env python3
"""Контроль влияния VAD и timestamps на длинный WAV; не рейтинг скорости."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True
from compare_backends import Backend, request_audio, words, edits


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--comparison-dir', type=Path, required=True)
    parser.add_argument('--vad-model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--warmup', type=Path, default=Path('resources/warmup.wav'))
    args = parser.parse_args()
    assert args.vad_model.is_file()
    vad_sha256 = hashlib.sha256(args.vad_model.read_bytes()).hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(args.manifest.read_text())
    config = next(row for row in manifest['backends'] if row['id'] == 'metal-f16')
    metadata = json.loads((args.comparison_dir / 'configuration.json').read_text())
    samples = {row['id']: row for row in metadata['samples']}
    records = []
    for vad in [False, True]:
        selected = dict(config, id='metal-f16-diagnostic')
        selected['arguments'] = ['--vad', '-vm', str(args.vad_model.resolve())] if vad else []
        backend = Backend(selected, args.output.parent, f'vad-{vad}-{time.time_ns()}')
        try:
            backend.transcribe(args.warmup, 'ru', '')
            cases = [('long', True), ('long', False)] + ([('silence', True)] if vad else [])
            for name, no_timestamps in cases:
                sample = samples[name]
                started = time.monotonic()
                text, _ = request_audio(backend.address, sample['wav'], 'auto', metadata['settings']['vocabulary'],
                                        options={'no_timestamps': str(no_timestamps).lower()})
                count = len(words(sample['reference']))
                errors = edits(words(sample['reference']), words(text))
                row = dict(sample=name, vad=vad, no_timestamps=no_timestamps, text=text,
                           reference_words=count, errors=errors, wer=round(errors / count * 100, 3) if count else None,
                           milliseconds=round((time.monotonic() - started) * 1000, 2))
                records.append(row)
                print({key: value for key, value in row.items() if key != 'text'}, flush=True)
        finally:
            backend.close()
            args.output.write_text(json.dumps(dict(
                note='One controlled diagnostic per setting, not a repeated speed benchmark.',
                backend=config, vad_model=str(args.vad_model.resolve()), vad_sha256=vad_sha256,
                samples=[samples[name] for name in ['long', 'silence']],
                language='auto', vocabulary=metadata['settings']['vocabulary'],
                records=records), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
