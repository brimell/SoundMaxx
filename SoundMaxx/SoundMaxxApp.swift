import SwiftUI
import AVFoundation
import CoreAudio
import Carbon.HIToolbox

@main
struct SoundMaxxApp: App {
    private static let mainWindowID = "main-window"

    @StateObject private var audioEngine: AudioEngine
    @StateObject private var eqModel: EQModel
    private let outputSwitchShortcutManager: OutputSwitchShortcutManager

    init() {
        let engine = AudioEngine()
        let model = EQModel()
        let shortcutManager = OutputSwitchShortcutManager {
            Self.cycleToNextOutputDevice(audioEngine: engine)
        }

        _audioEngine = StateObject(wrappedValue: engine)
        _eqModel = StateObject(wrappedValue: model)
        outputSwitchShortcutManager = shortcutManager

        Self.configureEngineCallbacks(audioEngine: engine, eqModel: model)
        Self.requestMicrophonePermissionAndStart(audioEngine: engine, eqModel: model)
    }

    var body: some Scene {
        MenuBarExtra("SoundMaxx", systemImage: "slider.horizontal.3") {
            ContentView(layout: .compact, advancedWindowID: Self.mainWindowID)
                .environmentObject(audioEngine)
                .environmentObject(eqModel)
        }
        .menuBarExtraStyle(.window)

        Window("SoundMaxx Advanced", id: Self.mainWindowID) {
            ContentView(layout: .full)
                .environmentObject(audioEngine)
                .environmentObject(eqModel)
        }
        .defaultSize(width: 900, height: 920)
    }

