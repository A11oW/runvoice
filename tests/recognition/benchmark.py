#!/usr/bin/env python3
"""Сравнение локальных ASR на общем WAV/эталоне, без микрофона, AI и вставки.

models.json: {"имя": "/path/to/ggml-model.bin"}
samples.json: [{"id": "mixed", "wav": "/path.wav", "reference": "...",
                "group": "mixed", "language": "ru", "terms": ["Cypress"]}]
Все результаты записываются в указанный каталог, пользовательские настройки не читаются.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import re
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid


def words(text):
    return re.findall(r"\w+", text.casefold().replace("ё", "е"))


def edits(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, word in enumerate(reference, 1):
        current = [i]
        for j, other in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (word != other)))
        previous = current
    return previous[-1]


def request_audio(address, path, language, prompt):
    boundary = uuid.uuid4().hex
    body = bytearray()
    for key, value in dict(language=language, prompt=prompt, translate="false",
                           response_format="json", no_timestamps="true").items():
        body.extend((f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n').encode())
    body.extend((f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode())
    body.extend(Path(path).read_bytes())
    body.extend(f'\r\n--{boundary}--\r\n'.encode())
    request = urllib.request.Request(address + "/inference", data=body,
                                    headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
    with urllib.request.urlopen(request, timeout=300) as response:
        return json.load(response)["text"].strip()


class FluidWorker:
    def __init__(self, helper, directory, model):
        self.messages = queue.Queue()
        self.process = subprocess.Popen([helper, "serve", directory, model], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
        def read():
            for line in self.process.stdout:
                if line.startswith("RUNVOICE_ASR "):
                    self.messages.put(json.loads(line[len("RUNVOICE_ASR "):]))
            self.messages.put({"event": "error", "message": "worker exited"})
        threading.Thread(target=read, daemon=True).start()
        self.receive("ready")

    def receive(self, kind, identifier=None):
        deadline = time.monotonic() + 300
        while True:
            event = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if event["event"] == "error":
                raise RuntimeError(event)
            if event["event"] == kind and (identifier is None or event.get("id") == identifier):
                return event

    def send(self, command):
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()

    def transcribe(self, path, language, prompt):
        identifier = uuid.uuid4().hex
        self.send(dict(action="start", id=identifier, language=language))
        self.send(dict(action="transcribe", id=identifier, path=str(Path(path).resolve())))
        return self.receive("final", identifier)["text"].strip()

    def close(self):
        self.process.terminate()
        self.process.wait(timeout=15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--samples", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--server", required=True)
    parser.add_argument("--warmup", required=True)
    parser.add_argument("--preview-tests", help="Необязательный бинарник tests/live-hud")
    parser.add_argument("--preview-only", action="store_true", help="Повторить только измерение предпросмотра")
    parser.add_argument("--fluid-helper")
    parser.add_argument("--fluid-directory")
    parser.add_argument("--fluid-model", default="parakeet-ultra")
    args = parser.parse_args()
    if args.preview_only and not args.preview_tests:
        parser.error("--preview-only требует --preview-tests")
    args.output.mkdir(parents=True, exist_ok=True)
    samples = json.loads(args.samples.read_text())
    models = json.loads(args.models.read_text())
    previous = args.output / "report.json"
    saved = json.loads(previous.read_text()) if previous.exists() else {}
    results, preview_results = saved.get("results", []), saved.get("preview", [])
    vocabulary = ", ".join(dict.fromkeys(term for sample in samples for term in sample.get("terms", [])))
    def evaluate(name, transcribe, supports_prompt):
        for sample in samples:
            for language in dict.fromkeys([sample["language"], "auto"]):
                for use_dictionary in ([False, True] if supports_prompt else [False]):
                    started = time.monotonic()
                    text = transcribe(sample["wav"], language, vocabulary if use_dictionary else "")
                    reference = words(sample["reference"])
                    terms = sample.get("terms", [])
                    hits = sum(bool(re.search(r"(?<!\w)" + re.escape(term.casefold()) + r"(?!\w)", text.casefold())) for term in terms)
                    row = dict(model=name, sample=sample["id"], group=sample["group"], language=language,
                               dictionary=use_dictionary, text=text, words=len(reference),
                               errors=edits(reference, words(text)), terms=len(terms), term_hits=hits,
                               milliseconds=round((time.monotonic() - started) * 1000))
                    results.append(row)
                    with (args.output / "results.jsonl").open("a", encoding="utf-8") as log:
                        log.write(json.dumps(row, ensure_ascii=False) + "\n")
        print(name + ": final ASR complete", flush=True)
    for name, model in models.items():
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        address = "http://127.0.0.1:" + str(port)
        with (args.output / (name + "-server.log")).open("w") as log:
            server = subprocess.Popen([args.server, "-m", model, "--host", "127.0.0.1", "--port", str(port), "-t", "8"],
                                      stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 180
                while True:
                    if server.poll() is not None:
                        raise RuntimeError(name + ": server exited")
                    try:
                        with urllib.request.urlopen(address + "/health", timeout=1):
                            break
                    except (OSError, urllib.error.URLError):
                        if time.monotonic() > deadline:
                            raise TimeoutError(name + ": server startup")
                        time.sleep(0.1)
                request_audio(address, args.warmup, "ru", "")
                if not args.preview_only:
                    evaluate(name, lambda path, language, prompt: request_audio(address, path, language, prompt), True)
                if args.preview_tests:
                    sample = next(sample for sample in samples if sample["id"] == "mixed")
                    env = dict(os.environ, RUNVOICE_TEST_PCM=str(Path(sample["wav"]).with_suffix(".pcm")),
                               RUNVOICE_TEST_SERVER=address, RUNVOICE_TEST_STREAM="1", RUNVOICE_TEST_LANGUAGE="auto",
                               RUNVOICE_TEST_VOCAB=vocabulary, RUNVOICE_TEST_TIMINGS="1",
                               RUNVOICE_TEST_EXPECT_SUFFIX="завершить проверку")
                    preview = subprocess.run([args.preview_tests], env=env, capture_output=True, text=True, timeout=90)
                    (args.output / (name + "-preview.log")).write_text(preview.stdout + preview.stderr)
                    metrics = {}
                    for line in preview.stdout.splitlines():
                        if line.startswith("Whisper preview timings: "):
                            metrics = json.loads(line[len("Whisper preview timings: "):])
                    preview_results = [row for row in preview_results if row["model"] != name]
                    preview_results.append(dict(model=name, passed=preview.returncode == 0, **metrics))
                    print(name + ": preview tested", flush=True)
            finally:
                server.terminate()
                server.wait(timeout=15)
    if args.fluid_helper and args.fluid_directory and not args.preview_only:
        worker = FluidWorker(args.fluid_helper, args.fluid_directory, args.fluid_model)
        try:
            evaluate(args.fluid_model, worker.transcribe, False)
        finally:
            worker.close()
    (args.output / "report.json").write_text(json.dumps(dict(results=results, preview=preview_results),
                                                        ensure_ascii=False, indent=2), encoding="utf-8")
    print("Report: " + str(args.output / "report.json"))


if __name__ == "__main__":
    main()
