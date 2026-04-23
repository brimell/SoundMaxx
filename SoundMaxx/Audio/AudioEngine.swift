import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import os

class AudioEngine: ObservableObject {
    private struct RealtimeUIState {
        var eqStagePeakSample: Float = 0.0
        var eqStagePeakHoldSample: Float = 0.0
        var eqStageClippingDetected = false
        var outputLimiterEngaged = false
        var outputPeakSample: Float = 0.0
        var outputPeakHoldSample: Float = 0.0
        var outputStageClippingDetected = false
        var clippingDetected = false
        var spectrumBins: [Float] = Array(repeating: 0.0, count: SpectrumAnalyzer.defaultBarCount)
    }

    static let supportedIOBufferFrames: [UInt32] = [64, 128, 256, 512, 1024, 2048, 4096]
    static let defaultIOBufferFrames: UInt32 = 256
    static let defaultRingBufferCapacityMultiplier: UInt32 = 4
    static let defaultLatencyTargetMultiplier: UInt32 = 2

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var parametricEQ: ParametricEQ?
    private var inputRenderBufferList: UnsafeMutableAudioBufferListPointer?
    private var inputRenderChannelData: [UnsafeMutablePointer<Float>] = []
    private var inputRenderFrameCapacity: UInt32 = 0

    private var ringBuffer: RingBuffer?
    private var outputLimiter: OutputLimiter?
    private var requestedIOBufferFrames: UInt32 = AudioEngine.defaultIOBufferFrames
    private var ringBufferCapacityMultiplier: UInt32 = AudioEngine.defaultRingBufferCapacityMultiplier
    private var latencyTargetMultiplier: UInt32 = AudioEngine.defaultLatencyTargetMultiplier
    private let deviceManager = AudioDeviceManager()
    private var currentBands: [EQBand] = EQBand.defaultTenBand
    private var currentBypassState = false
    private var currentEQFiltersEnabled = true

    @Published var isRunning = false
    @Published var selectedInputDeviceID: AudioDeviceID?
    @Published var selectedOutputDeviceID: AudioDeviceID?
    @Published var errorMessage: String?
    @Published private(set) var processingSampleRate: Double = 48000
    @Published private(set) var effectiveInputBufferFrames: UInt32 = AudioEngine.defaultIOBufferFrames
    @Published private(set) var effectiveOutputBufferFrames: UInt32 = AudioEngine.defaultIOBufferFrames
    @Published private(set) var effectiveRingBufferCapacityFrames: UInt32 = AudioEngine.defaultIOBufferFrames * AudioEngine.defaultRingBufferCapacityMultiplier

    // Software volume control (0.0 to 1.0)
    @Published var softwareVolume: Float = 1.0
    @Published var preGain: Float = 0.0
    @Published var outputGain: Float = 0.0
    private var outputGainLinear: Float = 1.0
    @Published var limiterEnabled: Bool = false
    @Published var limiterCeilingDB: Float = -1.0
    @Published var autoStopClippingEnabled: Bool = false
    @Published private(set) var eqStagePeakSample: Float = 0.0
    @Published private(set) var eqStagePeakHoldSample: Float = 0.0
    @Published private(set) var eqStageClippingDetected: Bool = false
    @Published private(set) var outputLimiterEngaged: Bool = false
    @Published private(set) var outputPeakSample: Float = 0.0
    @Published private(set) var outputPeakHoldSample: Float = 0.0
    @Published private(set) var outputStageClippingDetected: Bool = false
    @Published private(set) var spectrumBins: [Float] = Array(repeating: 0.0, count: SpectrumAnalyzer.defaultBarCount)

    // Backward-compatible alias for existing UI usage.
    @Published private(set) var clippingDetected: Bool = false

    private var autoStopClippingRuntimeEnabled = false
    private var lastAutoPreGainAdjustmentTime: TimeInterval = 0
    private let autoPreGainAdjustmentInterval: TimeInterval = 0.25
    private let autoPreGainHeadroomDB: Float = 0.2
    private let clippingIndicatorHoldDuration: TimeInterval = 1.0
    private let meterPublishInterval: TimeInterval = 1.0 / 20.0
    private var eqClippingHoldUntilTime: TimeInterval = 0
    private var limiterEngagedHoldUntilTime: TimeInterval = 0
    private var outputClippingHoldUntilTime: TimeInterval = 0
    private var lastMeterPublishTime: TimeInterval = 0
    private var lastEQMeterPeakSample: Float = 0.0
    private var lastEQMeterPeakHoldSample: Float = 0.0
    private var lastOutputMeterPeakSample: Float = 0.0
    private var lastOutputMeterPeakHoldSample: Float = 0.0
    private var lastEQMeterClippingDetected = false
    private var lastLimiterEngagedState = false
    private var lastOutputMeterClippingDetected = false
    private var spectrumAnalyzer: SpectrumAnalyzer?
    private let spectrumPublishInterval: TimeInterval = 1.0 / 30.0
    private var lastSpectrumPublishTime: TimeInterval = 0
    private let realtimeUIStateLock = OSAllocatedUnfairLock(initialState: RealtimeUIState())
    private var uiPublishTimer: DispatchSourceTimer?

