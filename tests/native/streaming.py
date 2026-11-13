"""Интеграция настоящей модели на синтетических PCM, без микрофона/вставки.

python3 tests/native/streaming.py <RunvoiceASR> <model-cache> <pcm> <language>
"""
import base64
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import uuid

executable, cache, pcm_path, language = sys.argv[1:]
events = queue.Queue()
process = subprocess.Popen([executable, "serve", cache], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)


def read():
    for line in process.stdout:
        if line.startswith("RUNVOICE_ASR "):
            events.put(json.loads(line.removeprefix("RUNVOICE_ASR ")))
    events.put({"event": "exit"})


threading.Thread(target=read, daemon=True).start()


def wait(kind, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        event = events.get(timeout=max(0.01, deadline - time.monotonic()))
        assert event["event"] not in ("error", "exit"), event
        if event["event"] == kind:
            return event
    raise AssertionError(f"No {kind}")


def send(action, **values):
    process.stdin.write(json.dumps({"action": action, "id": session_id, **values}) + "\n")
    process.stdin.flush()


try:
    load_start = time.monotonic()
    wait("ready", timeout=90)
    load_ms = round((time.monotonic() - load_start) * 1000)
    session_id = str(uuid.uuid4())
    vocabulary = os.environ.get("RUNVOICE_TEST_VOCAB", "").split(",")
    send("start", language=language, vocabulary=[x for x in vocabulary if x])
    started = time.monotonic()
    pcm = Path(pcm_path).read_bytes() + bytes(16000)
    first = None
    partials = []
    for offset in range(0, len(pcm), 3200):
        send("audio", pcm=base64.b64encode(pcm[offset:offset+3200]).decode())
        time.sleep(0.1)
        while not events.empty():
            event = events.get_nowait()
            assert event["event"] != "error", event
            if event["event"] == "partial" and event.get("text", "").strip():
                partials.append(event["text"])
                if first is None:
                    first = round((time.monotonic() - started) * 1000)
    stopped = time.monotonic()
    send("finish")
    result = wait("final", timeout=15)
    assert result["text"].strip(), "Пустой финальный результат"
    assert result["id"] == session_id
    assert first is not None, "Нет частичных результатов во время записи"
    print(json.dumps({"file": pcm_path, "language": language, "load_ms": load_ms,
                      "first_ms": first, "finish_ms": round((time.monotonic()-stopped)*1000),
                      "partials": partials, "final": result["text"]}, ensure_ascii=False))
    # Сброс сессии не оставляет слова предыдущей диктовки.
    send("cancel")
    session_id = str(uuid.uuid4())
    send("start", language=language)
    send("finish")
    empty = wait("final")
    assert empty["id"] == session_id and not empty["text"].strip(), empty
finally:
    process.terminate()
    process.wait(timeout=5)
