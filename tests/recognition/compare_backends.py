#!/usr/bin/env python3
"""Последовательное сравнение Metal / Core ML / WhisperKit на общих WAV.

Модели готовит prepare_backends.py. Пользовательские настройки, микрофон,
AI и вставка не используются. Исторические результаты — только в CHANGELOG.
"""
import argparse
import csv
import hashlib
import html
import io
import json
import math
import os
from pathlib import Path
import queue
import re
import socket
import statistics
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
import wave

sys.dont_write_bytecode = True
from benchmark import words, edits


def percentile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def samples_for_run(source, directory):
    directory.mkdir(parents=True, exist_ok=True)
    samples = json.loads(source.read_text())
    for row in samples:
        with wave.open(row['wav'], 'rb') as audio:
            assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (1, 2, 16000)
    def save(name, pcm):
        path = directory / (name + '.wav')
        buffer = io.BytesIO()
        with wave.open(buffer, 'wb') as audio:
            audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
            audio.writeframes(pcm)
        data = buffer.getvalue()
        if path.exists():
            if path.read_bytes() != data:
                raise RuntimeError('Existing fixture differs; choose a new output directory: ' + str(path))
        else:
            path.write_bytes(data)
        return str(path.resolve())
    chosen = [next(row for row in samples if row['id'] == name) for name in ['ru', 'en', 'mixed']]
    chunks = []
    for row in chosen:
        with wave.open(row['wav'], 'rb') as audio:
            chunks.append(audio.readframes(audio.getnframes()))
    samples.append(dict(id='long', wav=save('long', bytes(19200).join(chunks)),
                        reference=' '.join(row['reference'] for row in chosen), group='long', language='ru',
                        terms=list(dict.fromkeys(term for row in chosen for term in row.get('terms', [])))))
    samples.append(dict(id='silence', wav=save('silence', bytes(320000)),
                        reference='', group='silence', language='ru', terms=[]))
    for row in samples:
        with wave.open(row['wav'], 'rb') as audio:
            row['audio_seconds'] = audio.getnframes() / 16000
        row['sha256'] = hashlib.sha256(Path(row['wav']).read_bytes()).hexdigest()
    manifest_path = directory / 'samples.json'
    if manifest_path.exists():
        if json.loads(manifest_path.read_text()) != samples:
            raise RuntimeError('Existing sample manifest differs; choose a new output directory')
    else:
        manifest_path.write_text(json.dumps(samples, ensure_ascii=False, indent=2))
    return samples


