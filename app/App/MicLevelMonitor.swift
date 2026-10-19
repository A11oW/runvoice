import AVFoundation
import AppKit

/// Снимает уровень микрофона параллельно с записью ffmpeg.
final class MicLevelMonitor {
    var onLevel: ((CGFloat) -> Void)?

    private let engine = AVAudioEngine()
    private var timer: Timer?
    private var latestPeak: Float = 0
    private var displayed: CGFloat = 0
    private var running = false

    func start() {
        guard !running else { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            Log.write("mic level: no input format")
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(data[i]))
            }
            self.latestPeak = peak
        }

        do {
            engine.prepare()
            try engine.start()
            running = true
            Log.write("mic level: started")
        } catch {
            Log.write("mic level: \(error.localizedDescription)")
            return
        }

        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.emit()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard running else { return }

        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        latestPeak = 0
        displayed = 0
        onLevel?(0)
        Log.write("mic level: stopped")
    }

    private func emit() {
        // -60 dB … 0 dB → 0…1, быстрая атака и плавный спад
        let db = 20 * log10(max(latestPeak, 0.00001))
        let normalized = CGFloat(max(0, min(1, (db + 60) / 60)))
        displayed = max(normalized, displayed * 0.72)
        onLevel?(displayed)
    }
}