    private static func requestMicrophonePermissionAndStart(audioEngine: AudioEngine, eqModel: EQModel) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        print("Microphone access granted")
                        audioEngine.errorMessage = nil
                        startAudioServiceIfPossible(audioEngine: audioEngine, eqModel: eqModel)
                    } else {
                        print("Microphone access denied")
                        audioEngine.errorMessage = AudioEngine.microphoneAccessDeniedMessage
                    }
                }
            }
        case .denied, .restricted:
            print("Microphone access denied - please enable in System Settings > Privacy > Microphone")
            audioEngine.errorMessage = AudioEngine.microphoneAccessDeniedMessage
        case .authorized:
            print("Microphone access already authorized")
            audioEngine.errorMessage = nil
            startAudioServiceIfPossible(audioEngine: audioEngine, eqModel: eqModel)
        @unknown default:
            break
        }
    }

    private static func startAudioServiceIfPossible(audioEngine: AudioEngine, eqModel: EQModel) {
        let settingsStore = AppSettingsStore.shared
        let deviceManager = AudioDeviceManager()

        applyEQModelToAudioEngine(audioEngine: audioEngine, eqModel: eqModel)

        if let settings = settingsStore.load() {
            audioEngine.updateLatencySettings(
                ioBufferFrames: UInt32(max(16, settings.preferredIOBufferFrames)),
                ringCapacityMultiplier: UInt32(max(1, settings.ringBufferCapacityMultiplier)),
                latencyTargetMultiplier: UInt32(max(1, settings.latencyTargetMultiplier))
            )

            if let savedInputID = settings.selectedInputDeviceID {
                let inputID = AudioDeviceID(savedInputID)
                if deviceManager.inputDevices.contains(where: { $0.id == inputID }) {
                    audioEngine.setInputDevice(inputID)
                }
            }

            if let savedOutputID = settings.selectedOutputDeviceID {
                let outputID = AudioDeviceID(savedOutputID)
                if deviceManager.outputDevices.contains(where: { $0.id == outputID }) {
                    audioEngine.setOutputDevice(outputID)
                }
            }
        }

        if audioEngine.selectedInputDeviceID == nil,
           let blackHole = deviceManager.findBlackHole() {
            audioEngine.setInputDevice(blackHole.id)
        }

        if audioEngine.selectedOutputDeviceID == nil,
           let defaultOutput = deviceManager.getDefaultOutputDevice() {
            audioEngine.setOutputDevice(defaultOutput)
        }

        settingsStore.update { settings in
            settings.selectedInputDeviceID = audioEngine.selectedInputDeviceID.map { Int32($0) }
            settings.selectedOutputDeviceID = audioEngine.selectedOutputDeviceID.map { Int32($0) }
        }

        applyEQModelToAudioEngine(audioEngine: audioEngine, eqModel: eqModel)

        if !audioEngine.isRunning,
           audioEngine.selectedInputDeviceID != nil,
           audioEngine.selectedOutputDeviceID != nil {
            audioEngine.start()
        }
    }

    private static func configureEngineCallbacks(audioEngine: AudioEngine, eqModel: EQModel) {
        audioEngine.onOutputDeviceChanged = { _, uid, name in
            let apply = {
                eqModel.onDeviceChanged(deviceUID: uid, deviceName: name)
                applyEQModelToAudioEngine(audioEngine: audioEngine, eqModel: eqModel)
            }

            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }

        audioEngine.onPreGainAutoAdjusted = { newPreGain in
            if Thread.isMainThread {
                eqModel.setPreGain(gain: newPreGain)
            } else {
                DispatchQueue.main.async {
                    eqModel.setPreGain(gain: newPreGain)
                }
            }
        }
    }

    private static func applyEQModelToAudioEngine(audioEngine: AudioEngine, eqModel: EQModel) {
        audioEngine.setBands(eqModel.parametricBands)
        audioEngine.setBypass(!eqModel.isEnabled)
        audioEngine.setPreGain(eqModel.preGain)
        audioEngine.setOutputGain(eqModel.outputGain)
        audioEngine.setLimiterEnabled(eqModel.limiterEnabled)
        audioEngine.setLimiterCeilingDB(eqModel.limiterCeilingDB)
        audioEngine.setAutoStopClippingEnabled(eqModel.autoStopClippingEnabled)
        audioEngine.setVolume(eqModel.volume)
    }

    private static func cycleToNextOutputDevice(audioEngine: AudioEngine) {
        let deviceManager = AudioDeviceManager()
        let preferredUIDs = AppSettingsStore.shared.load()?.shortcutOutputDeviceUIDs
        guard let nextDevice = deviceManager.nextOutputDevice(
            after: audioEngine.selectedOutputDeviceID,
            preferredUIDs: preferredUIDs
        ) else {
            return
        }

        DispatchQueue.main.async {
            audioEngine.setOutputDevice(nextDevice.id)
            AppSettingsStore.shared.update { settings in
                settings.selectedOutputDeviceID = Int32(nextDevice.id)
            }
        }
    }
}

private final class OutputSwitchShortcutManager {
    private static let hotKeyCode = UInt32(kVK_ANSI_O)
    private static let hotKeyModifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let hotKeyIdentifier = EventHotKeyID(
        signature: fourCharCode("SMAX"),
        id: 1
    )

    private let onShortcutPressed: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(onShortcutPressed: @escaping () -> Void) {
        self.onShortcutPressed = onShortcutPressed
        registerHotKey()
    }

    deinit {
        unregisterHotKey()
    }

    private func registerHotKey() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            print("Failed to install output-switch hotkey handler (status: \(installStatus))")
            return
        }

        let hotKeyID = Self.hotKeyIdentifier
        let registerStatus = RegisterEventHotKey(
            Self.hotKeyCode,
            Self.hotKeyModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            print("Failed to register output-switch hotkey (status: \(registerStatus))")
        }
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private static let hotKeyHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else {
            return noErr
        }

        let manager = Unmanaged<OutputSwitchShortcutManager>.fromOpaque(userData).takeUnretainedValue()

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, hotKeyID.signature == hotKeyIdentifier.signature, hotKeyID.id == hotKeyIdentifier.id else {
            return noErr
        }

        DispatchQueue.main.async {
            manager.onShortcutPressed()
        }

        return noErr
    }
}

private func fourCharCode(_ text: String) -> OSType {
    precondition(text.utf8.count == 4)
    return text.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}