    // Device info
    @Published var outputDeviceNeedsVolumeControl = false
    @Published var outputDeviceUID: String?
    @Published var outputDeviceName: String?

    // Callback for device changes
    var onOutputDeviceChanged: ((AudioDeviceID, String, String) -> Void)?
    var onPreGainAutoAdjusted: ((Float) -> Void)?

    private var hardwareDevicesChangedListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputDeviceChangedListener: AudioObjectPropertyListenerBlock?

    static let bandFrequencies: [Float] = EQBand.defaultFrequencies
    static let microphoneAccessDeniedMessage = "Microphone access is denied. SoundMaxx needs microphone permission to capture audio input. Enable it in System Settings > Privacy & Security > Microphone, then restart SoundMaxx."

    init() {
        registerHardwareDeviceListener()
        registerDefaultOutputDeviceListener()
        enforceBlackHoleAsDefaultOutput()
    }

    deinit {
        unregisterHardwareDeviceListener()
        unregisterDefaultOutputDeviceListener()
    }

    var preferredIOBufferFrames: UInt32 {
        requestedIOBufferFrames
    }

    var preferredRingBufferCapacityMultiplier: UInt32 {
        ringBufferCapacityMultiplier
    }

    var preferredLatencyTargetMultiplier: UInt32 {
        latencyTargetMultiplier
    }

    func updateLatencySettings(ioBufferFrames: UInt32, ringCapacityMultiplier: UInt32, latencyTargetMultiplier: UInt32) {
        let clampedFrames = Self.clampIOBufferFrames(ioBufferFrames)
        let clampedRingMultiplier = max(1, min(ringCapacityMultiplier, 16))
        let clampedLatencyTargetMultiplier = max(1, min(latencyTargetMultiplier, clampedRingMultiplier))

        let hasChanges =
            requestedIOBufferFrames != clampedFrames ||
            ringBufferCapacityMultiplier != clampedRingMultiplier ||
            self.latencyTargetMultiplier != clampedLatencyTargetMultiplier

        requestedIOBufferFrames = clampedFrames
        ringBufferCapacityMultiplier = clampedRingMultiplier
        self.latencyTargetMultiplier = clampedLatencyTargetMultiplier

        guard hasChanges, isRunning else { return }
        stop()
        start()
    }

    private static func clampIOBufferFrames(_ value: UInt32) -> UInt32 {
        if supportedIOBufferFrames.contains(value) {
            return value
        }
        return supportedIOBufferFrames.min(by: { abs(Int64($0) - Int64(value)) < abs(Int64($1) - Int64(value)) }) ?? defaultIOBufferFrames
    }

    func setVolume(_ volume: Float) {
        softwareVolume = max(0.0, min(1.0, volume))
    }

    func setPreGain(_ gain: Float) {
        preGain = max(-12.0, min(0.0, gain))
        parametricEQ?.setPreGain(preGain)
    }

    func setOutputGain(_ gain: Float) {
        outputGain = max(-40.0, min(40.0, gain))
        outputGainLinear = powf(10.0, outputGain / 20.0)
    }

    func setLimiterEnabled(_ enabled: Bool) {
        limiterEnabled = enabled
        if enabled {
            outputLimiter?.reset()
        }
    }

    func setLimiterCeilingDB(_ value: Float) {
        limiterCeilingDB = max(-6.0, min(-0.1, value))
        outputLimiter?.setCeilingDB(limiterCeilingDB)
    }

    func setAutoStopClippingEnabled(_ enabled: Bool) {
        autoStopClippingEnabled = enabled
        autoStopClippingRuntimeEnabled = enabled
    }

    func clearSafetyMeters() {
        resetClippingMeterState()
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

    func setEQFiltersEnabled(_ enabled: Bool) {
        currentEQFiltersEnabled = enabled
        parametricEQ?.setFiltersEnabled(enabled)
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

    private func registerHardwareDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.handleOutputDeviceListChanged()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.global(qos: .userInitiated),
            listener
        )

        guard status == noErr else {
            print("Failed to register hardware device listener (status: \(status))")
            return
        }

        hardwareDevicesChangedListener = listener
    }

    private func unregisterHardwareDeviceListener() {
        guard let listener = hardwareDevicesChangedListener else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.global(qos: .userInitiated),
            listener
        )

