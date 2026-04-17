import SwiftUI
import Combine

class EQModel: ObservableObject {
    @Published var parametricBands: [EQBand] = EQBand.defaultTenBand
    @Published var isEnabled: Bool = true
    @Published var isEQFiltersEnabled: Bool = true
    @Published var preGain: Float = 0.0
    @Published var outputGain: Float = 0.0
    @Published var limiterEnabled: Bool = true
    @Published var limiterCeilingDB: Float = -1.0
    @Published var autoStopClippingEnabled: Bool = false
    @Published var volume: Float = 1.0
    @Published var selectedBuiltInPreset: BuiltInPreset? = .flat
    @Published var selectedCustomPreset: CustomPreset? = nil

    // Current device profile tracking
    @Published var currentDeviceUID: String?
    @Published var currentDeviceName: String?
    @Published var hasDeviceProfile: Bool = false
    @Published var autoSaveEnabled: Bool = true

    static let frequencyLabels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    var legacyGains: [Float] {
        parametricBands.map { $0.gain }
    }

    private var cancellables = Set<AnyCancellable>()
    private let profileManager = DeviceProfileManager.shared
    private let settingsStore = AppSettingsStore.shared
    private var isLoadingProfile = false
    private let legacyParametricBandsKey = "eq_parametric_bands"
    private let legacyPreGainKey = "eq_pre_gain"
    private let legacyBandsKey = "eq_bands"
    private let legacyEnabledKey = "eq_enabled"
    private let legacyBuiltInPresetKey = "eq_builtin_preset"
    private let legacyAutoStopClippingKey = "eq_auto_stop_clipping"

    init() {
        loadSettings()

        $parametricBands
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveSettings()
                self?.autoSaveToDeviceProfile()
            }
            .store(in: &cancellables)

        $isEnabled
            .sink { [weak self] _ in
                self?.saveSettings()
                self?.autoSaveToDeviceProfile()
            }
            .store(in: &cancellables)

        $isEQFiltersEnabled
            .sink { [weak self] _ in
                self?.saveSettings()
                self?.autoSaveToDeviceProfile()
            }
            .store(in: &cancellables)

