import AVFoundation
import AudioToolbox

/// Входной AUHAL с выключенным output. Не создаёт AVAudioEngine/AVAudioIOUnit
/// и не зависит от устройства вывода. Настройка — Apple TN2091.
final class HALInput {
    let deviceID: AudioDeviceID
    let format: AVAudioFormat
    private let unit: AudioUnit
    private var initialized = false
    private var context: InputContext?

    init(deviceID: AudioDeviceID) throws {
        let configured = try Self.make(deviceID: deviceID)
        unit = configured.0; format = configured.1; self.deviceID = deviceID
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw NativeAudioRecorder.Failure.openDevice(status) }
    }

    private static func make(deviceID: AudioDeviceID) throws -> (AudioUnit, AVAudioFormat) {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw NativeAudioRecorder.Failure.format }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance))
        guard let unit = instance else { throw NativeAudioRecorder.Failure.format }
        do {
            var enable: UInt32 = 1
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                            &enable, UInt32(MemoryLayout<UInt32>.size)))
            enable = 0
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                            &enable, UInt32(MemoryLayout<UInt32>.size)))
            var device = deviceID
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                            &device, UInt32(MemoryLayout<AudioDeviceID>.size)))
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                            &hardware, &size))
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                                             channels: hardware.mChannelsPerFrame, interleaved: false) else {
                throw NativeAudioRecorder.Failure.format
            }
            var client = format.streamDescription.pointee
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                            &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            var frames: UInt32 = 8192
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                            &frames, UInt32(MemoryLayout<UInt32>.size)))
            // AudioUnitRender пишет в заранее выделенные AVAudioPCMBuffer.
            var allocate: UInt32 = 0
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1,
                                            &allocate, UInt32(MemoryLayout<UInt32>.size)))
            return (unit, format)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    var formatMatchesHardware: Bool {
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                    &hardware, &size) == noErr
            && hardware.mSampleRate == format.sampleRate && hardware.mChannelsPerFrame == format.channelCount
    }

    var isRunning: Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0,
                                    &running, &size) == noErr && running != 0
    }

    func start(sink: PCMSink, queue: DispatchQueue) throws {
        let context = InputContext(unit: unit, format: format, sink: sink, queue: queue)
        self.context = context
        var callback = AURenderCallbackStruct(inputProc: { reference, flags, timestamp, _, frames, _ in
            return Unmanaged<InputContext>.fromOpaque(reference).takeUnretainedValue()
                .render(flags: flags, timestamp: timestamp, frames: frames)
        }, inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
        do {
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            if !initialized { try Self.check(AudioUnitInitialize(unit)); initialized = true }
            try Self.check(AudioOutputUnitStart(unit))
        } catch { stop(); throw error }
    }

    func resume() throws { try Self.check(AudioOutputUnitStart(unit)) }

    func stop() {
        // Stop синхронизируется с I/O callback; context освобождается только после него.
        AudioOutputUnitStop(unit)
        var callback = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                             &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        context = nil
    }

    deinit {
        stop()
        if initialized { AudioUnitUninitialize(unit) }
        AudioComponentInstanceDispose(unit)
    }
}

private final class InputContext {
    private let unit: AudioUnit
    private let pool: CapturePool
    private let sink: PCMSink
    private let queue: DispatchQueue
    init(unit: AudioUnit, format: AVAudioFormat, sink: PCMSink, queue: DispatchQueue) {
        self.unit = unit; self.sink = sink; self.queue = queue
        pool = CapturePool(format: format, capacity: 8192, count: 32)
    }
    func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>,
                frames: UInt32) -> OSStatus {
        guard frames > 0 else { return noErr }
        guard frames <= 8192, let buffer = pool.take() else {
            sink.fail(NativeAudioRecorder.Failure.overflow); return noErr
        }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, buffer.mutableAudioBufferList)
        queue.async { [sink, pool] in
            if status == noErr { sink.consume(buffer) }
            else { sink.fail(NativeAudioRecorder.Failure.openDevice(status)) }
            pool.put(buffer)
        }
        return noErr
    }
}