        hardwareDevicesChangedListener = nil
    }

    private func registerDefaultOutputDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.enforceBlackHoleAsDefaultOutput()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.global(qos: .userInitiated),
            listener
        )

        guard status == noErr else {
            print("Failed to register default output listener (status: \(status))")
            return
        }

        defaultOutputDeviceChangedListener = listener
    }

    private func unregisterDefaultOutputDeviceListener() {
        guard let listener = defaultOutputDeviceChangedListener else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.global(qos: .userInitiated),
            listener
        )

        defaultOutputDeviceChangedListener = nil
    }

    private func enforceBlackHoleAsDefaultOutput() {
        deviceManager.refreshDevices()
        guard let blackHoleOutput = deviceManager.outputDevices.first(where: { $0.name.lowercased().contains("blackhole") }) else {
            return
        }

        if let currentDefaultOutput = deviceManager.getDefaultOutputDevice(),
           currentDefaultOutput == blackHoleOutput.id {
            return
        }

        _ = setSystemDefaultOutputDevice(blackHoleOutput.id)
    }

    @discardableResult
    private func setSystemDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var writable: DarwinBoolean = false
        let writableStatus = AudioObjectIsPropertySettable(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            &writable
        )

        guard writableStatus == noErr, writable.boolValue else {
            return false
        }

        var updatedDeviceID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &updatedDeviceID
        )

        if status != noErr {
            print("Failed to set default output to BlackHole (status: \(status))")
        }

        return status == noErr
    }

    private func handleOutputDeviceListChanged() {
        guard let selectedOutputDeviceID else { return }

        deviceManager.refreshDevices()
        let outputStillConnected = deviceManager.outputDevices.contains { $0.id == selectedOutputDeviceID }
        guard !outputStillConnected else { return }

        let preferredUIDs = AppSettingsStore.shared.load()?.shortcutOutputDeviceUIDs
        let fallbackDevice = deviceManager.nextOutputDevice(
            after: selectedOutputDeviceID,
            preferredUIDs: preferredUIDs
        )

        if let fallbackDevice {
            setOutputDevice(fallbackDevice.id)
            AppSettingsStore.shared.update { settings in
                settings.selectedOutputDeviceID = Int32(fallbackDevice.id)
            }
            return
        }

        if let defaultOutputDeviceID = deviceManager.getDefaultOutputDevice(),
           deviceManager.outputDevices.contains(where: { $0.id == defaultOutputDeviceID }) {
            setOutputDevice(defaultOutputDeviceID)
            AppSettingsStore.shared.update { settings in
                settings.selectedOutputDeviceID = Int32(defaultOutputDeviceID)
            }
        }
    }

    func start() {
        guard !isRunning else { return }

        let micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micAuthorization == .authorized else {
            errorMessage = Self.microphoneAccessDeniedMessage
            return
        }

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

            processingSampleRate = workingSampleRate
            setupSpectrumAnalyzer(sampleRate: Float(workingSampleRate))

            let desiredBufferFrames = requestedIOBufferFrames
            let inputBufferFrames = setDeviceBufferFrameSize(deviceID: inputDeviceID, requestedFrames: desiredBufferFrames) ?? desiredBufferFrames
            let outputBufferFrames = setDeviceBufferFrameSize(deviceID: outputDeviceID, requestedFrames: desiredBufferFrames) ?? desiredBufferFrames
            effectiveInputBufferFrames = inputBufferFrames
            effectiveOutputBufferFrames = outputBufferFrames

            let callbackFrameCapacity = max(inputBufferFrames, outputBufferFrames)
            let ringCapacityFrames = max(callbackFrameCapacity * ringBufferCapacityMultiplier, callbackFrameCapacity)

            // Initialize ring buffer.
            ringBuffer = RingBuffer(channels: 2, bytesPerFrame: 8, capacityFrames: ringCapacityFrames)
            effectiveRingBufferCapacityFrames = ringCapacityFrames
            prepareInputRenderBuffers(frameCapacity: callbackFrameCapacity)
            resetClippingMeterState()

            // Create input unit (captures from BlackHole)
            inputUnit = try createInputUnit(deviceID: inputDeviceID, format: &streamFormat)

            // Create output unit (plays to output device)
            outputUnit = try createOutputUnit(deviceID: outputDeviceID, format: &streamFormat)

            // Create parametric EQ
            parametricEQ = ParametricEQ(sampleRate: workingSampleRate, bands: currentBands)
            parametricEQ?.bypass = currentBypassState
            parametricEQ?.setFiltersEnabled(currentEQFiltersEnabled)
            parametricEQ?.setPreGain(preGain)

            // Final output limiter/clip guard.
            outputLimiter = OutputLimiter(sampleRate: Float(workingSampleRate), ceilingDB: limiterCeilingDB)

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
            startUIPublishTimer()

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

        var maxFramesPerSlice = max(effectiveInputBufferFrames, requestedIOBufferFrames)
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                                      kAudioUnitScope_Global, 0, &maxFramesPerSlice, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not set max frames per slice for input unit"])
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

        var maxFramesPerSlice = max(effectiveOutputBufferFrames, requestedIOBufferFrames)
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                                      kAudioUnitScope_Global, 0, &maxFramesPerSlice, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not set max frames per slice for output unit"])
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

    private func setDeviceBufferFrameSize(deviceID: AudioDeviceID, requestedFrames: UInt32) -> UInt32? {
        guard let range = getDeviceBufferFrameSizeRange(deviceID: deviceID) else { return nil }

        let minFrames = max(16.0, range.mMinimum)
        let maxFrames = max(minFrames, range.mMaximum)
        let clamped = min(max(Double(requestedFrames), minFrames), maxFrames)
        let roundedRequested = UInt32(clamped.rounded())

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isSettable: DarwinBoolean = false
        let isSettableStatus = AudioObjectIsPropertySettable(deviceID, &propertyAddress, &isSettable)
        if isSettableStatus == noErr && isSettable.boolValue {
            var requested = roundedRequested
            _ = AudioObjectSetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &requested
            )
        }

        var currentFrames: UInt32 = roundedRequested
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let readStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &currentFrames)
        if readStatus != noErr {
            return roundedRequested
        }

        return currentFrames
    }

    private func getDeviceBufferFrameSizeRange(deviceID: AudioDeviceID) -> AudioValueRange? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var dataSize = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &range)
        guard status == noErr else { return nil }
        return range
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
        stopUIPublishTimer()

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
        outputLimiter = nil
        spectrumAnalyzer = nil
        ringBuffer = nil
        releaseInputRenderBuffers()
        resetClippingMeterState()
        resetSpectrumState()
    }

    private func startUIPublishTimer() {
        stopUIPublishTimer()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            self?.publishRealtimeStateToUI()
        }
        timer.resume()
        uiPublishTimer = timer
    }

    private func stopUIPublishTimer() {
        uiPublishTimer?.cancel()
        uiPublishTimer = nil
    }

    private func publishRealtimeStateToUI() {
        let snapshot = realtimeUIStateLock.withLock { state in
            state
        }

        eqStagePeakSample = snapshot.eqStagePeakSample
        eqStagePeakHoldSample = snapshot.eqStagePeakHoldSample
        eqStageClippingDetected = snapshot.eqStageClippingDetected
        outputLimiterEngaged = snapshot.outputLimiterEngaged
        outputPeakSample = snapshot.outputPeakSample
        outputPeakHoldSample = snapshot.outputPeakHoldSample
        outputStageClippingDetected = snapshot.outputStageClippingDetected
        clippingDetected = snapshot.clippingDetected
        spectrumBins = snapshot.spectrumBins
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
        let frameCount = Int(inNumberFrames)

        let desiredLatencyFrames = max(effectiveOutputBufferFrames * latencyTargetMultiplier, effectiveOutputBufferFrames)
        ringBuffer.trimBufferedFrames(maxBufferedFrames: desiredLatencyFrames + inNumberFrames)

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

        // Apply EQ processing to the output buffer.
        if let eq = parametricEQ, !eq.bypass {
            let bufferListPtr = UnsafeMutableAudioBufferListPointer(ioData)
            for (channelIndex, buffer) in bufferListPtr.enumerated() where channelIndex < 2 {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                eq.process(buffer: data, frameCount: frameCount, channel: channelIndex)
            }
        }

        let bufferListPtr = UnsafeMutableAudioBufferListPointer(ioData)
        let processingEnabled = !currentBypassState
        let applyOutputGain = processingEnabled && fabsf(outputGainLinear - 1.0) > 0.0001

        // Meter EQ stage and apply post-EQ output gain in one pass.
        var eqStagePeak: Float = 0.0
        for buffer in bufferListPtr {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frameCount {
                let sample = data[i]
                let absSample = fabsf(sample)
                if absSample > eqStagePeak {
                    eqStagePeak = absSample
                }
                if applyOutputGain {
                    data[i] = sample * outputGainLinear
                }
            }
        }

        // Auto-stop clipping is a headroom guard for the EQ stage.
        let autoStopEnabled = autoStopClippingRuntimeEnabled
        if autoStopEnabled && processingEnabled {
            reducePreGainIfClipping(eqStagePeak)
        }

        // Spectrum intentionally taps the post-EQ signal so frequency changes track EQ moves.
        processSpectrum(bufferList: bufferListPtr, frameCount: Int(inNumberFrames))

        // Apply final limiter / clip guard.
        var limiterEngagedInBlock = false
        if processingEnabled, limiterEnabled, let limiter = outputLimiter {
            limiter.setCeilingDB(limiterCeilingDB)
            limiterEngagedInBlock = applyLimiter(limiter, to: ioData, frameCount: frameCount)
        }

        // Apply final software volume (mainly for outputs without hardware volume control).
        let volume = softwareVolume
        var outputStagePeak: Float = 0.0
        for buffer in bufferListPtr {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frameCount {
                if volume < 1.0 {
                    data[i] *= volume
                }

                let absSample = fabsf(data[i])
                if absSample > outputStagePeak {
                    outputStagePeak = absSample
                }
            }
        }

        publishStagePeaks(
            eqStagePeakSample: eqStagePeak,
            outputStagePeakSample: outputStagePeak,
            limiterEngaged: limiterEngagedInBlock
        )

        return noErr
    }

    private func applyLimiter(
        _ limiter: OutputLimiter,
        to ioData: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) -> Bool {
        let bufferListPtr = UnsafeMutableAudioBufferListPointer(ioData)
        guard !bufferListPtr.isEmpty else { return false }

        let leftData = bufferListPtr.indices.contains(0)
            ? bufferListPtr[0].mData?.assumingMemoryBound(to: Float.self)
            : nil
        let rightData = bufferListPtr.indices.contains(1)
            ? bufferListPtr[1].mData?.assumingMemoryBound(to: Float.self)
            : nil

        var limiterEngaged = false

        // Stereo-linked limiting; mono streams use the same value for both sides.
        for frame in 0..<frameCount {
            let leftIn = leftData?[frame] ?? 0.0
            let rightIn = rightData?[frame] ?? leftIn
            let limited = limiter.process(left: leftIn, right: rightIn)
            limiterEngaged = limiterEngaged || limited.wasLimited

            leftData?[frame] = limited.left
            if rightData != nil {
                rightData?[frame] = limited.right
            }
        }

        return limiterEngaged
    }

    private func reducePreGainIfClipping(_ peakSample: Float) {
        guard peakSample > 1.0 else { return }

        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastAutoPreGainAdjustmentTime >= autoPreGainAdjustmentInterval else { return }

        let requiredReductionDB = (20.0 * log10f(peakSample)) + autoPreGainHeadroomDB
        guard requiredReductionDB > 0 else { return }

        let currentPreGain = preGain
        let newPreGain = max(-12.0, currentPreGain - requiredReductionDB)
        guard newPreGain < currentPreGain - 0.05 else { return }

        lastAutoPreGainAdjustmentTime = now
        parametricEQ?.setPreGain(newPreGain)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.preGain = newPreGain
            self.onPreGainAutoAdjusted?(newPreGain)
        }
    }

    private func publishStagePeaks(eqStagePeakSample: Float, outputStagePeakSample: Float, limiterEngaged: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        let nextEQPeakHoldSample = max(lastEQMeterPeakHoldSample, eqStagePeakSample)
        let nextOutputPeakHoldSample = max(lastOutputMeterPeakHoldSample, outputStagePeakSample)

        if eqStagePeakSample > 1.0 {
            eqClippingHoldUntilTime = now + clippingIndicatorHoldDuration
        }
        if limiterEngaged {
            limiterEngagedHoldUntilTime = now + clippingIndicatorHoldDuration
        }
        if outputStagePeakSample > 1.0 {
            outputClippingHoldUntilTime = now + clippingIndicatorHoldDuration
        }

        let eqClippingActive = now <= eqClippingHoldUntilTime
        let limiterActive = now <= limiterEngagedHoldUntilTime
        let outputClippingActive = now <= outputClippingHoldUntilTime

        let clippingStateChanged =
            (eqClippingActive != lastEQMeterClippingDetected) ||
            (limiterActive != lastLimiterEngagedState) ||
            (outputClippingActive != lastOutputMeterClippingDetected)

        let peakChangedEnough =
            fabsf(eqStagePeakSample - lastEQMeterPeakSample) >= 0.01 ||
            fabsf(outputStagePeakSample - lastOutputMeterPeakSample) >= 0.01 ||
            fabsf(nextEQPeakHoldSample - lastEQMeterPeakHoldSample) >= 0.01 ||
            fabsf(nextOutputPeakHoldSample - lastOutputMeterPeakHoldSample) >= 0.01

        let publishDue = (now - lastMeterPublishTime) >= meterPublishInterval

        guard clippingStateChanged || peakChangedEnough || publishDue else { return }

        lastMeterPublishTime = now
        lastEQMeterPeakSample = eqStagePeakSample
        lastEQMeterPeakHoldSample = nextEQPeakHoldSample
        lastOutputMeterPeakSample = outputStagePeakSample
        lastOutputMeterPeakHoldSample = nextOutputPeakHoldSample
        lastEQMeterClippingDetected = eqClippingActive
        lastLimiterEngagedState = limiterActive
        lastOutputMeterClippingDetected = outputClippingActive

        realtimeUIStateLock.withLock { state in
            state.eqStagePeakSample = eqStagePeakSample
            state.eqStagePeakHoldSample = nextEQPeakHoldSample
            state.eqStageClippingDetected = eqClippingActive
            state.outputLimiterEngaged = limiterActive
            state.outputPeakSample = outputStagePeakSample
            state.outputPeakHoldSample = nextOutputPeakHoldSample
            state.outputStageClippingDetected = outputClippingActive
            state.clippingDetected = outputClippingActive
        }
    }

    private func setupSpectrumAnalyzer(sampleRate: Float) {
        spectrumAnalyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        lastSpectrumPublishTime = 0
        realtimeUIStateLock.withLock { state in
            state.spectrumBins = Array(repeating: 0.0, count: SpectrumAnalyzer.defaultBarCount)
        }
    }

    private func processSpectrum(bufferList: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard let analyzer = spectrumAnalyzer else { return }

        let left = bufferList.indices.contains(0)
            ? bufferList[0].mData?.assumingMemoryBound(to: Float.self)
            : nil
        let right = bufferList.indices.contains(1)
            ? bufferList[1].mData?.assumingMemoryBound(to: Float.self)
            : nil

        guard analyzer.process(left: left, right: right, frameCount: frameCount) else { return }

        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastSpectrumPublishTime >= spectrumPublishInterval else { return }

        lastSpectrumPublishTime = now
        let bars = analyzer.currentBars
        realtimeUIStateLock.withLock { state in
            state.spectrumBins = bars
        }
    }

    private func resetSpectrumState() {
        lastSpectrumPublishTime = 0
        let resetBins = Array(repeating: Float(0), count: SpectrumAnalyzer.defaultBarCount)
        realtimeUIStateLock.withLock { state in
            state.spectrumBins = resetBins
        }

        DispatchQueue.main.async { [weak self] in
            self?.spectrumBins = resetBins
        }
    }

    private func resetClippingMeterState() {
        eqClippingHoldUntilTime = 0
        limiterEngagedHoldUntilTime = 0
        outputClippingHoldUntilTime = 0
        lastMeterPublishTime = 0
        lastEQMeterPeakSample = 0
        lastEQMeterPeakHoldSample = 0
        lastOutputMeterPeakSample = 0
        lastOutputMeterPeakHoldSample = 0
        lastEQMeterClippingDetected = false
        lastLimiterEngagedState = false
        lastOutputMeterClippingDetected = false

        realtimeUIStateLock.withLock { state in
            state.eqStagePeakSample = 0
            state.eqStagePeakHoldSample = 0
            state.eqStageClippingDetected = false
            state.outputLimiterEngaged = false
            state.outputPeakSample = 0
            state.outputPeakHoldSample = 0
            state.outputStageClippingDetected = false
            state.clippingDetected = false
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.eqStagePeakSample = 0
            self.eqStagePeakHoldSample = 0
            self.eqStageClippingDetected = false
            self.outputLimiterEngaged = false
            self.outputPeakSample = 0
            self.outputPeakHoldSample = 0
            self.outputStageClippingDetected = false
            self.clippingDetected = false
        }
    }
}

