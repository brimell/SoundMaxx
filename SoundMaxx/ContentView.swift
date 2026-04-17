import SwiftUI
import CoreAudio
import UniformTypeIdentifiers

enum ContentViewLayout {
    case compact
    case full
}

struct ContentView: View {
    let layout: ContentViewLayout
    let advancedWindowID: String?

    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var eqModel: EQModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var deviceManager = AudioDeviceManager()
    @StateObject private var presetManager = PresetManager()

    @State private var selectedInputID: AudioDeviceID?
    @State private var showingSavePreset = false
    @State private var showingAutoEQ = false
    @State private var showingEQImportPicker = false
    @State private var showingHelp = false
    @State private var showingEQImportError = false
    @State private var eqImportErrorMessage = ""
    @State private var newPresetName = ""
    @State private var didInitialStartup = false
    @StateObject private var launchAtLogin = LaunchAtLogin()
    private let settingsStore = AppSettingsStore.shared
    private let autoEQManager = AutoEQManager.shared

    private var menuWidth: CGFloat {
        isCompactLayout ? 640 : 800
    }

    private var isCompactLayout: Bool {
        layout == .compact
    }

    init(layout: ContentViewLayout = .full, advancedWindowID: String? = nil) {
        self.layout = layout
        self.advancedWindowID = advancedWindowID
    }

    var body: some View {
        VStack(spacing: isCompactLayout ? 12 : 16) {
            header

            Divider()

            responseGraph

            eqSliders

            preGainControl

            // Volume slider for HDMI/devices without hardware volume
            if audioEngine.outputDeviceNeedsVolumeControl {
                volumeControl
            }

            if isCompactLayout {
                compactOutputControl
            }

            if !isCompactLayout {
                Divider()

                presetControls

                Divider()

                deviceControls

                Divider()
            }

            footer
        }
        .padding(isCompactLayout ? 14 : 18)
        .frame(width: menuWidth)
        .font(.system(size: 14))
        .onAppear {
            setupDeviceChangeCallback()
            eqModel.resolvePresetSelection(using: presetManager.customPresets)
            syncEQToEngine()
            if !didInitialStartup {
                autoSelectDevicesAndStart()
                didInitialStartup = true
            }
        }
        .onReceive(audioEngine.$selectedInputDeviceID) { newDeviceID in
            if selectedInputID != newDeviceID {
                selectedInputID = newDeviceID
            }
        }
        .onChange(of: eqModel.parametricBands) { newValue in
            audioEngine.setBands(newValue)
        }
        .onChange(of: eqModel.isEnabled) { newValue in
            audioEngine.setBypass(!newValue)
        }
        .onChange(of: eqModel.isEQFiltersEnabled) { newValue in
            audioEngine.setEQFiltersEnabled(newValue)
        }
        .onChange(of: eqModel.preGain) { newValue in
            audioEngine.setPreGain(newValue)
        }
        .onChange(of: eqModel.outputGain) { newValue in
            audioEngine.setOutputGain(newValue)
        }
        .onChange(of: eqModel.limiterEnabled) { newValue in
            audioEngine.setLimiterEnabled(newValue)
        }
        .onChange(of: eqModel.limiterCeilingDB) { newValue in
            audioEngine.setLimiterCeilingDB(newValue)
        }
        .onChange(of: eqModel.autoStopClippingEnabled) { newValue in
            audioEngine.setAutoStopClippingEnabled(newValue)
        }
        .onChange(of: eqModel.volume) { newValue in
            audioEngine.setVolume(newValue)
        }
        .onChange(of: presetManager.customPresets) { newPresets in
            eqModel.resolvePresetSelection(using: newPresets)
        }
        .sheet(isPresented: $showingSavePreset) {
            savePresetSheet
        }
        .fileImporter(
            isPresented: $showingEQImportPicker,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false,
            onCompletion: importEQFile
        )
        .alert("Import Failed", isPresented: $showingEQImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(eqImportErrorMessage)
        }
    }

