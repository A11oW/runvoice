"""Регрессия финального shell → app handoff без реального микрофона/буфера."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import json
import os
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
TEXT = "Используй Cypress вместо Playwright."
requests = []


class Whisper(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        requests.append(body)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"text": TEXT}).encode())


server = HTTPServer(("127.0.0.1", 0), Whisper)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix="runvoice-pipeline-") as temporary:
        base = Path(temporary)
        # Проверяем импорт заглушек до запуска теста. Они исключают обращения
        # к общему пользовательскому буферу даже при регрессии shell-кода.
        probe = subprocess.run(
            ["/bin/bash", "-c", "pbcopy() { return 99; }; export -f pbcopy; /bin/bash -c 'type -t pbcopy'"],
            capture_output=True, text=True, check=True,
        )
        assert probe.stdout.strip() == "function"
        for restore in ("0", "1"):
            state = base / restore
            state.mkdir()
            model = state / "model.bin"
            model.write_bytes(b"test-model")
            pcm = state / "rec.pcm"
            pcm.write_bytes(b"\x10\x00" * 16_000)
            (state / "whisper-server.model").write_text(f"{model}|/test/server")
            marker = state / "unexpected-clipboard-access"
            # Имитируем живой процесс записи с уникальным PCM-путём.
            # stop_recorders завершает только его; звук уже лежит в файле.
            recorder = subprocess.Popen(["tail", "-f", str(pcm)], stdout=subprocess.DEVNULL)
            (state / "pid").write_text(str(recorder.pid))
            environment = {
                **os.environ,
                "DICTATE_STATE_DIR": str(state), "WHISPER_MODEL": str(model),
                "WHISPER_SERVER_BIN": "/test/server", "WHISPER_CLI_BIN": "/nonexistent",
                "WHISPER_SERVER_PORT": str(server.server_port), "DICTATE_USE_OC": "0",
                "DICTATE_NO_PASTE": "1", "DICTATE_RESTORE_CLIPBOARD": restore,
                "DICTATE_NOTIFY": "0", "HUD_BIN": "/nonexistent", "DICTATE_DRY_RUN": "0",
                "TEST_CLIPBOARD_MARKER": str(marker),
            }
            wrapper = """
pbcopy() { printf called > "$TEST_CLIPBOARD_MARKER"; return 99; }
pbpaste() { printf called > "$TEST_CLIPBOARD_MARKER"; return 99; }
export -f pbcopy pbpaste
exec /bin/bash "$1" stop
"""
            try:
                subprocess.run(["/bin/bash", "-c", wrapper, "test", str(ROOT / "bin/dictate.sh")],
                               env=environment, check=True, timeout=15, capture_output=True)
                result = json.loads((state / "last_result.json").read_text())
                assert result["raw"] == result["fixed"] == TEXT
                assert result["readyAtMilliseconds"] > 0
                assert result["timestamp"] == result["readyAtMilliseconds"] / 1000
                assert (state / "status").read_text() == "done|" + TEXT
                assert not marker.exists(), "App handoff не должен запускать pbcopy/pbpaste"
                assert (state / "last_result.json").stat().st_mode & 0o777 == 0o600
            finally:
                if recorder.poll() is None:
                    recorder.terminate()
                recorder.wait(timeout=3)
        assert len(requests) == 2, "На каждую остановку — ровно одно финальное распознавание"
        assert all(b'name="no_timestamps"\r\n\r\ntrue' in body for body in requests)
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)

print("OK: 2 финальных handoff, RAW/FIXED, тайминги, права файлов, без pbcopy/pbpaste")