// Ring buffer for passing audio between input and output callbacks
class RingBuffer {
    private var buffer: UnsafeMutablePointer<Float>
    private let capacityFrames: UInt32
    private let channels: UInt32
    private var writeIndex: UInt32 = 0
    private var readIndex: UInt32 = 0
    private var storedFrames: UInt32 = 0
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

    private func channelBase(_ channelIndex: Int) -> Int {
        channelIndex * Int(capacityFrames)
    }

    func store(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        lock.lock()
        defer { lock.unlock() }

        let bufferListPtr = UnsafeMutableAudioBufferListPointer(bufferList)
        let frameCountInt = Int(frameCount)
        let firstChunk = min(frameCount, capacityFrames - writeIndex)
        let firstChunkInt = Int(firstChunk)
        let secondChunkInt = frameCountInt - firstChunkInt

        for (channelIndex, audioBuffer) in bufferListPtr.enumerated() where channelIndex < Int(channels) {
            guard let data = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }

            let base = channelBase(channelIndex)
            let destination = buffer.advanced(by: base)

            memcpy(
                destination.advanced(by: Int(writeIndex)),
                data,
                firstChunkInt * MemoryLayout<Float>.size
            )

            if secondChunkInt > 0 {
                memcpy(
                    destination,
                    data.advanced(by: firstChunkInt),
                    secondChunkInt * MemoryLayout<Float>.size
                )
            }
        }