        $preGain
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveSettings()
                self?.autoSaveToDeviceProfile()
            }
            .store(in: &cancellables)

        $outputGain
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveSettings()
                self?.autoSaveToDeviceProfile()
            }
            .store(in: &cancellables)

        $limiterEnabled
            .sink { [weak self] _ in
                self?.saveSettings()
                self?.autoSaveToDeviceProfile()
            }
            .store(in: &cancellables)

        $limiterCeilingDB
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveSettings()
                self?.autoSaveToDeviceProfile()
            }
            .store(in: &cancellables)

        $autoStopClippingEnabled
            .sink { [weak self] _ in
                self?.saveSettings()
                self?.autoSaveToDeviceProfile()
            }
            .store(in: &cancellables)

        $volume
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveSettings()
                self?.autoSaveToDeviceProfile()
            }
            .store(in: &cancellables)
    }

    // MARK: - Device Profile Management

    func onDeviceChanged(deviceUID: String, deviceName: String) {
        currentDeviceUID = deviceUID
        currentDeviceName = deviceName

        // Load profile for this device if it exists
        if let profile = profileManager.profile(for: deviceUID) {
            loadFromProfile(profile)
            hasDeviceProfile = true
        } else {
            hasDeviceProfile = false
        }
    }

    func saveCurrentAsDeviceProfile() {
        guard let uid = currentDeviceUID, let name = currentDeviceName else { return }

        let bandsAsDouble = legacyGains.map { Double($0) }
        profileManager.saveCurrentSettings(
            for: uid,
            deviceName: name,
            eqBands: bandsAsDouble,
            parametricBands: parametricBands,
            preGain: preGain,
            outputGain: outputGain,
            limiterEnabled: limiterEnabled,
            limiterCeilingDB: limiterCeilingDB,
            autoStopClippingEnabled: autoStopClippingEnabled,
            volume: volume,
            isEQEnabled: isEnabled,
            isEQFiltersEnabled: isEQFiltersEnabled
        )
        hasDeviceProfile = true
    }

    func deleteCurrentDeviceProfile() {
        guard let uid = currentDeviceUID else { return }
        profileManager.deleteProfile(for: uid)
        hasDeviceProfile = false
    }

    private func loadFromProfile(_ profile: DeviceProfile) {
        isLoadingProfile = true
        parametricBands = profile.effectiveBands
        preGain = profile.preGain
        outputGain = profile.outputGain
        limiterEnabled = profile.limiterEnabled
        limiterCeilingDB = profile.limiterCeilingDB
        autoStopClippingEnabled = profile.autoStopClippingEnabled
        volume = profile.volume
        isEnabled = profile.isEQEnabled
        isEQFiltersEnabled = profile.isEQFiltersEnabled
        clearPresetSelection()
        isLoadingProfile = false
    }

    private func autoSaveToDeviceProfile() {
        guard autoSaveEnabled,
              !isLoadingProfile,
              hasDeviceProfile,
              let uid = currentDeviceUID,
              let name = currentDeviceName else { return }

        let bandsAsDouble = legacyGains.map { Double($0) }
        profileManager.saveCurrentSettings(
            for: uid,
            deviceName: name,
            eqBands: bandsAsDouble,
            parametricBands: parametricBands,
            preGain: preGain,
            outputGain: outputGain,
            limiterEnabled: limiterEnabled,
            limiterCeilingDB: limiterCeilingDB,
            autoStopClippingEnabled: autoStopClippingEnabled,
            volume: volume,
            isEQEnabled: isEnabled,
            isEQFiltersEnabled: isEQFiltersEnabled
        )
    }

    func applyBuiltInPreset(_ preset: BuiltInPreset) {
        selectedBuiltInPreset = preset
        selectedCustomPreset = nil
        parametricBands = preset.bands
        preGain = 0.0
        outputGain = 0.0
    }

    func applyCustomPreset(_ preset: CustomPreset) {
        selectedCustomPreset = preset
        selectedBuiltInPreset = nil
        parametricBands = preset.effectiveBands
        preGain = preset.preGain
        outputGain = preset.outputGain
        limiterEnabled = preset.limiterEnabled
        limiterCeilingDB = preset.limiterCeilingDB
    }

    func reset() {
        applyBuiltInPreset(.flat)
    }

    func clearPresetSelection() {
        selectedBuiltInPreset = nil
        selectedCustomPreset = nil
    }

    func setBandGain(index: Int, gain: Float) {
        guard parametricBands.indices.contains(index) else { return }
        var updatedBands = parametricBands
        updatedBands[index].gain = min(max(gain, -24.0), 24.0)
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func setBandFrequency(index: Int, frequency: Float) {
        guard parametricBands.indices.contains(index) else { return }
        var updatedBands = parametricBands
        updatedBands[index].frequency = min(max(frequency, 20.0), 20000.0)
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func setBandQ(index: Int, q: Float) {
        guard parametricBands.indices.contains(index) else { return }
        var updatedBands = parametricBands
        updatedBands[index].q = min(max(q, 0.2), 12.0)
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func setBandType(index: Int, type: EQFilterType) {
        guard parametricBands.indices.contains(index) else { return }
        var updatedBands = parametricBands
        updatedBands[index].type = type
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func setBandEnabled(index: Int, isEnabled: Bool) {
        guard parametricBands.indices.contains(index) else { return }
        var updatedBands = parametricBands
        updatedBands[index].isEnabled = isEnabled
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func setPreGain(gain: Float) {
        preGain = min(max(gain, -24.0), 24.0)
        clearPresetSelection()
    }

    func setOutputGain(gain: Float) {
        outputGain = min(max(gain, -24.0), 24.0)
        clearPresetSelection()
    }

    func setLimiterEnabled(_ enabled: Bool) {
        limiterEnabled = enabled
        clearPresetSelection()
    }

    func setLimiterCeilingDB(_ value: Float) {
        limiterCeilingDB = min(max(value, -6.0), -0.1)
        clearPresetSelection()
    }

    private func saveSettings() {
        settingsStore.update { settings in
            settings.parametricBands = parametricBands
            settings.isEnabled = isEnabled
            settings.isEQFiltersEnabled = isEQFiltersEnabled
            settings.preGain = preGain
            settings.outputGain = outputGain
            settings.limiterEnabled = limiterEnabled
            settings.limiterCeilingDB = limiterCeilingDB
            settings.autoStopClippingEnabled = autoStopClippingEnabled
            settings.volume = volume
            settings.autoSaveEnabled = autoSaveEnabled

            if let preset = selectedBuiltInPreset {
                settings.selectedBuiltInPresetName = preset.rawValue
                settings.selectedCustomPresetID = nil
            } else if let preset = selectedCustomPreset {
                settings.selectedBuiltInPresetName = nil
                settings.selectedCustomPresetID = preset.id.uuidString
            } else {
                settings.selectedBuiltInPresetName = nil
                settings.selectedCustomPresetID = nil
            }
        }
    }

    private func loadSettings() {
        if let settings = settingsStore.load() {
            if !settings.parametricBands.isEmpty {
                parametricBands = settings.parametricBands
            }
            isEnabled = settings.isEnabled
            isEQFiltersEnabled = settings.isEQFiltersEnabled
            preGain = settings.preGain
            outputGain = settings.outputGain
            limiterEnabled = settings.limiterEnabled
            limiterCeilingDB = settings.limiterCeilingDB
            autoStopClippingEnabled = settings.autoStopClippingEnabled
            volume = settings.volume
            autoSaveEnabled = settings.autoSaveEnabled

            if let presetName = settings.selectedBuiltInPresetName,
               let preset = BuiltInPreset(rawValue: presetName) {
                selectedBuiltInPreset = preset
                selectedCustomPreset = nil
            }
            return
        }

        if let parametricData = UserDefaults.standard.data(forKey: legacyParametricBandsKey),
           let decoded = try? JSONDecoder().decode([EQBand].self, from: parametricData),
           !decoded.isEmpty {
            parametricBands = decoded
        } else if let savedBands = UserDefaults.standard.array(forKey: legacyBandsKey) as? [NSNumber] {
            parametricBands = EQBand.tenBand(withGains: savedBands.map { $0.floatValue })
        }

        isEnabled = UserDefaults.standard.object(forKey: legacyEnabledKey) as? Bool ?? true
        preGain = UserDefaults.standard.object(forKey: legacyPreGainKey) as? Float ?? 0.0
        outputGain = 0.0
        limiterEnabled = true
        limiterCeilingDB = -1.0
        autoStopClippingEnabled = UserDefaults.standard.object(forKey: legacyAutoStopClippingKey) as? Bool ?? false

        if let presetName = UserDefaults.standard.string(forKey: legacyBuiltInPresetKey),
           let preset = BuiltInPreset(rawValue: presetName) {
            selectedBuiltInPreset = preset
            selectedCustomPreset = nil
        }

        // Migrate from legacy UserDefaults keys to JSON save file on first launch after upgrade.
        saveSettings()
    }
}

struct EQResponsePoint {
    let frequency: Float
    let gainDB: Float
}

extension EQModel {
    static let responseMinFrequency: Float = 20.0
    static let responseMaxFrequency: Float = 20_000.0

    func responseCurve(sampleRate: Float, pointCount: Int = 220) -> [EQResponsePoint] {
        guard pointCount > 1 else {
            return [EQResponsePoint(frequency: Self.responseMinFrequency, gainDB: 0.0)]
        }

        let safeSampleRate = max(8_000.0, sampleRate)
        let logMin = log10f(Self.responseMinFrequency)
        let logMax = log10f(Self.responseMaxFrequency)

        return (0..<pointCount).map { index in
            let t = Float(index) / Float(pointCount - 1)
            let exponent = logMin + ((logMax - logMin) * t)
            let frequency = powf(10.0, exponent)
            let gainDB = responseGainDB(at: frequency, sampleRate: safeSampleRate)
            return EQResponsePoint(frequency: frequency, gainDB: gainDB)
        }
    }

    private func responseGainDB(at frequency: Float, sampleRate: Float) -> Float {
        guard isEnabled else { return 0.0 }

        var totalMagnitude = powf(10.0, preGain / 20.0)
        if isEQFiltersEnabled {
            for band in parametricBands where band.isEnabled {
                totalMagnitude *= Self.biquadMagnitude(for: band, at: frequency, sampleRate: sampleRate)
            }
        }

        let safeMagnitude = max(totalMagnitude, 1e-7)
        return 20.0 * log10f(safeMagnitude)
    }

    private static func biquadMagnitude(for band: EQBand, at frequency: Float, sampleRate: Float) -> Float {
        guard let coefficients = biquadCoefficients(for: band, sampleRate: sampleRate) else {
            return 1.0
        }

        let omega = 2.0 * Float.pi * frequency / sampleRate
        let cosW = cosf(omega)
        let sinW = sinf(omega)
        let cos2W = cosf(2.0 * omega)
        let sin2W = sinf(2.0 * omega)

        let numeratorReal = coefficients.b0 + (coefficients.b1 * cosW) + (coefficients.b2 * cos2W)
        let numeratorImag = -(coefficients.b1 * sinW) - (coefficients.b2 * sin2W)

        let denominatorReal = 1.0 + (coefficients.a1 * cosW) + (coefficients.a2 * cos2W)
        let denominatorImag = -(coefficients.a1 * sinW) - (coefficients.a2 * sin2W)

        let numeratorMagSquared = (numeratorReal * numeratorReal) + (numeratorImag * numeratorImag)
        let denominatorMagSquared = max((denominatorReal * denominatorReal) + (denominatorImag * denominatorImag), 1e-12)

        return sqrtf(numeratorMagSquared / denominatorMagSquared)
    }

    private static func biquadCoefficients(for band: EQBand, sampleRate: Float) -> (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float)? {
        let limitedSampleRate = max(8_000.0, sampleRate)
        let nyquist = (limitedSampleRate * 0.5) - 1.0
        let limitedFrequency = max(20.0, min(band.frequency, nyquist))
        let limitedQ = max(0.05, band.q)
        let limitedGain = max(-24.0, min(24.0, band.gain))

        let A = powf(10.0, limitedGain / 40.0)
        let omega = 2.0 * Float.pi * limitedFrequency / limitedSampleRate
        let sinOmega = sinf(omega)
        let cosOmega = cosf(omega)
        let alpha = sinOmega / (2.0 * limitedQ)
        let sqrtA = sqrtf(A)

        var b0Raw: Float = 1.0
        var b1Raw: Float = 0.0
        var b2Raw: Float = 0.0
        var a0Raw: Float = 1.0
        var a1Raw: Float = 0.0
        var a2Raw: Float = 0.0

        switch band.type {
        case .peak:
            if abs(limitedGain) < 0.01 { return nil }
            b0Raw = 1.0 + alpha * A
            b1Raw = -2.0 * cosOmega
            b2Raw = 1.0 - alpha * A
            a0Raw = 1.0 + alpha / A
            a1Raw = -2.0 * cosOmega
            a2Raw = 1.0 - alpha / A

        case .lowShelf:
            if abs(limitedGain) < 0.01 { return nil }
            b0Raw = A * ((A + 1.0) - (A - 1.0) * cosOmega + 2.0 * sqrtA * alpha)
            b1Raw = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosOmega)
            b2Raw = A * ((A + 1.0) - (A - 1.0) * cosOmega - 2.0 * sqrtA * alpha)
            a0Raw = (A + 1.0) + (A - 1.0) * cosOmega + 2.0 * sqrtA * alpha
            a1Raw = -2.0 * ((A - 1.0) + (A + 1.0) * cosOmega)
            a2Raw = (A + 1.0) + (A - 1.0) * cosOmega - 2.0 * sqrtA * alpha

        case .highShelf:
            if abs(limitedGain) < 0.01 { return nil }
            b0Raw = A * ((A + 1.0) + (A - 1.0) * cosOmega + 2.0 * sqrtA * alpha)
            b1Raw = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosOmega)
            b2Raw = A * ((A + 1.0) + (A - 1.0) * cosOmega - 2.0 * sqrtA * alpha)
            a0Raw = (A + 1.0) - (A - 1.0) * cosOmega + 2.0 * sqrtA * alpha
            a1Raw = 2.0 * ((A - 1.0) - (A + 1.0) * cosOmega)
            a2Raw = (A + 1.0) - (A - 1.0) * cosOmega - 2.0 * sqrtA * alpha

        case .lowPass:
            b0Raw = (1.0 - cosOmega) * 0.5
            b1Raw = 1.0 - cosOmega
            b2Raw = (1.0 - cosOmega) * 0.5
            a0Raw = 1.0 + alpha
            a1Raw = -2.0 * cosOmega
            a2Raw = 1.0 - alpha

        case .highPass:
            b0Raw = (1.0 + cosOmega) * 0.5
            b1Raw = -(1.0 + cosOmega)
            b2Raw = (1.0 + cosOmega) * 0.5
            a0Raw = 1.0 + alpha
            a1Raw = -2.0 * cosOmega
            a2Raw = 1.0 - alpha

        case .notch:
            b0Raw = 1.0
            b1Raw = -2.0 * cosOmega
            b2Raw = 1.0
            a0Raw = 1.0 + alpha
            a1Raw = -2.0 * cosOmega
            a2Raw = 1.0 - alpha

        case .bandPass:
            b0Raw = alpha
            b1Raw = 0.0
            b2Raw = -alpha
            a0Raw = 1.0 + alpha
            a1Raw = -2.0 * cosOmega
            a2Raw = 1.0 - alpha
        }

        let safeA0 = abs(a0Raw) < 1e-8 ? 1.0 : a0Raw
        return (
            b0Raw / safeA0,
            b1Raw / safeA0,
            b2Raw / safeA0,
            a1Raw / safeA0,
            a2Raw / safeA0
        )
    }
}
