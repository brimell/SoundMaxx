import AVFoundation
import CoreAudio
import AudioToolbox

class AudioEngine: ObservableObject {
    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var parametricEQ: ParametricEQ?
    private var inputRenderBufferList: UnsafeMutableAudioBufferListPointer?
    private var inputRenderChannelData: [UnsafeMutablePointer<Float>] = []
    private var inputRenderFrameCapacity: UInt32 = 0

    private var ringBuffer: RingBuffer?
    private let bufferSize: UInt32 = 4096
    private var currentBands: [EQBand] = EQBand.defaultTenBand
    private var currentBypassState = false

    @Published var isRunning = false
    @Published var selectedInputDeviceID: AudioDeviceID?
    @Published var selectedOutputDeviceID: AudioDeviceID?
    @Published var errorMessage: String?

    // Software volume control (0.0 to 1.0)
    @Published var softwareVolume: Float = 1.0
    @Published var preGain: Float = 0.0

    // Device info
    @Published var outputDeviceNeedsVolumeControl = false
    @Published var outputDeviceUID: String?
    @Published var outputDeviceName: String?

    // Callback for device changes
    var onOutputDeviceChanged: ((AudioDeviceID, String, String) -> Void)?

    static let bandFrequencies: [Float] = EQBand.defaultFrequencies

    init() {}

    func setVolume(_ volume: Float) {
        softwareVolume = max(0.0, min(1.0, volume))
    }

    func setPreGain(_ gain: Float) {
        preGain = max(-24.0, min(24.0, gain))
        parametricEQ?.setPreGain(preGain)
    }

    func setGain(forBand band: Int, gain: Float) {
        guard currentBands.indices.contains(band) else { return }
        currentBands[band].gain = gain
        parametricEQ?.setGain(band: band, gain: gain)
    }

    func setBands(_ bands: [EQBand]) {
        currentBands = bands.isEmpty ? EQBand.defaultTenBand : bands
        parametricEQ?.setBands(currentBands)
    }

    func setAllGains(_ gains: [Float]) {
        for index in currentBands.indices where index < gains.count {
            currentBands[index].gain = gains[index]
        }
        parametricEQ?.setAllGains(gains)
    }

    func setBypass(_ bypass: Bool) {
        currentBypassState = bypass
        parametricEQ?.bypass = bypass
    }

