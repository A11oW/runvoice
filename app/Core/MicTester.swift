import Foundation

/// Проверяет тот же нативный тракт и устройство, что использует диктовка.
enum MicTester {
    private static var active: NativeAudioRecorder?
    static func test(micName: String, deviceUID: String = "", completion: @escaping (Result<String, Error>) -> Void) {
        let state = (try? String(contentsOf: Paths.status, encoding: .utf8)).flatMap(DictationState.init(raw:))
        guard active == nil, !["preparing", "recording", "transcribing", "fixing"].contains(state?.key ?? "") else {
            completion(.failure(TestError.busy)); return
        }
        let recorder = NativeAudioRecorder()
        active = recorder
        let url = Paths.state.appendingPathComponent("mic-test-\(UUID().uuidString).wav")
        var peak: Float = 0
        var finished = false
        func complete(_ result: Result<String, Error>) {
            guard !finished else { return }
            finished = true
            active = nil
            recorder.onAudio = nil
            recorder.onFailure = nil
            try? FileManager.default.removeItem(at: url)
            completion(result)
        }
        recorder.onAudio = { data in
            data.withUnsafeBytes { bytes in
                for sample in bytes.bindMemory(to: Int16.self) {
                    peak = max(peak, abs(Float(Int16(littleEndian: sample)) / 32768))
                }
            }
        }
        recorder.onFailure = { error in
            recorder.stop(discard: true) { _ in complete(.failure(error)) }
        }
        recorder.start(microphone: micName, deviceUID: deviceUID, url: url) { result in
            switch result {
            case .failure(let error): complete(.failure(error))
            case .success:
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard !finished else { return }
                    recorder.stop(discard: true) { result in
                        switch result {
                        case .failure(let error): complete(.failure(error))
                        case .success(let recording):
                            guard recording.frames >= 3200 else {
                                complete(.failure(NativeAudioRecorder.Failure.empty)); return
                            }
                            let db = 20 * log10(max(peak, 0.00001))
                            complete(.success(String(format: "%.1f", db)))
                        }
                    }
                }
            }
        }
    }
    enum TestError: LocalizedError {
        case busy
        var errorDescription: String? { "Идёт диктовка или проверка — повторите позже" }
    }
}
