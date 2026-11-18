#!/usr/bin/env python3
"""Подготовка изолированных Metal / Core ML / WhisperKit артефактов сравнения.

Сборка не изменяет приложение, пользовательские настройки и production-кэш CMake.
Все загружаемые веса закреплены ревизией и проверяются по метаданным Hugging Face.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import urllib.parse
import urllib.request
import zipfile

CPP_REVISION = "d1be6fde11ac6e0407606b4e42fe72d34add8037"
CPP_MODELS_REVISION = "5359861c739e955e79d9a303bcbc70fb988958b1"
KIT_MODELS_REVISION = "0f63a7800b00dd0226abd051b906c246e1907482"
TOKENIZER_REVISION = "41f01f3fe87f28c78e2fbf8b568835947dd65ed9"
KIT_FOLDER = "openai_whisper-large-v3-v20240930"
FP16_SHA256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"


def digest(path, algorithm="sha256"):
    result = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def metadata(repo, revision, folder=""):
    url = f"https://huggingface.co/api/models/{repo}/tree/{revision}"
    if folder:
        url += "/" + folder
    url += "?recursive=true&expand=false"
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)


def download(repo, revision, item, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    expected = item.get("lfs", {}).get("oid")

    def valid(path):
        if not path.is_file() or path.stat().st_size != item["size"]:
            return False
        if expected:
            return digest(path) == expected
        data = path.read_bytes()
        return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest() == item["oid"]

    if not valid(target):
        partial = target.with_name(target.name + ".partial")
        if valid(partial):
            partial.replace(target)
            return {"repo": repo, "revision": revision, "file": item["path"], "path": str(target),
                    "bytes": item["size"], "sha256": digest(target)}
        if partial.exists() and partial.stat().st_size >= item["size"]:
            partial.unlink()
        url = "https://huggingface.co/" + repo + "/resolve/" + revision + "/" + urllib.parse.quote(item["path"])
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4", "--retry-delay", "2",
                        "--connect-timeout", "30", "--continue-at", "-", "--output", str(partial), url], check=True)
        partial.replace(target)
        if not valid(target):
            raise RuntimeError(f"Checksum mismatch: {target}")
    return {"repo": repo, "revision": revision, "file": item["path"], "path": str(target),
            "bytes": item["size"], "sha256": digest(target)}


def prepare_models(repo, root):
    models = root / "models"
    cpp = models / "cpp"
    cpp.mkdir(parents=True, exist_ok=True)
    original = repo / ".build/whisper-evaluation/turbo-f16.bin"
    target = cpp / "ggml-large-v3-turbo.bin"
    cpp_tree = metadata("ggerganov/whisper.cpp", CPP_MODELS_REVISION)
    if not target.exists():
        if original.is_file() and digest(original) == FP16_SHA256:
            try:
                subprocess.run(["cp", "-c", str(original), str(target)], check=True, capture_output=True)
            except subprocess.CalledProcessError:
                shutil.copy2(original, target)
        else:
            item = next(row for row in cpp_tree if row["path"] == "ggml-large-v3-turbo.bin")
            download("ggerganov/whisper.cpp", CPP_MODELS_REVISION, item, target)
    if digest(target) != FP16_SHA256:
        raise RuntimeError("Invalid Turbo FP16 GGML")
    manifest = {"ggml": {"path": str(target), "sha256": FP16_SHA256, "precision": "FP16 weights, no integer quantization"}}
    encoder_item = next(row for row in cpp_tree if row["path"] == "ggml-large-v3-turbo-encoder.mlmodelc.zip")
    archive = root / "downloads" / encoder_item["path"]
    jobs = [("cpp_encoder_archive", "ggerganov/whisper.cpp", CPP_MODELS_REVISION, encoder_item, archive)]
    kit_tree = metadata("argmaxinc/whisperkit-coreml", KIT_MODELS_REVISION, KIT_FOLDER)
    for item in kit_tree:
        if item["type"] == "file":
            jobs.append(("kit/" + item["path"], "argmaxinc/whisperkit-coreml", KIT_MODELS_REVISION,
                         item, models / "whisperkit" / item["path"]))
    tokenizer_repo = "openai/whisper-large-v3-turbo"
    tokenizer_names = {"config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json",
                       "special_tokens_map.json", "vocab.json", "merges.txt", "normalizer.json", "preprocessor_config.json"}
    for item in metadata(tokenizer_repo, TOKENIZER_REVISION):
        if item["type"] == "file" and item["path"] in tokenizer_names:
            jobs.append(("tokenizer/" + item["path"], tokenizer_repo, TOKENIZER_REVISION,
                         item, models / "tokenizer" / item["path"]))
    assets = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        pending = {pool.submit(download, model_repo, revision, item, path): name
                   for name, model_repo, revision, item, path in jobs}
        for future in concurrent.futures.as_completed(pending):
            name = pending[future]
            assets[name] = future.result()
            print("Verified " + name, flush=True)
    encoder = cpp / "ggml-large-v3-turbo-encoder.mlmodelc"
    if not encoder.exists():
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.infolist():
                destination = (cpp / member.filename).resolve()
                if cpp.resolve() not in destination.parents:
                    raise RuntimeError("Unsafe archive path")
            bundle.extractall(cpp)
    if not encoder.is_dir():
        raise RuntimeError("Encoder archive did not contain the expected directory")
    for path in sorted(encoder.rglob("*")):
        if path.is_file():
            name = "cpp_encoder/" + str(path.relative_to(encoder))
            assets[name] = {"repo": "ggerganov/whisper.cpp", "revision": CPP_MODELS_REVISION,
                            "file": encoder_item["path"], "archive_member": str(path.relative_to(cpp)),
                            "path": str(path), "bytes": path.stat().st_size, "sha256": digest(path)}
    manifest.update({"assets": assets, "cpp_model": str(target), "cpp_encoder": str(encoder),
                     "whisperkit_model": str(models / "whisperkit" / KIT_FOLDER),
                     "whisperkit_tokenizer": str(models / "tokenizer")})
    mil_files = list(encoder.glob("*.mil"))
    kit_encoder = models / "whisperkit" / KIT_FOLDER / "AudioEncoder.mlmodelc/model.mil"
    manifest["precision_inspection"] = {}
    for label, paths in [("cpp_encoder", mil_files), ("whisperkit_encoder", [kit_encoder])]:
        for path in paths:
            if path.is_file():
                text = path.read_text(errors="replace")
                manifest["precision_inspection"][label] = {"file": str(path), "fp16_mentions": text.count("fp16"),
                                                           "fp32_mentions": text.count("fp32")}
    return manifest


def build_backends(repo, root):
    source = repo / ".build/whisper-src"
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if revision != CPP_REVISION:
        raise RuntimeError(f"Unexpected whisper.cpp source revision: {revision}")
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    paths = {}
    for name, coreml in [("cpp-metal", "OFF"), ("cpp-coreml", "ON")]:
        build = root / name
        flags = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
                 "-DBUILD_SHARED_LIBS=OFF", "-DWHISPER_BUILD_TESTS=OFF", "-DWHISPER_BUILD_SERVER=ON",
                 "-DWHISPER_BUILD_EXAMPLES=ON", "-DGGML_METAL=ON", "-DGGML_METAL_EMBED_LIBRARY=ON",
                 "-DGGML_BLAS=OFF", "-DGGML_BACKEND_DL=OFF", "-DGGML_OPENMP=OFF",
                 "-DWHISPER_COREML=" + coreml, "-DWHISPER_COREML_ALLOW_FALLBACK=OFF"]
        with (root / (name + "-build.log")).open("w") as log:
            subprocess.run(["cmake", "-S", str(source), "-B", str(build)] + flags, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            subprocess.run(["cmake", "--build", str(build), "--target", "whisper-server", "whisper-cli", "-j", "6"],
                           env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        paths[name] = {"server": str(build / "bin/whisper-server"), "cli": str(build / "bin/whisper-cli"),
                       "source_revision": revision, "cmake_flags": flags}
        print("Built " + name, flush=True)
    return paths


def combined_manifest(repo, root):
    models_path, backends_path = root / "models-manifest.json", root / "backends-manifest.json"
    if not models_path.is_file() or not backends_path.is_file():
        return
    models, compiled = json.loads(models_path.read_text()), json.loads(backends_path.read_text())
    backends = [
        {"id": "metal-f16", "kind": "cpp", "executable": compiled["cpp-metal"]["server"], "model": models["cpp_model"]},
        {"id": "coreml-f16", "kind": "cpp", "executable": compiled["cpp-coreml"]["server"], "model": models["cpp_model"]},
        {"id": "whisperkit-f16", "kind": "whisperkit",
         "executable": str(repo / ".build/whisperkit-benchmark/arm64-apple-macosx/release/WhisperKitBenchmark"),
         "model": models["whisperkit_model"], "tokenizer": models["whisperkit_tokenizer"]},
    ]
    settings = Path.home() / "Library/Application Support/Runvoice/settings.json"
    if settings.is_file():
        selected = Path(json.loads(settings.read_text()).get("whisperModelPath", "/nonexistent"))
        if selected.is_file() and selected.name == "ggml-large-v3-turbo-q5_0.bin":
            q5 = root / "models/cpp/ggml-large-v3-turbo-q5_0.bin"
            if not q5.exists():
                try:
                    subprocess.run(["cp", "-c", str(selected), str(q5)], check=True, capture_output=True)
                except subprocess.CalledProcessError:
                    shutil.copy2(selected, q5)
            expected = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
            if digest(q5) != expected:
                raise RuntimeError("Unexpected Turbo Q5 checksum")
            backends.append({"id": "metal-q5", "kind": "cpp", "executable": compiled["cpp-metal"]["server"], "model": str(q5)})
    artifacts = [{"path": models["cpp_model"], "sha256": models["ggml"]["sha256"],
                  "source": "https://huggingface.co/ggerganov/whisper.cpp", "revision": CPP_MODELS_REVISION}]
    for asset in models["assets"].values():
        artifacts.append({"path": asset["path"], "sha256": asset["sha256"],
                          "source": "https://huggingface.co/" + asset["repo"], "revision": asset["revision"]})
    for backend in ["cpp-metal", "cpp-coreml"]:
        path = Path(compiled[backend]["server"])
        artifacts.append({"path": str(path), "sha256": digest(path),
                          "source": "https://github.com/ggml-org/whisper.cpp", "revision": CPP_REVISION})
    for backend in backends:
        if backend["id"] == "metal-q5":
            artifacts.append({"path": backend["model"], "sha256": digest(Path(backend["model"])),
                              "source": "https://huggingface.co/ggerganov/whisper.cpp", "revision": CPP_MODELS_REVISION})
    value = {"backends": backends, "artifacts": artifacts, "builds": compiled,
             "precision_inspection": models["precision_inspection"],
             "comparison_scope": "Official uncompressed Turbo exports; conversion/numeric differences are not attributed solely to runtime."}
    (root / "manifest.json").write_text(json.dumps(value, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models-only", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    args = parser.parse_args()
    if args.models_only and args.build_only:
        parser.error("Select only one preparation mode")
    repo = Path(__file__).resolve().parents[2]
    root = repo / ".build/asr-backend-comparison"
    root.mkdir(parents=True, exist_ok=True)
    if not args.build_only:
        models = prepare_models(repo, root)
        (root / "models-manifest.json").write_text(json.dumps(models, ensure_ascii=False, indent=2))
    if not args.models_only:
        backends = build_backends(repo, root)
        (root / "backends-manifest.json").write_text(json.dumps(backends, ensure_ascii=False, indent=2))
    combined_manifest(repo, root)
    print("Preparation complete", flush=True)


if __name__ == "__main__":
    main()