def request_audio(address, path, language, prompt, timeout=300, options=None):
    boundary = uuid.uuid4().hex
    body = bytearray()
    fields = dict(language=language, prompt=prompt, translate='false', response_format='json',
                  no_timestamps='true', temperature='0', temperature_inc='0', best_of='1', beam_size='1',
                  audio_ctx='0', suppress_nst='false')
    fields.update(options or {})
    for name, value in fields.items():
        body.extend((f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n').encode())
    body.extend((f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode())
    body.extend(Path(path).read_bytes())
    body.extend(f'\r\n--{boundary}--\r\n'.encode())
    request = urllib.request.Request(address + '/inference', data=body,
                                    headers={'Content-Type': 'multipart/form-data; boundary=' + boundary})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)['text'].strip(), {}


class Backend:
    def __init__(self, config, output, round_number):
        self.config = config
        self.queue = queue.Queue()
        self.ready = {}
        self.log = (output / f'{config["id"]}-{round_number}.log').open('w')
        self.started = time.monotonic()
        self.process = None
        try:
            self.start(config)
        except BaseException:
            self.close()
            raise

    def start(self, config):
        if config['kind'] == 'cpp':
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            self.address = f'http://127.0.0.1:{port}'
            self.process = subprocess.Popen([config['executable'], '-m', config['model'], '--host', '127.0.0.1',
                '--port', str(port), '-t', '8', '-bs', '1', '-bo', '1', '-nf', '-nt'] + config.get('arguments', []), stdout=self.log, stderr=self.log)
            deadline = time.monotonic() + 600
            while True:
                if self.process.poll() is not None:
                    raise RuntimeError(config['id'] + ': server exited; see ' + self.log.name)
                try:
                    with urllib.request.urlopen(self.address + '/health', timeout=1):
                        break
                except OSError:
                    if time.monotonic() > deadline:
                        self.close()
                        raise TimeoutError('server startup')
                    time.sleep(0.1)
            self.log.flush()
            if config['id'].startswith('coreml'):
                assert 'Core ML model loaded' in Path(self.log.name).read_text(), 'Core ML encoder was not loaded'
        else:
            self.process = subprocess.Popen([config['executable'], '--model-dir', config['model'],
                '--tokenizer-dir', config['tokenizer']], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self.log, text=True, encoding='utf-8')
            def read():
                for line in self.process.stdout:
                    if line.startswith('RUNVOICE_BENCH '):
                        self.queue.put(json.loads(line[len('RUNVOICE_BENCH '):]))
                self.queue.put({'event': 'error', 'message': 'worker exited'})
            threading.Thread(target=read, daemon=True).start()
            self.ready = self.receive('ready', timeout=900)
        self.load_ms = round((time.monotonic() - self.started) * 1000)

    def receive(self, kind, identifier=None, timeout=300):
        deadline = time.monotonic() + timeout
        while True:
            event = self.queue.get(timeout=max(.01, deadline - time.monotonic()))
            if event.get('event') == 'error':
                raise RuntimeError(event)
            if event.get('event') == kind and (identifier is None or event.get('id') == identifier):
                return event

    def transcribe(self, path, language, prompt, timeout=300):
        if self.config['kind'] == 'cpp':
            return request_audio(self.address, path, language, prompt, timeout=timeout)
        identifier = uuid.uuid4().hex
        self.process.stdin.write(json.dumps(dict(id=identifier, wav=str(path), language=language, prompt=prompt)) + '\n')
        self.process.stdin.flush()
        response = self.receive('result', identifier, timeout=timeout)
        return response['text'].strip(), response.get('diagnostics', {})

    def resources(self):
        try:
            values = subprocess.check_output(['ps', '-o', 'rss=,time=', '-p', str(self.process.pid)], text=True).split()
            minutes, seconds = values[1].split(':')
            return {'rss_kib': int(values[0]), 'cpu_seconds': int(minutes) * 60 + float(seconds)}
        except (ValueError, IndexError, subprocess.CalledProcessError):
            return {}

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()


def preview(backend, executable, sample, vocabulary, log_path):
    started = time.monotonic()
    process = subprocess.Popen([str(executable), '--wav', sample['wav'], '--language', 'auto', '--prompt', vocabulary],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for line in process.stdout:
            if not line.startswith('RUNVOICE_PREVIEW '):
                continue
            event = json.loads(line[len('RUNVOICE_PREVIEW '):])
            if event['event'] == 'request':
                try:
                    text, _ = backend.transcribe(event['wav'], event['language'], event['prompt'], timeout=30)
                    reply = dict(id=event['id'], text=text)
                except Exception as error:
                    reply = dict(id=event['id'], error=str(error))
                if process.poll() is not None:
                    raise RuntimeError('Preview harness ended while backend was processing a request')
                process.stdin.write(json.dumps(reply) + '\n')
                process.stdin.flush()
            elif event['event'] == 'result':
                process.stdin.close()
                process.wait(timeout=20)
                assert process.returncode == 0
                log_path.write_text(process.stderr.read())
                metrics = event['metrics']
                passed = not any(metrics.get(key) for key in ['timed_out', 'bridge_closed', 'failed_requests', 'unfinished_requests'])
                return dict(sample=sample['id'], passed=passed,
                            milliseconds=round((time.monotonic() - started) * 1000), **event)
        raise RuntimeError('Preview harness ended without metrics: ' + process.stderr.read())
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


def summaries(results):
    groups = {}
    for row in results:
        key = (row['backend'], row['group'], row['language'], row['dictionary'])
        groups.setdefault(key, []).append(row)
    output = []
    for (backend, group, language, dictionary), rows in sorted(groups.items()):
        duration = [row['milliseconds'] for row in rows]
        count = sum(row['words'] for row in rows)
        terms = sum(row['terms'] for row in rows)
        output.append(dict(backend=backend, group=group, language=language, dictionary=dictionary,
            requests=len(rows), wer=round(sum(row['errors'] for row in rows) / count * 100, 3) if count else None,
            term_accuracy=round(sum(row['term_hits'] for row in rows) / terms * 100, 2) if terms else None,
            hallucinated_words=sum(row['errors'] for row in rows) if not count else None,
            median_ms=round(statistics.median(duration), 1), p95_ms=percentile(duration, .95),
            median_rtfx=round(statistics.median(row['audio_seconds'] * 1000 / max(.01, row['milliseconds']) for row in rows), 2)))
    return output


def write_report(output, metadata, results, previews, loads):
    summary = summaries(results)
    report = dict(metadata=metadata, summary=summary, results=results, preview=previews, loads=loads)
    (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    if results:
        with (output / 'results.csv').open('w') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(results[0]), extrasaction='ignore')
            writer.writeheader()
            writer.writerows({key: json.dumps(value, ensure_ascii=False) if isinstance(value, (dict, list)) else value
                              for key, value in row.items()} for row in results)
    def table(rows, columns):
        def cell(value):
            return '—' if value is None else html.escape(str(value))
        return '<table><thead><tr>' + ''.join('<th>' + label + '</th>' for key, label in columns) + '</tr></thead><tbody>' + ''.join(
            '<tr>' + ''.join('<td>' + cell(row.get(key)) + '</td>' for key, label in columns) + '</tr>' for row in rows) + '</tbody></table>'
    preview_rows, resource_rows = [], []
    samples = {row['id']: row for row in metadata.get('samples', metadata.get('primary', {}).get('samples', []))}
    for backend in sorted({row['backend'] for row in results}):
        observed = [row for row in results if row['backend'] == backend]
        starts = [row for row in loads if row['backend'] == backend]
        rss = [row['rss_kib'] / 1024 for row in observed if row.get('rss_kib')]
        cpu = [row['resources']['after']['cpu_seconds'] - row['resources']['before']['cpu_seconds'] for row in starts
               if row.get('resources', {}).get('after', {}).get('cpu_seconds') is not None
               and row.get('resources', {}).get('before', {}).get('cpu_seconds') is not None]
        resource_rows.append(dict(backend=backend, load_ms=round(statistics.median(row['load_ms'] for row in starts), 1) if starts else None,
            warmup_ms=round(statistics.median(row['warmup_ms'] for row in starts), 1) if starts else None,
            rss_mib=round(max(rss), 1) if rss else None, cpu_seconds=round(sum(cpu), 2) if cpu else None, blocks=len(starts)))
        for sample in sorted({row['sample'] for row in previews if row['backend'] == backend}):
            rows = [row for row in previews if row['backend'] == backend and row['sample'] == sample]
            good = [row['metrics'] for row in rows if row.get('passed')]
            def median_metric(name):
                values = [row[name] for row in good if row.get(name) is not None]
                return round(statistics.median(values), 1) if values else None
            reference = words(samples[sample]['reference']) if sample in samples else []
            preview_errors = [edits(reference, words(row['text'])) for row in rows if row.get('passed')] if reference else []
            preview_rows.append(dict(backend=backend, sample=sample, passed=f'{len(good)}/{len(rows)}',
                first_ms=median_metric('first_published_ms'), gap_ms=median_metric('gap_median_ms'),
                gap_p95_ms=median_metric('gap_p95_ms'), request_ms=median_metric('request_median_ms'),
                updates=median_metric('updates'),
                wer=round(sum(preview_errors) / (len(reference) * len(preview_errors)) * 100, 3) if preview_errors else None))
    diagnostic_rows = metadata.get('long_diagnostic', {}).get('records', [])
    diagnostic_html = ''
    if diagnostic_rows:
        diagnostic_html = '<h2>Контроль длинной записи</h2><p>Одиночные диагностические запросы Metal FP16, не рейтинг скорости. Длинный файл искусственно собран из трёх источников с разными языками. Высокие ошибки общего режима без VAD/timestamps нельзя считать результатом рабочей конфигурации приложения.</p>' + table(diagnostic_rows,
            [('sample','Запись'),('vad','VAD'),('no_timestamps','Без timestamps'),('reference_words','Слов эталона'),('errors','Ошибок'),('wer','WER %')])
    (output / 'report.html').write_text('''<!doctype html><meta charset="utf-8"><title>Сравнение Whisper</title>
<style>body{font:15px system-ui;margin:32px;color:#222}table{border-collapse:collapse}td,th{padding:7px;border:1px solid #ddd;text-align:left}thead{position:sticky;top:0;background:#fff}input{padding:8px;width:360px}tr[hidden]{display:none}</style>
<h1>Сравнение локальных вариантов Whisper</h1><p>Меньше WER и времени — лучше. Больше точность терминов и RTFx — лучше. Основное сравнение — ASR без AI, VAD и вставки на одинаковых WAV из манифеста. Диагностические контроли с VAD показаны отдельно.</p>
<p>Основная тройка использует официальные несжатые экспорты Turbo; конвертация и арифметика могут различаться. Metal Q5 — дополнительный ориентир с квантованием. Контекст декодера WhisperKit — 224 токена. Общий preview использует audio_ctx=0, рабочий HTTP-preview — 512.</p>
<input placeholder="Фильтр: mixed, auto, backend…" oninput="for(const r of document.querySelectorAll('tbody tr'))r.hidden=!r.textContent.toLowerCase().includes(this.value.toLowerCase())">
<h2>Финальное распознавание</h2>''' + table(summary, [(key, label) for key, label in zip(
        ['backend','group','language','dictionary','requests','wer','term_accuracy','hallucinated_words','median_ms','p95_ms','median_rtfx'],
        ['Backend','Группа','Язык','Словарь','Запросов','WER %','Термины %','Слова на тишине','Медиана мс','p95 мс','RTFx'])]) +
        '<h2>Общий предпросмотр</h2><p>Медианы по повторным прогонам. Успех означает отсутствие технических ошибок. WER рассчитан для накопленного текста preview после завершения подачи аудио, отдельно от финального ASR. Времена относятся к подтверждённому тексту; более частые публикации сами по себе не доказывают лучшую полноту. p95 интервала использует нижний эмпирический квантиль Swift, p95 финального ASR — ближайший ранг Python.</p>' + table(preview_rows,
        [('backend','Backend'),('sample','Запись'),('passed','Без тех. ошибок'),('wer','WER preview %'),('first_ms','Первый текст мс'),('gap_ms','Интервал мс'),
         ('gap_p95_ms','p95 интервала мс'),('request_ms','Запрос мс'),('updates','Публикаций')]) +
        '<h2>Загрузка и ресурсы</h2><p>Загрузка — повторный запуск процесса без очистки системного кэша; отдельно выполненный первый наблюдаемый запуск хранится в каталоге эксперимента. CPU — процесс ASR до/после финальных запросов, без preview и системных служб Core ML.</p>' + table(resource_rows,
        [('backend','Backend'),('blocks','Блоков'),('load_ms','Загрузка мс'),('warmup_ms','Прогрев мс'),('rss_mib','Макс. наблюд. RSS МиБ'),('cpu_seconds','CPU с')]) +
        diagnostic_html + '<p>Полные ответы, метаданные и preview: report.json; табличные данные: results.csv. RSS не включает всю память системных процессов Core ML. Энергия без powermetrics не измерена. Тишина: число выданных слов по всем повторам, не WER. Повторы повышают надёжность временных замеров, а не число независимых аудиопримеров.</p>')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--samples', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--warmup', type=Path, required=True)
    parser.add_argument('--preview-harness', type=Path)
    parser.add_argument('--rounds', type=int, default=10)
    parser.add_argument('--preview-rounds', type=int, default=3)
    parser.add_argument('--only', nargs='*')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(args.manifest.read_text())
    configs = manifest['backends']
    if args.only:
        configs = [row for row in configs if row['id'] in args.only]
    assert configs and args.rounds > 0 and args.preview_rounds >= 0
    samples = samples_for_run(args.samples, args.output / 'fixtures')
    vocabulary = ', '.join(dict.fromkeys(term for row in samples for term in row.get('terms', [])))
    metadata = dict(manifest=manifest, samples=samples, rounds=args.rounds, preview_rounds=args.preview_rounds,
                    settings=dict(temperature=0, temperature_fallback=False, beam_size=1, best_of=1,
                    audio_ctx=0, vad=False, ai=False, suppress_nst=False, vocabulary=vocabulary),
                    executable_sha256={config['id']: hashlib.sha256(Path(config['executable']).read_bytes()).hexdigest() for config in configs},
                    preview_sha256=hashlib.sha256(args.preview_harness.read_bytes()).hexdigest() if args.preview_harness else None,
                    energy=dict(measured=False, reason='powermetrics requires sudo; no cached noninteractive authorization'))
    configuration_path = args.output / 'configuration.json'
    if configuration_path.exists():
        assert json.loads(configuration_path.read_text()) == metadata, 'Output contains a different configuration; choose a new directory'
    else:
        configuration_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
    def restore(kind):
        path = args.output / (kind + '.jsonl')
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []
    results, previews, loads = restore('results'), restore('preview'), restore('loads')
    complete = {(r['backend'], r['round'], r['sample'], r['language'], r['dictionary']) for r in results}
    preview_complete = {(r['backend'], r['round'], r['sample']) for r in previews}
    def append(kind, row):
        with (args.output / (kind + '.jsonl')).open('a') as stream:
            stream.write(json.dumps(row, ensure_ascii=False) + '\n')
    for number in range(args.rounds):
        order = configs[number % len(configs):] + configs[:number % len(configs)]
        for config in order:
            expected = {(config['id'], number, sample['id'], language, dictionary) for sample in samples
                        for language in dict.fromkeys([sample['language'], 'auto']) for dictionary in [False, True]}
            expected_preview = {(config['id'], number, name) for name in ['mixed', 'long']}
            if expected <= complete and (not args.preview_harness or number >= args.preview_rounds or expected_preview <= preview_complete):
                continue
            print(f'Round {number + 1}/{args.rounds}: {config["id"]} loading', flush=True)
            backend = Backend(config, args.output, number)
            try:
                warm_started = time.monotonic()
                backend.transcribe(args.warmup, 'ru', '')
                load = dict(backend=config['id'], round=number, load_ms=backend.load_ms,
                            warmup_ms=round((time.monotonic() - warm_started) * 1000), ready=backend.ready)
                loads.append(load)
                before = backend.resources()
                for sample in samples:
                    for language in dict.fromkeys([sample['language'], 'auto']):
                        for dictionary in [False, True]:
                            key = (config['id'], number, sample['id'], language, dictionary)
                            if key in complete:
                                continue
                            started = time.monotonic()
                            text, diagnostics = backend.transcribe(sample['wav'], language, vocabulary if dictionary else '')
                            elapsed = (time.monotonic() - started) * 1000
                            term_hits = sum(bool(re.search(r'(?<!\w)' + re.escape(term.casefold()) + r'(?!\w)', text.casefold())) for term in sample.get('terms', []))
                            row = dict(backend=config['id'], round=number, sample=sample['id'], group=sample['group'],
                                language=language, dictionary=dictionary, text=text, words=len(words(sample['reference'])),
                                errors=edits(words(sample['reference']), words(text)), terms=len(sample.get('terms', [])),
                                term_hits=term_hits, milliseconds=round(elapsed, 2), audio_seconds=sample['audio_seconds'],
                                rss_kib=backend.resources().get('rss_kib'), diagnostics=diagnostics)
                            results.append(row)
                            complete.add(key)
                            append('results', row)
                after = backend.resources()
                load['resources'] = dict(before=before, after=after)
                append('loads', load)
                print(f'Round {number + 1}: {config["id"]} final ASR complete', flush=True)
                if args.preview_harness and number < args.preview_rounds:
                    for sample in [row for row in samples if row['id'] in ['mixed', 'long']]:
                        key = (config['id'], number, sample['id'])
                        if key in preview_complete:
                            continue
                        try:
                            value = preview(backend, args.preview_harness, sample, vocabulary,
                                            args.output / f'{config["id"]}-{number}-{sample["id"]}-preview.log')
                        except Exception as error:
                            value = dict(sample=sample['id'], event='error', passed=False, error=str(error))
                        value.update(backend=config['id'], round=number)
                        previews.append(value)
                        append('preview', value)
                        preview_complete.add(key)
                        print(f'Round {number + 1}: {config["id"]} preview {sample["id"]} complete', flush=True)
                write_report(args.output, metadata, results, previews, loads)
            finally:
                backend.close()
                write_report(args.output, metadata, results, previews, loads)
    write_report(args.output, metadata, results, previews, loads)
    print('Report: ' + str(args.output / 'report.html'), flush=True)


if __name__ == '__main__':
    main()