        writeIndex = (writeIndex + frameCount) % capacityFrames
        let newStoredFrames = min(storedFrames + frameCount, capacityFrames)
        if storedFrames + frameCount > capacityFrames {
            let overflowFrames = (storedFrames + frameCount) - capacityFrames
            readIndex = (readIndex + overflowFrames) % capacityFrames
        }
        storedFrames = newStoredFrames
    }

    func fetch(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }

        let toRead = min(frameCount, storedFrames)

        let bufferListPtr = UnsafeMutableAudioBufferListPointer(bufferList)
        let toReadInt = Int(toRead)
        let firstChunk = min(toRead, capacityFrames - readIndex)
        let firstChunkInt = Int(firstChunk)
        let secondChunkInt = toReadInt - firstChunkInt

        for (channelIndex, audioBuffer) in bufferListPtr.enumerated() where channelIndex < Int(channels) {
            guard let data = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }

            let base = channelBase(channelIndex)
            let source = buffer.advanced(by: base)

            memcpy(
                data,
                source.advanced(by: Int(readIndex)),
                firstChunkInt * MemoryLayout<Float>.size
            )

            if secondChunkInt > 0 {
                memcpy(
                    data.advanced(by: firstChunkInt),
                    source,
                    secondChunkInt * MemoryLayout<Float>.size
                )
            }
        }

        readIndex = (readIndex + toRead) % capacityFrames
        storedFrames -= toRead
        return toRead
    }

    func trimBufferedFrames(maxBufferedFrames: UInt32) {
        lock.lock()
        defer { lock.unlock() }

        guard maxBufferedFrames < storedFrames else { return }
        let framesToDrop = storedFrames - maxBufferedFrames
        readIndex = (readIndex + framesToDrop) % capacityFrames
        storedFrames = maxBufferedFrames
    }
}

