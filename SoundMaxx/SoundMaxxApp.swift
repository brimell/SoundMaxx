import SwiftUI
import AVFoundation
import CoreAudio
import AppKit

@main
struct SoundMaxxApp: App {
    private static let mainWindowID = "main-window"

    @StateObject private var audioEngine: AudioEngine
    @StateObject private var eqModel: EQModel

    init() {
        let engine = AudioEngine()
        let model = EQModel()

        _audioEngine = StateObject(wrappedValue: engine)
        _eqModel = StateObject(wrappedValue: model)

        Self.configureEngineCallbacks(audioEngine: engine, eqModel: model)
        Self.requestMicrophonePermissionAndStart(audioEngine: engine, eqModel: model)
    }

    var body: some Scene {
        Window("SoundMaxx", id: Self.mainWindowID) {
            ContentView()
                .environmentObject(audioEngine)
                .environmentObject(eqModel)
        }
        .defaultSize(width: 840, height: 900)

        MenuBarExtra("SoundMaxx", systemImage: "slider.horizontal.3") {
            AppMenu(mainWindowID: Self.mainWindowID)
        }
        .menuBarExtraStyle(.menu)
    }

    private static func requestMicrophonePermissionAndStart(audioEngine: AudioEngine, eqModel: EQModel) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        print("Microphone access granted")
                        startAudioServiceIfPossible(audioEngine: audioEngine, eqModel: eqModel)
                    } else {
                        print("Microphone access denied")
                    }
                }
            }
        case .denied, .restricted:
            print("Microphone access denied - please enable in System Settings > Privacy > Microphone")
        case .authorized:
            print("Microphone access already authorized")
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
}

private struct AppMenu: View {
    let mainWindowID: String

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open SoundMaxx") {
            openWindow(id: mainWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit SoundMaxx") {
            NSApplication.shared.terminate(nil)
        }
    }
}