    func setInputDevice(_ deviceID: AudioDeviceID) {
        // Ignore no-op selections so menu/view reappears do not restart audio.
        guard selectedInputDeviceID != deviceID else { return }
        selectedInputDeviceID = deviceID
        if isRunning {
            stop()
            start()
        }
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) {
        // Ignore no-op selections so menu/view reappears do not restart audio.
        guard selectedOutputDeviceID != deviceID else { return }
        selectedOutputDeviceID = deviceID

        // Get device info
        if let name = getDeviceName(deviceID),
           let uid = DeviceInfo.getDeviceUID(deviceID) {
            outputDeviceUID = uid
            outputDeviceName = name
            outputDeviceNeedsVolumeControl = !DeviceInfo.hasHardwareVolumeControl(deviceID)

            // Notify about device change
            onOutputDeviceChanged?(deviceID, uid, name)
        }

        if isRunning {
            stop()
            start()
        }
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var unmanagedName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &unmanagedName)
        guard status == noErr, let deviceName = unmanagedName?.takeRetainedValue() else { return nil }
        return deviceName as String
    }

    func start() {
        guard !isRunning else { return }

        guard let inputDeviceID = selectedInputDeviceID else {
            errorMessage = "Please select an input device (BlackHole)"
            return
        }

        guard let outputDeviceID = selectedOutputDeviceID else {
            errorMessage = "Please select an output device"
            return
        }

        do {
            // Get sample rates
            let inputSampleRate = try getDeviceSampleRate(inputDeviceID)
            let outputSampleRate = try getDeviceSampleRate(outputDeviceID)

            // Try to match sample rates if different
            var workingSampleRate = inputSampleRate
            if inputSampleRate != outputSampleRate {
                // Try to set output to match input
                if setDeviceSampleRate(outputDeviceID, sampleRate: inputSampleRate) {
                    workingSampleRate = inputSampleRate
                }
                // If that fails, try to set input to match output
                else if setDeviceSampleRate(inputDeviceID, sampleRate: outputSampleRate) {
                    workingSampleRate = outputSampleRate
                }
                // If both fail, use a common rate
                else {
                    let commonRates: [Double] = [48000, 44100, 96000]
                    for rate in commonRates {
                        if setDeviceSampleRate(inputDeviceID, sampleRate: rate) &&
                           setDeviceSampleRate(outputDeviceID, sampleRate: rate) {
                            workingSampleRate = rate
                            break
                        }
                    }
                }
            }

            // Create format - non-interleaved stereo float
            var streamFormat = AudioStreamBasicDescription(
                mSampleRate: workingSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )

            // Initialize ring buffer
            ringBuffer = RingBuffer(channels: 2, bytesPerFrame: 8, capacityFrames: bufferSize * 4)
            prepareInputRenderBuffers(frameCapacity: bufferSize)

            // Create input unit (captures from BlackHole)
            inputUnit = try createInputUnit(deviceID: inputDeviceID, format: &streamFormat)

            // Create output unit (plays to output device)
            outputUnit = try createOutputUnit(deviceID: outputDeviceID, format: &streamFormat)

            // Create parametric EQ
            parametricEQ = ParametricEQ(sampleRate: workingSampleRate, bands: currentBands)
            parametricEQ?.bypass = currentBypassState
            parametricEQ?.setPreGain(preGain)

            // Start units
            var status = AudioOutputUnitStart(inputUnit!)
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Failed to start input unit"])
            }

            status = AudioOutputUnitStart(outputUnit!)
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Failed to start output unit"])
            }

            isRunning = true
            errorMessage = nil

        } catch {
            errorMessage = "Failed to start: \(error.localizedDescription)"
            cleanup()
        }
    }


    private func createInputUnit(deviceID: AudioDeviceID, format: inout AudioStreamBasicDescription) throws -> AudioUnit {
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw NSError(domain: "AudioEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not find HAL output component"])
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create input audio unit"])
        }

        // Enable input, disable output
        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not enable input on input unit"])
        }

        enableIO = 0
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not disable output on input unit"])
        }

        // Set device
        var deviceIDVar = deviceID
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &deviceIDVar, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not set input device"])
        }

        // Set format
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not set stream format for input unit"])
        }

        // Set input callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not set input callback"])
        }

        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not initialize input unit"])
        }

        return audioUnit
    }

    private func createOutputUnit(deviceID: AudioDeviceID, format: inout AudioStreamBasicDescription) throws -> AudioUnit {
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw NSError(domain: "AudioEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not find HAL output component"])
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create output audio unit"])
        }

        // Set device
        var deviceIDVar = deviceID
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &deviceIDVar, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not set output device"])
        }

        // Set format
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not set stream format for output unit"])
        }

        // Set render callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: outputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not set output callback"])
        }

        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not initialize output unit"])
        }

        return audioUnit
    }

    private func getDeviceSampleRate(_ deviceID: AudioDeviceID) throws -> Double {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var sampleRate: Double = 0
        var dataSize = UInt32(MemoryLayout<Double>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &sampleRate)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not get sample rate"])
        }

        return sampleRate
    }

    private func setDeviceSampleRate(_ deviceID: AudioDeviceID, sampleRate: Double) -> Bool {
        if let currentRate = try? getDeviceSampleRate(deviceID), abs(currentRate - sampleRate) < 0.1 {
            return true
        }

        guard deviceSupportsSampleRate(deviceID, sampleRate: sampleRate) else {
            return false
        }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Check if writable
        var isSettable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &propertyAddress, &isSettable)
        guard status == noErr && isSettable.boolValue else {
            return false
        }

        var newSampleRate = sampleRate
        status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<Double>.size),
            &newSampleRate
        )

        return status == noErr
    }

    private func deviceSupportsSampleRate(_ deviceID: AudioDeviceID, sampleRate: Double) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else { return true }

        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.size
        guard count > 0 else { return true }

        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
        status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &ranges)
        guard status == noErr else { return true }

        return ranges.contains { range in
            sampleRate >= range.mMinimum && sampleRate <= range.mMaximum
        }
    }

    private func prepareInputRenderBuffers(frameCapacity: UInt32) {
        releaseInputRenderBuffers()

        var bufferList = AudioBufferList.allocate(maximumBuffers: 2)
        inputRenderFrameCapacity = frameCapacity

        for i in 0..<2 {
            let channelData = UnsafeMutablePointer<Float>.allocate(capacity: Int(frameCapacity))
            channelData.initialize(repeating: 0, count: Int(frameCapacity))
            inputRenderChannelData.append(channelData)

            bufferList[i].mNumberChannels = 1
            bufferList[i].mDataByteSize = frameCapacity * UInt32(MemoryLayout<Float>.size)
            bufferList[i].mData = UnsafeMutableRawPointer(channelData)
        }

        inputRenderBufferList = bufferList
    }

    private func releaseInputRenderBuffers() {
        for channelData in inputRenderChannelData {
            channelData.deinitialize(count: Int(inputRenderFrameCapacity))
            channelData.deallocate()
        }
        inputRenderChannelData.removeAll(keepingCapacity: false)

        if let bufferList = inputRenderBufferList {
            bufferList.unsafeMutablePointer.deallocate()
            inputRenderBufferList = nil
        }

        inputRenderFrameCapacity = 0
    }

    func stop() {
        cleanup()
        isRunning = false
    }

    private func cleanup() {
        if let unit = inputUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
            inputUnit = nil
        }
        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
            outputUnit = nil
        }
        parametricEQ = nil
        ringBuffer = nil
        releaseInputRenderBuffers()
    }

    // Called when input data is available from BlackHole
    fileprivate func handleInputCallback(
        inRefCon: UnsafeMutableRawPointer,
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let inputUnit = inputUnit, let ringBuffer = ringBuffer else { return noErr }
        guard let bufferList = inputRenderBufferList else { return noErr }
        guard inNumberFrames <= inputRenderFrameCapacity else { return noErr }

        for i in 0..<2 {
            bufferList[i].mDataByteSize = inNumberFrames * UInt32(MemoryLayout<Float>.size)
        }

        // Render input
        let status = AudioUnitRender(inputUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, bufferList.unsafeMutablePointer)

        if status == noErr {
            ringBuffer.store(bufferList.unsafeMutablePointer, frameCount: inNumberFrames)
        }

        return status
    }

    // Called when output needs data for Scarlett
    fileprivate func handleOutputCallback(
        inRefCon: UnsafeMutableRawPointer,
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let ioData = ioData, let ringBuffer = ringBuffer else { return noErr }

        // Fetch from ring buffer
        let fetched = ringBuffer.fetch(ioData, frameCount: inNumberFrames)

        if fetched < inNumberFrames {
            // Not enough data, zero fill
            let bufferListPtr = UnsafeMutableAudioBufferListPointer(ioData)
            for buffer in bufferListPtr {
                if let data = buffer.mData {
                    let bytesToZero = Int((inNumberFrames - fetched) * 4)
                    let offset = Int(fetched * 4)
                    memset(data.advanced(by: offset), 0, bytesToZero)
                }
            }
        }

        // Apply EQ processing to the output buffer
        if let eq = parametricEQ, !eq.bypass {
            let bufferListPtr = UnsafeMutableAudioBufferListPointer(ioData)
            for (channelIndex, buffer) in bufferListPtr.enumerated() where channelIndex < 2 {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                eq.process(buffer: data, frameCount: Int(inNumberFrames), channel: channelIndex)
            }
        }

        // Apply software volume
        let volume = softwareVolume
        if volume < 1.0 {
            let bufferListPtr = UnsafeMutableAudioBufferListPointer(ioData)
            for buffer in bufferListPtr {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(inNumberFrames) {
                    data[i] *= volume
                }
            }
        }

        return noErr
    }
}