final class SpectrumAnalyzer {
    static let defaultBarCount = 192

    private let sampleRate: Float
    private let fftSize: Int
    private let hopSize: Int
    private let barCount: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let minFrequency: Float = 20.0
    private let analysisMaxFrequency: Float

    private var circularBuffer: [Float]
    private var circularWriteIndex = 0
    private var totalSamplesSeen = 0
    private var samplesSinceLastFFT = 0

    private var fftInput: [Float]
    private var window: [Float]
    private var splitReal: [Float]
    private var splitImag: [Float]
    private var magnitudes: [Float]
    private var binToBar: [Int]
    private var barBinContributors: [Int]
    private var barNearestLowerContributor: [Int]
    private var barNearestUpperContributor: [Int]
    private var workingBars: [Float]

    private(set) var currentBars: [Float]

    init(sampleRate: Float, fftSize: Int = 4096, hopSize: Int = 1024, barCount: Int = SpectrumAnalyzer.defaultBarCount) {
        precondition(fftSize > 0 && (fftSize & (fftSize - 1)) == 0, "FFT size must be a power of two")
        precondition(hopSize > 0 && hopSize <= fftSize, "Hop size must be between 1 and fftSize")
        precondition(barCount > 0, "Bar count must be greater than zero")

        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.barCount = barCount
        self.analysisMaxFrequency = min(20_000.0, sampleRate * 0.5)

        let log2Value = Int(log2(Double(fftSize)))
        self.log2n = vDSP_Length(log2Value)

        guard let setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup")
        }
        self.fftSetup = setup