    private var compactOutputControl: some View {
        HStack {
            Text("Output")
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)

            Picker("", selection: selectedOutputBinding) {
                Text("Select...").tag(nil as AudioDeviceID?)
                ForEach(deviceManager.outputDevices) { device in
                    Text(device.name).tag(device.id as AudioDeviceID?)
                }
            }
            .labelsHidden()
            .help("Choose the output device")

            Button {
                cycleToNextOutputDevice()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Switch to next output device (Control+Option+Command+O)")
        }
    }

    private func setupDeviceChangeCallback() {
        audioEngine.onOutputDeviceChanged = { _, uid, name in
            DispatchQueue.main.async {
                eqModel.onDeviceChanged(deviceUID: uid, deviceName: name)
                eqModel.resolvePresetSelection(using: presetManager.customPresets)
                audioEngine.setBands(eqModel.parametricBands)
                audioEngine.setBypass(!eqModel.isEnabled)
                audioEngine.setEQFiltersEnabled(eqModel.isEQFiltersEnabled)
                // Sync volume from profile to engine
                audioEngine.setPreGain(eqModel.preGain)
                audioEngine.setOutputGain(eqModel.outputGain)
                audioEngine.setLimiterEnabled(eqModel.limiterEnabled)
                audioEngine.setLimiterCeilingDB(eqModel.limiterCeilingDB)
                audioEngine.setAutoStopClippingEnabled(eqModel.autoStopClippingEnabled)
                audioEngine.setVolume(eqModel.volume)
            }
        }

        audioEngine.onPreGainAutoAdjusted = { newPreGain in
            DispatchQueue.main.async {
                eqModel.setPreGain(gain: newPreGain)
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
                .font(.title)

            Text("SoundMaxx EQ")
                .font(.title3.weight(.semibold))

            Spacer()

            Button {
                showingHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingHelp) {
                helpView
            }

            HStack(spacing: 8) {
                Text("Audio")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("", isOn: $eqModel.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Enable or bypass all processing (headroom + EQ filters)")

                Text("EQ")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("", isOn: $eqModel.isEQFiltersEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!eqModel.isEnabled)
                    .help("Bypass only EQ filters while keeping headroom active for A/B comparison")
            }
        }
    }

    private var helpView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Help")
                .font(.headline)

            Divider()

            Group {
                helpRow(icon: "slider.vertical.3", title: "EQ Sliders", desc: "Drag up to boost, down to cut (±12dB)")
                helpRow(icon: "arrow.up.and.down.circle", title: "Headroom + Volume", desc: "Headroom protects the EQ stage, Volume is post-EQ loudness")
                helpRow(icon: "arrow.left.arrow.right.square", title: "EQ Switch", desc: "Toggle filters on/off for A/B comparison while keeping headroom")
                helpRow(icon: "waveform.path.ecg", title: "Output Safety", desc: "Separate EQ clipping, limiter activity, and final output status")
                helpRow(icon: "speaker.wave.2", title: "Volume", desc: "Software volume for HDMI outputs")
                helpRow(icon: "square.and.arrow.down", title: "Presets", desc: "Select or save EQ configurations")
                helpRow(icon: "headphones", title: "AutoEQ", desc: "Apply headphone correction curves")
                helpRow(icon: "hifispeaker", title: "Device Profiles", desc: "EQ settings saved per output device")
                helpRow(icon: "keyboard", title: "Output Shortcut", desc: "Control+Option+Command+O switches to next output")
                helpRow(icon: "power", title: "Start/Stop", desc: "Toggle audio processing")
            }

            Divider()

            HStack {
                Text("Tip: Set system output to BlackHole 2ch")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 340)
    }

    private func helpRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(desc)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }

