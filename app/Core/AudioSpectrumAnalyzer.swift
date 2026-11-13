import Accelerate
import Foundation

/// Текущий спектр PCM16/16 kHz. Полосы привязаны к частотам, а не к истории уровней.
/// Используется уже записанный PCM; микрофон и поток для ASR не меняются.
final class AudioSpectrumAnalyzer {
    static let bandCount = 18
    static let frameSize = 1024 // 64 мс звука, один небольшой DFT на кадр.
    private static let window: [Float] = (0..<frameSize).map {
        0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(frameSize))
    }
    private static let bands: [Range<Int>] = (0..<bandCount).map { index in
        let lower = 80 * pow(7600.0 / 80, Double(index) / Double(bandCount))
        let upper = 80 * pow(7600.0 / 80, Double(index + 1) / Double(bandCount))
        let first = max(1, Int(lower * Double(frameSize) / 16_000))
        let end = min(frameSize / 2, max(first + 1, Int(upper * Double(frameSize) / 16_000)))
        return first..<end
    }

    private let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(frameSize), .FORWARD)
    private var samples = [Float](repeating: 0, count: frameSize)
    private var input = [Float](repeating: 0, count: frameSize)
    private let imaginary = [Float](repeating: 0, count: frameSize)
    private var realOutput = [Float](repeating: 0, count: frameSize)
    private var imaginaryOutput = [Float](repeating: 0, count: frameSize)
    private var position = 0

    /// Вызывается в main, куда PCMSink уже передаёт PCM для распознавания.
    /// Возвращается последний целый кадр, без очереди устаревших кадров для UI.
    func consume(_ pcm: Data) -> [CGFloat]? {
        var latest: [CGFloat]?
        pcm.withUnsafeBytes { raw in
            for value in raw.bindMemory(to: Int16.self) {
                samples[position] = Float(Int16(littleEndian: value)) / 32768
                position += 1
                if position == Self.frameSize {
                    latest = spectrum()
                    position = 0
                }
            }
        }
        return latest
    }

    func reset() { position = 0 }

    private func spectrum() -> [CGFloat] {
        guard let setup else { return [CGFloat](repeating: 0, count: Self.bandCount) }
        for index in 0..<Self.frameSize { input[index] = samples[index] * Self.window[index] }
        vDSP_DFT_Execute(setup, input, imaginary, &realOutput, &imaginaryOutput)
        let scale = Float(4) / Float(Self.frameSize) // Односторонняя амплитуда с учётом окна Hann.
        return Self.bands.map { bins in
            var peak: Float = 0
            for bin in bins {
                let real = realOutput[bin], imaginary = imaginaryOutput[bin]
                peak = max(peak, sqrt(real * real + imaginary * imaginary) * scale)
            }
            let decibels = 20 * log10(max(peak, 0.000001))
            return CGFloat(min(1, max(0, (decibels + 60) / 60)))
        }
    }

    deinit { vDSP_DFT_DestroySetup(setup) }
}
