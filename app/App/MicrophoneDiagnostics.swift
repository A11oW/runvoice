import AppKit

/// Явный аппаратный smoke: --test-microphone [--microphone-test-count N].
/// Короткие записи удаляются; распознавание, AI, история и вставка не запускаются.
enum MicrophoneDiagnostics {
    static func startIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.contains("--test-microphone") else { return false }
        let count: Int
        if let index = arguments.firstIndex(of: "--microphone-test-count"), index + 1 < arguments.count {
            count = max(1, min(100, Int(arguments[index + 1]) ?? 20))
        } else { count = 20 }
        let settings = SettingsStore.load()
        var failures = 0
        func emit(_ value: [String: Any]) {
            guard let json = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
            FileHandle.standardOutput.write(Data("RUNVOICE_MIC_TEST ".utf8) + json + Data([10]))
        }
        func run(_ index: Int) {
            if index == count {
                emit(["event": "complete", "cycles": count, "failures": failures])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                return
            }
            let started = Date()
            MicTester.test(micName: settings.microphone, deviceUID: settings.microphoneUID) { result in
                switch result {
                case .success(let level):
                    emit(["event": "cycle", "index": index + 1, "ok": true, "level": level,
                          "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000)])
                case .failure(let error):
                    failures += 1
                    emit(["event": "cycle", "index": index + 1, "ok": false, "error": error.localizedDescription])
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(index + 1) }
            }
            if index == 0 {
                // Проверяем lease между окном настроек и второй диктовкой.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    let competing = NativeAudioRecorder()
                    let url = Paths.state.appendingPathComponent("mic-busy-\(UUID().uuidString).wav")
                    competing.start(microphone: settings.microphone, deviceUID: settings.microphoneUID, url: url) { result in
                        if case .failure(let error) = result,
                           case NativeAudioRecorder.Failure.busy = error {
                            emit(["event": "busy_guard", "ok": true])
                        } else {
                            failures += 1
                            emit(["event": "busy_guard", "ok": false])
                            competing.stop(discard: true) { _ in }
                        }
                    }
                }
            }
        }
        let unavailable = NativeAudioRecorder()
        let url = Paths.state.appendingPathComponent("mic-missing-\(UUID().uuidString).wav")
        unavailable.start(microphone: settings.microphone, deviceUID: "runvoice-missing-\(UUID().uuidString)", url: url) { result in
            if case .failure(let error) = result,
               case NativeAudioRecorder.Failure.microphone = error {
                emit(["event": "missing_device", "ok": true])
            } else { failures += 1; emit(["event": "missing_device", "ok": false]) }
            run(0)
        }
        return true
    }
}