    private static let frequencyTooltips = [
        "Sub-bass: Rumble, sub-woofer content",
        "Bass: Kick drums, bass guitar fundamentals",
        "Low-mid: Bass warmth, body of sound",
        "Mid-bass: Reduce for less muddiness",
        "Midrange: Vocal body, snare drum",
        "Upper-mid: Vocal presence, clarity",
        "Presence: Detail, intelligibility",
        "Brilliance: Attack, consonants, hi-hat",
        "Treble: Airiness, cymbal shimmer",
        "Air: Sparkle, highest harmonics"
    ]

    private var responseCurvePoints: [EQResponsePoint] {
        eqModel.responseCurve(sampleRate: Float(audioEngine.processingSampleRate))
    }

    private var responseGraph: some View {
        EQResponseGraphView(
            points: responseCurvePoints,
            isEnabled: eqModel.isEnabled && eqModel.isEQFiltersEnabled,
            sampleRate: audioEngine.processingSampleRate
        )
        .frame(height: isCompactLayout ? 120 : 154)
        .help("Actual resulting EQ response across the frequency spectrum")
    }

    private var eqSliders: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(eqModel.parametricBands.count) band\(eqModel.parametricBands.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    eqModel.removeLastBand()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(eqModel.parametricBands.count <= EQModel.minimumBandCount)
                .help("Remove last band")

                Button {
                    eqModel.addBand()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a new band")
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(eqModel.parametricBands.indices, id: \.self) { index in
                        VStack(spacing: 4) {
                            EQSliderView(
                                value: Binding(
                                    get: { eqModel.parametricBands[index].gain },
                                    set: { eqModel.setBandGain(index: index, gain: $0) }
                                ),
                                label: "",
                                tooltip: bandTooltip(index)
                            )

                            if !isCompactLayout {
                                inlineBandControls(index)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .opacity(eqModel.isEnabled ? (eqModel.isEQFiltersEnabled ? 1.0 : 0.7) : 0.5)
            .disabled(!eqModel.isEnabled)
        }
    }

    private func inlineBandControls(_ index: Int) -> some View {
        let band = eqModel.parametricBands[index]

        return VStack(spacing: 4) {
            Menu {
                ForEach(EQFilterType.allCases) { type in
                    Button(type.displayName) {
                        eqModel.setBandType(index: index, type: type)
                    }
                }
            } label: {
                Text(shortFilterTypeName(band.type))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(Color.gray.opacity(0.16))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)

            TextField(
                "Freq",
                value: Binding(
                    get: { Double(eqModel.parametricBands[index].frequency) },
                    set: { eqModel.setBandFrequency(index: index, frequency: Float($0)) }
                ),
                format: .number.precision(.fractionLength(0))
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .multilineTextAlignment(.center)
            .help("Frequency (Hz)")

            TextField(
                "Q",
                value: Binding(
                    get: { Double(eqModel.parametricBands[index].q) },
                    set: { eqModel.setBandQ(index: index, q: Float($0)) }
                ),
                format: .number.precision(.fractionLength(2))
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .multilineTextAlignment(.center)
            .help("Q factor")

            Button {
                eqModel.removeBand(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            .disabled(eqModel.parametricBands.count <= EQModel.minimumBandCount)
            .help("Remove this band")
        }
        .frame(width: 60)
    }

    private var volumeControl: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.secondary)
                    .font(.caption)

                Slider(value: $eqModel.volume, in: 0...1)
                    .help("Software volume control - macOS disables hardware volume for HDMI outputs")

                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.secondary)
                    .font(.caption)

                Text("\(Int(eqModel.volume * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 35, alignment: .trailing)
            }

            Text("HDMI Volume (no hardware control)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var preGainControl: some View {
        Group {
            if isCompactLayout {
                compactPreGainControl
            } else {
                advancedPreGainControl
            }
        }
        .opacity(eqModel.isEnabled ? 1.0 : 0.5)
    }

    private var compactPreGainControl: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Volume")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 55, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(eqModel.outputGain) },
                        set: { eqModel.setOutputGain(gain: Float($0)) }
                    ),
                    in: Double(EQModel.outputGainRange.lowerBound)...Double(EQModel.outputGainRange.upperBound),
                    step: 0.1
                )

                Text(String(format: "%+.1f dB", eqModel.outputGain))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }

            Text("Headroom is available in Advanced Options")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(audioEngine.eqStageClippingDetected ? Color.red : Color.secondary.opacity(0.28))
                    .frame(width: 8, height: 8)

                Text(audioEngine.eqStageClippingDetected ? "EQ stage clipping" : "EQ stage clean")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(audioEngine.eqStageClippingDetected ? .red : .secondary)

                Spacer()

                Text(eqPeakLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .help("Headroom + EQ stage peak/clipping monitor.")

            HStack(spacing: 8) {
                Circle()
                    .fill(outputStatusIndicatorColor)
                    .frame(width: 8, height: 8)

                Text(outputStatusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(outputStatusColor)

                Spacer()

                Text(outputPeakLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .help("Post-EQ limiter activity and final output clipping monitor.")
        }
    }

    private var advancedPreGainControl: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Headroom")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 55, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(eqModel.preGain) },
                        set: { eqModel.setPreGain(gain: Float($0)) }
                    ),
                    in: Double(EQModel.preGainRange.lowerBound)...Double(EQModel.preGainRange.upperBound),
                    step: 0.1
                )
                .help("Headroom control before EQ filters. Keep this negative when EQ has positive boosts.")

                Text(String(format: "%+.1f dB", eqModel.preGain))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }

            HStack {
                Text("Volume")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 55, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(eqModel.outputGain) },
                        set: { eqModel.setOutputGain(gain: Float($0)) }
                    ),
                    in: Double(EQModel.outputGainRange.lowerBound)...Double(EQModel.outputGainRange.upperBound),
                    step: 0.1
                )
                .help("User loudness control after EQ and before limiter.")

                Text(String(format: "%+.1f dB", eqModel.outputGain))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }

            Text("Signal chain: Input -> Headroom -> EQ -> Volume -> Limiter -> Output")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Toggle(
                    "auto-stop EQ clipping",
                    isOn: Binding(
                        get: { eqModel.autoStopClippingEnabled },
                        set: { eqModel.autoStopClippingEnabled = $0 }
                    )
                )
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Automatically lowers headroom when the EQ stage clips.")

                Toggle(
                    "Limiter",
                    isOn: Binding(
                        get: { eqModel.limiterEnabled },
                        set: { eqModel.setLimiterEnabled($0) }
                    )
                )
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Final safety stage to avoid output overs.")

                Spacer()
            }

            if eqModel.limiterEnabled {
                HStack {
                    Text("Ceiling")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 55, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { Double(eqModel.limiterCeilingDB) },
                            set: { eqModel.setLimiterCeilingDB(Float($0)) }
                        ),
                        in: -6.0 ... -0.1,
                        step: 0.1
                    )
                    .help("Limiter ceiling in dBFS.")

                    Text(String(format: "%.1f dBFS", eqModel.limiterCeilingDB))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 62, alignment: .trailing)
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(audioEngine.eqStageClippingDetected ? Color.red : Color.secondary.opacity(0.28))
                    .frame(width: 8, height: 8)

                Text(audioEngine.eqStageClippingDetected ? "EQ stage clipping" : "EQ stage clean")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(audioEngine.eqStageClippingDetected ? .red : .secondary)

                Spacer()

                Text(eqPeakLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .help("Headroom + EQ stage peak/clipping monitor.")

            HStack(spacing: 8) {
                Circle()
                    .fill(outputStatusIndicatorColor)
                    .frame(width: 8, height: 8)

                Text(outputStatusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(outputStatusColor)

                Spacer()

                Text(outputPeakLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .help("Post-EQ limiter activity and final output clipping monitor.")
        }
    }

    private var eqPeakLabel: String {
        peakLabel(from: audioEngine.eqStagePeakSample, prefix: "EQ")
    }

    private var outputPeakLabel: String {
        peakLabel(from: audioEngine.outputPeakSample, prefix: "Out")
    }

    private var outputStatusText: String {
        if audioEngine.outputStageClippingDetected {
            return "Output clipping"
        }
        if audioEngine.outputLimiterEngaged {
            return "Output limited"
        }
        return "Output clean"
    }

    private var outputStatusColor: Color {
        if audioEngine.outputStageClippingDetected {
            return .red
        }
        if audioEngine.outputLimiterEngaged {
            return .orange
        }
        return .secondary
    }

    private var outputStatusIndicatorColor: Color {
        if audioEngine.outputStageClippingDetected {
            return .red
        }
        if audioEngine.outputLimiterEngaged {
            return .orange
        }
        return Color.secondary.opacity(0.28)
    }

    private func peakLabel(from peak: Float, prefix: String) -> String {
        guard peak > 0 else { return "\(prefix) -inf dBFS" }

        let dBFS = 20.0 * log10(Double(peak))
        if dBFS >= 0 {
            return String(format: "\(prefix) +%.1f dBFS", dBFS)
        }
        return String(format: "\(prefix) %.1f dBFS", dBFS)
    }

    private var presetControls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Preset")
                    .foregroundColor(.secondary)

                Spacer()

                Menu {
                    // Built-in presets
                    Section("Built-in") {
                        ForEach(BuiltInPreset.allCases) { preset in
                            Button(preset.rawValue) {
                                eqModel.applyBuiltInPreset(preset)
                            }
                        }
                    }

                    // Custom presets
                    if !presetManager.customPresets.isEmpty {
                        Section("Custom") {
                            ForEach(presetManager.customPresets) { preset in
                                Button(preset.name) {
                                    eqModel.applyCustomPreset(preset)
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(currentPresetName)
                            .frame(width: 120, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(6)
                }
                .help("Select a preset EQ curve")

                Button {
                    newPresetName = ""
                    showingSavePreset = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Save current EQ as a custom preset")

                Button {
                    showingAutoEQ = true
                } label: {
                    Image(systemName: "headphones")
                }
                .buttonStyle(.borderless)
                .help("Apply AutoEQ headphone correction")
                .popover(isPresented: $showingAutoEQ) {
                    AutoEQView()
                        .environmentObject(eqModel)
                }

                Button {
                    showingEQImportPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Import an AutoEQ ParametricEQ.txt file")

                if let customPreset = eqModel.selectedCustomPreset {
                    Button {
                        presetManager.deletePreset(customPreset)
                        eqModel.applyBuiltInPreset(.flat)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                    .help("Delete this preset")
                }
            }
        }
    }

    private var currentPresetName: String {
        if let preset = eqModel.selectedBuiltInPreset {
            return preset.rawValue
        } else if let preset = eqModel.selectedCustomPreset {
            return preset.name
        } else {
            return "Custom"
        }
    }

    private var selectedOutputBinding: Binding<AudioDeviceID?> {
        Binding(
            get: { audioEngine.selectedOutputDeviceID },
            set: { newDevice in
                if let deviceID = newDevice {
                    audioEngine.setOutputDevice(deviceID)
                }
                persistSelectedDevices()
            }
        )
    }

    private var deviceControls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Input")
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)

                Picker("", selection: $selectedInputID) {
                    Text("Select...").tag(nil as AudioDeviceID?)
                    ForEach(deviceManager.inputDevices) { device in
                        Text(device.name).tag(device.id as AudioDeviceID?)
                    }
                }
                .labelsHidden()
                .help("Select BlackHole 2ch to capture system audio")
                .onChange(of: selectedInputID) { newDevice in
                    if let deviceID = newDevice {
                        audioEngine.setInputDevice(deviceID)
                    }
                    persistSelectedDevices()
                }
            }

            HStack {
                Text("Output")
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)

                Picker("", selection: selectedOutputBinding) {
                    Text("Select...").tag(nil as AudioDeviceID?)
                    ForEach(deviceManager.outputDevices) { device in
                        Text(device.name).tag(device.id as AudioDeviceID?)
                    }
                }
                .labelsHidden()
                .help("Select your speakers or headphones")

                Button {
                    cycleToNextOutputDevice()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Switch to next output device (Control+Option+Command+O)")
            }

            // Device profile controls
            if eqModel.currentDeviceName != nil {
                deviceProfileControls
            }

        }
    }

    private var deviceProfileControls: some View {
        HStack {
            if eqModel.hasDeviceProfile {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("Profile saved for \(eqModel.currentDeviceName ?? "device")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    eqModel.deleteCurrentDeviceProfile()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .help("Delete device profile")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "circle.dashed")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("No profile for \(eqModel.currentDeviceName ?? "device")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    eqModel.saveCurrentAsDeviceProfile()
                } label: {
                    Text("Save Profile")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Save EQ settings for this device")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if isCompactLayout {
                    compactFooter
                } else {
                    fullFooter
                }
            }

            if let error = audioEngine.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fullFooter: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("Launch at Login", isOn: $launchAtLogin.isEnabled)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .help("Automatically start SoundMaxx when you log in")

                Spacer()
            }

            HStack {
                statusIndicator

                Spacer()

                Button("Reset") {
                    eqModel.reset()
                }
                .help("Reset all EQ bands to 0dB (flat)")

                Button(audioEngine.isRunning ? "Stop" : "Start") {
                    if audioEngine.isRunning {
                        audioEngine.stop()
                    } else {
                        audioEngine.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .help(audioEngine.isRunning ? "Stop audio processing" : "Start audio processing")

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .help("Quit SoundMaxx")
            }
        }
    }

    private var compactFooter: some View {
        VStack(spacing: 8) {
            HStack {
                statusIndicator

                Spacer()

                Button("Reset") {
                    eqModel.reset()
                }

                Button(audioEngine.isRunning ? "Stop" : "Start") {
                    if audioEngine.isRunning {
                        audioEngine.stop()
                    } else {
                        audioEngine.start()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            HStack {
                Button("Advanced Options") {
                    openAdvancedWindow()
                }
                .disabled(advancedWindowID == nil)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(audioEngine.isRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            Text(audioEngine.isRunning ? "Running" : "Stopped")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var savePresetSheet: some View {
        VStack(spacing: 16) {
            Text("Save Preset")
                .font(.headline)

            TextField("Preset Name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            HStack {
                Button("Cancel") {
                    showingSavePreset = false
                }

                Button("Save") {
                    if !newPresetName.isEmpty {
                        presetManager.savePreset(
                            name: newPresetName,
                            bands: eqModel.parametricBands,
                            preGain: eqModel.preGain,
                            outputGain: eqModel.outputGain,
                            limiterEnabled: eqModel.limiterEnabled,
                            limiterCeilingDB: eqModel.limiterCeilingDB
                        )
                        showingSavePreset = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPresetName.isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private func syncEQToEngine() {
        audioEngine.setBands(eqModel.parametricBands)
        audioEngine.setBypass(!eqModel.isEnabled)
        audioEngine.setEQFiltersEnabled(eqModel.isEQFiltersEnabled)
        audioEngine.setPreGain(eqModel.preGain)
        audioEngine.setOutputGain(eqModel.outputGain)
        audioEngine.setLimiterEnabled(eqModel.limiterEnabled)
        audioEngine.setLimiterCeilingDB(eqModel.limiterCeilingDB)
        audioEngine.setAutoStopClippingEnabled(eqModel.autoStopClippingEnabled)
        audioEngine.setVolume(eqModel.volume)
    }

    private func bandFrequencyLabel(_ index: Int) -> String {
        guard eqModel.parametricBands.indices.contains(index) else { return "-" }
        let frequency = eqModel.parametricBands[index].frequency
        if frequency >= 1000 {
            return String(format: "%.1fK", frequency / 1000.0)
        }
        return String(format: "%.0f", frequency)
    }

    private func bandTooltip(_ index: Int) -> String {
        guard eqModel.parametricBands.indices.contains(index) else { return "Adjust parametric EQ band" }
        let band = eqModel.parametricBands[index]
        let frequencyText = String(format: "%.0f", band.frequency)
        let qText = String(format: "%.2f", band.q)
        return "\(band.type.displayName): \(frequencyText)Hz, Q \(qText), Gain \(Int(band.gain))dB"
    }

    private func shortFilterTypeName(_ type: EQFilterType) -> String {
        switch type {
        case .peak:
            return "Peak"
        case .lowShelf:
            return "LS"
        case .highShelf:
            return "HS"
        case .lowPass:
            return "LP"
        case .highPass:
            return "HP"
        case .notch:
            return "Notch"
        case .bandPass:
            return "BP"
        }
    }

    private func autoSelectDevicesAndStart() {
        restoreSavedDeviceSelections()

        if selectedInputID == nil, let blackhole = deviceManager.findBlackHole() {
            selectedInputID = blackhole.id
            audioEngine.setInputDevice(blackhole.id)
        }

        if !audioEngine.isRunning,
           audioEngine.selectedInputDeviceID != nil,
           audioEngine.selectedOutputDeviceID != nil {
            audioEngine.start()
        }
    }

    private func openAdvancedWindow() {
        guard let windowID = advancedWindowID else { return }

        openWindow(id: windowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreSavedDeviceSelections() {
        guard let settings = settingsStore.load() else { return }

        if selectedInputID == nil, let savedInputID = settings.selectedInputDeviceID {
            let inputID = AudioDeviceID(savedInputID)
            if deviceManager.inputDevices.contains(where: { $0.id == inputID }) {
                selectedInputID = inputID
                audioEngine.setInputDevice(inputID)
            }
        }

        if audioEngine.selectedOutputDeviceID == nil, let savedOutputID = settings.selectedOutputDeviceID {
            let outputID = AudioDeviceID(savedOutputID)
            if deviceManager.outputDevices.contains(where: { $0.id == outputID }) {
                audioEngine.setOutputDevice(outputID)
            }
        }
    }

    private func persistSelectedDevices() {
        settingsStore.update { settings in
            settings.selectedInputDeviceID = selectedInputID.map { Int32($0) }
            settings.selectedOutputDeviceID = audioEngine.selectedOutputDeviceID.map { Int32($0) }
        }
    }

    private func cycleToNextOutputDevice() {
        let currentDeviceID = audioEngine.selectedOutputDeviceID
        guard let nextDevice = deviceManager.nextOutputDevice(after: currentDeviceID) else { return }

        audioEngine.setOutputDevice(nextDevice.id)
        persistSelectedDevices()
    }

    private func importEQFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }

            do {
                let fileContents = try readTextFile(fileURL)
                let curve = try autoEQManager.parseImportedEQ(content: fileContents)

                if let importedBands = curve.parametricBands, !importedBands.isEmpty {
                    eqModel.parametricBands = importedBands
                } else {
                    eqModel.parametricBands = EQBand.tenBand(withGains: curve.bands)
                }

                eqModel.setPreGain(gain: curve.preGain)
                eqModel.clearPresetSelection()
            } catch {
                eqImportErrorMessage = "Could not parse this EQ file. Use AutoEQ ParametricEQ.txt (or GraphicEQ.txt) format."
                showingEQImportError = true
            }

        case .failure(let error):
            eqImportErrorMessage = error.localizedDescription
            showingEQImportError = true
        }
    }

    private func readTextFile(_ url: URL) throws -> String {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)

        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        if let text = String(data: data, encoding: .ascii) {
            return text
        }

        if let text = String(data: data, encoding: .isoLatin1) {
            return text
        }

        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}

private struct EQResponseGraphView: View {
    let points: [EQResponsePoint]
    let isEnabled: Bool
    let sampleRate: Double

    private let frequencyTicks: [Float] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    private let labeledFrequencyTicks: [Float] = [20, 100, 1000, 10000, 20000]
    private let gainTicks: [Float] = [-24, -12, 0, 12, 24]
    private let gainRange: ClosedRange<Float> = -24...24

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Response")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Spacer()

                Text(String(format: "%.1f kHz", sampleRate / 1000.0))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height

                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.08))

                    ForEach(gainTicks, id: \.self) { tick in
                        Path { path in
                            let y = yPosition(for: tick, in: height)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: width, y: y))
                        }
                        .stroke(
                            tick == 0 ? Color.secondary.opacity(0.45) : Color.secondary.opacity(0.18),
                            lineWidth: tick == 0 ? 1.2 : 0.8
                        )
                    }

                    ForEach(frequencyTicks, id: \.self) { tick in
                        Path { path in
                            let x = xPosition(for: tick, in: width)
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: height))
                        }
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 0.8)
                    }

                    if points.count > 1 {
                        responseFillPath(in: CGSize(width: width, height: height))
                            .fill(
                                LinearGradient(
                                    colors: [Color.orange.opacity(isEnabled ? 0.18 : 0.08), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        responsePath(in: CGSize(width: width, height: height))
                            .stroke(
                                isEnabled ? Color.orange : Color.secondary,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                            )
                    }

                    ForEach(labeledFrequencyTicks, id: \.self) { tick in
                        Text(formatFrequency(tick))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .position(
                                x: xPosition(for: tick, in: width),
                                y: height - 8
                            )
                    }

                    ForEach(gainTicks, id: \.self) { tick in
                        Text(formatGain(tick))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .position(
                                x: 16,
                                y: yPosition(for: tick, in: height)
                            )
                    }
                }
            }
        }
    }

    private func responsePath(in size: CGSize) -> Path {
        var path = Path()
        guard let first = points.first else { return path }

        path.move(
            to: CGPoint(
                x: xPosition(for: first.frequency, in: size.width),
                y: yPosition(for: first.gainDB, in: size.height)
            )
        )

        for point in points.dropFirst() {
            path.addLine(
                to: CGPoint(
                    x: xPosition(for: point.frequency, in: size.width),
                    y: yPosition(for: point.gainDB, in: size.height)
                )
            )
        }

        return path
    }

    private func responseFillPath(in size: CGSize) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }

        let baselineY = yPosition(for: 0, in: size.height)

        path.move(to: CGPoint(x: xPosition(for: first.frequency, in: size.width), y: baselineY))

        for point in points {
            path.addLine(
                to: CGPoint(
                    x: xPosition(for: point.frequency, in: size.width),
                    y: yPosition(for: point.gainDB, in: size.height)
                )
            )
        }

        path.addLine(to: CGPoint(x: xPosition(for: last.frequency, in: size.width), y: baselineY))
        path.closeSubpath()
        return path
    }

    private func xPosition(for frequency: Float, in width: CGFloat) -> CGFloat {
        let clamped = max(EQModel.responseMinFrequency, min(EQModel.responseMaxFrequency, frequency))
        let minLog = log10f(EQModel.responseMinFrequency)
        let maxLog = log10f(EQModel.responseMaxFrequency)
        let valueLog = log10f(clamped)
        let normalized = (valueLog - minLog) / max(maxLog - minLog, 0.0001)
        return CGFloat(normalized) * width
    }

    private func yPosition(for gainDB: Float, in height: CGFloat) -> CGFloat {
        let clamped = max(gainRange.lowerBound, min(gainRange.upperBound, gainDB))
        let normalized = (clamped - gainRange.lowerBound) / (gainRange.upperBound - gainRange.lowerBound)
        return height - (CGFloat(normalized) * height)
    }

    private func formatFrequency(_ frequency: Float) -> String {
        if frequency >= 1000 {
            return "\(Int(frequency / 1000.0))k"
        }
        return "\(Int(frequency))"
    }

    private func formatGain(_ gain: Float) -> String {
        if gain > 0 {
            return "+\(Int(gain))"
        }
        return "\(Int(gain))"
    }
}

#Preview {
    ContentView()
        .environmentObject(AudioEngine())
        .environmentObject(EQModel())
}