        self.circularBuffer = Array(repeating: 0.0, count: fftSize)
        self.fftInput = Array(repeating: 0.0, count: fftSize)
        self.window = Array(repeating: 0.0, count: fftSize)
        self.splitReal = Array(repeating: 0.0, count: fftSize / 2)
        self.splitImag = Array(repeating: 0.0, count: fftSize / 2)
        self.magnitudes = Array(repeating: 0.0, count: fftSize / 2)
        self.binToBar = Array(repeating: -1, count: fftSize / 2)
        self.barBinContributors = Array(repeating: 0, count: barCount)
        self.barNearestLowerContributor = Array(repeating: -1, count: barCount)
        self.barNearestUpperContributor = Array(repeating: -1, count: barCount)
        self.workingBars = Array(repeating: 0.0, count: barCount)
        self.currentBars = Array(repeating: 0.0, count: barCount)

        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        buildBinToBarMap()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func process(left: UnsafePointer<Float>?, right: UnsafePointer<Float>?, frameCount: Int) -> Bool {
        guard frameCount > 0 else { return false }

        for i in 0..<frameCount {
            let leftSample = left?[i] ?? 0.0
            let rightSample = right?[i] ?? leftSample
            circularBuffer[circularWriteIndex] = 0.5 * (leftSample + rightSample)

            circularWriteIndex += 1
            if circularWriteIndex >= fftSize {
                circularWriteIndex = 0
            }
        }

        totalSamplesSeen += frameCount
        samplesSinceLastFFT += frameCount

        var generatedFrame = false
        while totalSamplesSeen >= fftSize && samplesSinceLastFFT >= hopSize {
            analyzeLatestFrame()
            samplesSinceLastFFT -= hopSize
            generatedFrame = true
        }

        return generatedFrame
    }

