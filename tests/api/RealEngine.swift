import Foundation
import Darwin

/// Изолированная проверка ASR и HTTP на синтетической речи, без микрофона и AI.
@main struct RealEngineProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let audio = URL(fileURLWithPath: args[1])
        let model = args[2]
        var settings = Settings(); settings.apiAudioFilterEnabled = true; settings.apiEnabled = true; settings.apiImproveText = false
        settings.whisperModelPath = model; settings.language = "ru"; settings.apiPort = Int(args[3])!
        let engine = APIRecognitionEngine(backendPort: Int(args[4])!)
        let service = LocalAPIService(engine: engine, loadSettings: { settings })
        defer { service.stop() }
        let pcm = try LocalAPIWire.pcm(from: Data(contentsOf: audio))
        var records: [[String: Any]] = []
        func wait(_ message: String, timeout: TimeInterval = 90, _ ready: () -> Bool) throws {
            let until = Date().addingTimeInterval(timeout)
            while !ready(), Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            if !ready() { throw LocalAPIError(500, message) }
        }
        func direct() throws -> (String, Double) {
            let began = ProcessInfo.processInfo.systemUptime
            var result: Result<String, Error>?
            engine.transcribe(pcm: pcm, settings: settings.apiRecognitionSettings) { result = $0 }
            try wait("Direct ASR timeout") { result != nil }
            return (try result!.get(), (ProcessInfo.processInfo.systemUptime - began) * 1000)
        }
        func api() throws -> (String, Double) {
            let boundary = "real-probe"
            var body = Data()
            for (key, value) in [("model","runvoice-active"),("response_format","json")] {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
            }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n\r\n".utf8))
            body.append(LiveTranscriber.wav(pcm: pcm)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: URL(string: LocalAPIService.endpoint(port: settings.apiPort))!)
            request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 90
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let began = ProcessInfo.processInfo.systemUptime
            var output: Result<String, Error>?
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                DispatchQueue.main.async {
                    if (response as? HTTPURLResponse)?.statusCode == 200, let text = json?["text"] as? String { output = .success(text) }
                    else { output = .failure(LocalAPIError(500,"API recognition failed")) }
                }
            }.resume()
            try wait("HTTP ASR timeout") { output != nil }
            return (try output!.get(), (ProcessInfo.processInfo.systemUptime - began) * 1000)
        }
        for technology in [RecognitionTechnology.whisper, .fluidAudio] {
            if technology == .fluidAudio, !FluidModelStore.installed(.nemotron) { print("SKIP: Nemotron weights unavailable"); continue }
            // API выбирает модель явно, технология приложения при этом противоположна.
            settings.recognitionTechnology = technology == .whisper ? .fluidAudio : .whisper
            settings.apiRecognitionModel = technology == .whisper ? .whisper(model) : .fluidAudio(.nemotron)
            settings.fluidModel = .nemotron
            let cold = ProcessInfo.processInfo.systemUptime
            service.configure(settings)
            try wait("Model warmup failed") { service.health()["status"] as? String == "ready" }
            let warmup = (ProcessInfo.processInfo.systemUptime - cold)*1000
            let firstRequest = try api()
            _ = try direct()
            var directMS: [Double] = [], apiMS: [Double] = []
            var text = ""
            for _ in 0..<10 {
                let local = try direct(); directMS.append(local.1)
                let remote = try api(); apiMS.append(remote.1); text = remote.0
                guard !local.0.isEmpty, !remote.0.isEmpty else { throw LocalAPIError(500,"Empty real ASR result") }
            }
            // Другая сессия получает начало фразы, пока API распознаёт свою копию.
            var parallelOK = false
            if technology == .fluidAudio {
                let dictation = FluidSpeechClient()
                dictation.warmUp(model: .nemotron)
                defer { dictation.unload() }
                try wait("Parallel dictation warmup failed") { dictation.ready }
                dictation.start(model: .nemotron, language: "ru")
                let split = pcm.count / 4 * 2
                dictation.append(pcm.prefix(split))
                let _ = try api()
                dictation.append(pcm.suffix(from: split))
                var final: String?
                var finished = false
                dictation.finish { final = $0; finished = true }
                try wait("Parallel dictation finish failed") { finished }
                parallelOK = final?.isEmpty == false
                guard parallelOK else { throw LocalAPIError(500,"API interrupted independent dictation") }
            } else {
                let other = APIRecognitionEngine(backendPort: Int(args[5])!)
                defer { other.shutdown() }
                var ready = false
                other.prepare(settings: settings.apiRecognitionSettings) { if case .success = $0 { ready = true } }
                try wait("Second Whisper warmup failed") { ready }
                var otherResult: String?
                other.transcribe(pcm: pcm, settings: settings.apiRecognitionSettings) { if case .success(let value) = $0 { otherResult = value } }
                let _ = try api()
                try wait("Independent Whisper inference failed") { otherResult != nil }
                parallelOK = otherResult?.isEmpty == false
            }
            func p(_ values: [Double], _ fraction: Double) -> Int { Int(values.sorted()[Int((Double(values.count)-1)*fraction)].rounded()) }
            records.append(["technology":technology.rawValue,"model":LocalAPIService.modelName(settings),
                            "audio_seconds":Double(pcm.count)/32000,"warmup_ms":Int(warmup),"first_request_ms":Int(firstRequest.1),"iterations":10,
                            "direct_ms":directMS,"api_ms":apiMS,"direct_median_ms":p(directMS,0.5),
                            "api_median_ms":p(apiMS,0.5),"direct_p95_ms":p(directMS,1),"api_p95_ms":p(apiMS,1),
                            "parallel_session_ok":parallelOK,"independent_api_selection":settings.recognitionTechnology != technology,
                            "synthetic_transcript":text])
        }
        let report = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted,.sortedKeys])
        try report.write(to: URL(fileURLWithPath: args[6]))
        print(String(data:report,encoding:.utf8)!)
        print("OK: real Whisper, available FluidAudio, direct/API benchmark and independent sessions")
    }
}