// Ring buffer for passing audio between input and output callbacks
class RingBuffer {
    private var buffer: UnsafeMutablePointer<Float>
    private let capacityFrames: UInt32
    private let channels: UInt32
    private var writeIndex: UInt32 = 0
    private var readIndex: UInt32 = 0
    private let lock = NSLock()

    init(channels: UInt32, bytesPerFrame: UInt32, capacityFrames: UInt32) {
        self.channels = channels
        self.capacityFrames = capacityFrames
        buffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(capacityFrames * channels))
        buffer.initialize(repeating: 0, count: Int(capacityFrames * channels))
    }

    deinit {
        buffer.deallocate()
    }

    func store(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        lock.lock()
        defer { lock.unlock() }

        let bufferListPtr = UnsafeMutableAudioBufferListPointer(bufferList)

        for frame in 0..<frameCount {
            for (channelIndex, audioBuffer) in bufferListPtr.enumerated() where channelIndex < Int(channels) {
                if let data = audioBuffer.mData?.assumingMemoryBound(to: Float.self) {
                    let destIndex = Int((writeIndex + frame) % capacityFrames) * Int(channels) + channelIndex
                    buffer[destIndex] = data[Int(frame)]
                }
            }
        }

        writeIndex = (writeIndex + frameCount) % capacityFrames
    }

    func fetch(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }

        let available = (writeIndex >= readIndex) ? (writeIndex - readIndex) : (capacityFrames - readIndex + writeIndex)
        let toRead = min(frameCount, available)

        let bufferListPtr = UnsafeMutableAudioBufferListPointer(bufferList)

        for frame in 0..<toRead {
            for (channelIndex, audioBuffer) in bufferListPtr.enumerated() where channelIndex < Int(channels) {
                if let data = audioBuffer.mData?.assumingMemoryBound(to: Float.self) {
                    let srcIndex = Int((readIndex + frame) % capacityFrames) * Int(channels) + channelIndex
                    data[Int(frame)] = buffer[srcIndex]
                }
            }
        }

        readIndex = (readIndex + toRead) % capacityFrames
        return toRead
    }
}

// C callbacks that forward to the AudioEngine instance
private func inputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return engine.handleInputCallback(
        inRefCon: inRefCon,
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inBusNumber: inBusNumber,
        inNumberFrames: inNumberFrames,
        ioData: ioData
    )
}

private func outputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return engine.handleOutputCallback(
        inRefCon: inRefCon,
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inBusNumber: inBusNumber,
        inNumberFrames: inNumberFrames,
        ioData: ioData
    )
}