    private func buildBinToBarMap() {
        guard analysisMaxFrequency > minFrequency else { return }

        for index in 0..<barBinContributors.count {
            barBinContributors[index] = 0
        }

        let minLog = log10f(minFrequency)
        let maxLog = log10f(analysisMaxFrequency)
        let logRange = max(maxLog - minLog, 0.0001)

        for bin in 1..<binToBar.count {
            let frequency = (Float(bin) * sampleRate) / Float(fftSize)
            guard frequency >= minFrequency && frequency <= analysisMaxFrequency else {
                continue
            }

            let normalized = (log10f(frequency) - minLog) / logRange
            let clamped = max(0.0, min(1.0, normalized))
            let barIndex = min(barCount - 1, Int(clamped * Float(barCount - 1)))
            binToBar[bin] = barIndex
            barBinContributors[barIndex] += 1
        }

        var lowerContributor = -1
        for index in 0..<barCount {
            if barBinContributors[index] > 0 {
                lowerContributor = index
            }
            barNearestLowerContributor[index] = lowerContributor
        }

        var upperContributor = -1
        for index in stride(from: barCount - 1, through: 0, by: -1) {
            if barBinContributors[index] > 0 {
                upperContributor = index
            }
            barNearestUpperContributor[index] = upperContributor
        }
    }

    private func analyzeLatestFrame() {
        var sourceIndex = circularWriteIndex
        for i in 0..<fftSize {
            fftInput[i] = circularBuffer[sourceIndex]
            sourceIndex += 1
            if sourceIndex >= fftSize {
                sourceIndex = 0
            }
        }

        vDSP_vmul(fftInput, 1, window, 1, &fftInput, 1, vDSP_Length(fftSize))

        fftInput.withUnsafeMutableBufferPointer { inputPtr in
            splitReal.withUnsafeMutableBufferPointer { realPtr in
                splitImag.withUnsafeMutableBufferPointer { imagPtr in
                    guard let inputBase = inputPtr.baseAddress,
                          let realBase = realPtr.baseAddress,
                          let imagBase = imagPtr.baseAddress else {
                        return
                    }

                    inputBase.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                        var scale: Float = 1.0 / Float(fftSize)
                        vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, vDSP_Length(fftSize / 2))
                        vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, vDSP_Length(fftSize / 2))
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                    }
                }
            }
        }

        if !magnitudes.isEmpty {
            magnitudes[0] = 0
        }

        for i in 0..<workingBars.count {
            workingBars[i] = 0
        }

        for bin in 1..<magnitudes.count {
            let barIndex = binToBar[bin]
            guard barIndex >= 0 else { continue }

            let magnitude = magnitudes[bin]
            if magnitude > workingBars[barIndex] {
                workingBars[barIndex] = magnitude
            }
        }

        // Many low-frequency log bars have no direct FFT-bin assignment.
        // Fill them from neighboring populated bars to avoid visible gaps.
        for barIndex in 0..<barCount where barBinContributors[barIndex] == 0 {
            let lower = barNearestLowerContributor[barIndex]
            let upper = barNearestUpperContributor[barIndex]

            if lower >= 0 && upper >= 0 {
                if lower == upper {
                    workingBars[barIndex] = workingBars[lower]
                    continue
                }

                let t = Float(barIndex - lower) / Float(upper - lower)
                let lowerDB = 20.0 * log10f(max(workingBars[lower], 1e-12))
                let upperDB = 20.0 * log10f(max(workingBars[upper], 1e-12))
                let interpolatedDB = lowerDB + ((upperDB - lowerDB) * t)
                workingBars[barIndex] = powf(10.0, interpolatedDB / 20.0)
            } else if lower >= 0 {
                workingBars[barIndex] = workingBars[lower]
            } else if upper >= 0 {
                workingBars[barIndex] = workingBars[upper]
            }
        }

        let floorDB: Float = -90.0
        let ceilingDB: Float = 0.0
        let risingSmoothing: Float = 0.55
        let fallingSmoothing: Float = 0.14
        let range = max(ceilingDB - floorDB, 0.0001)

        for i in 0..<barCount {
            let amplitude = max(workingBars[i], 1e-9)
            let db = 20.0 * log10f(amplitude)
            let normalized = max(0.0, min(1.0, (db - floorDB) / range))

            let previous = currentBars[i]
            let smoothing = normalized > previous ? risingSmoothing : fallingSmoothing
            currentBars[i] = previous + ((normalized - previous) * smoothing)
        }
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
