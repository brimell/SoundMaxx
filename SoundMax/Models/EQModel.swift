import SwiftUI
import Combine

class EQModel: ObservableObject {
    @Published var parametricBands: [EQBand] = EQBand.defaultTenBand
    @Published var isEnabled: Bool = true
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
    private var isLoadingProfile = false
    private let parametricBandsKey = "eq_parametric_bands"

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

        $volume
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
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
            volume: volume,
            isEQEnabled: isEnabled
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
        volume = profile.volume
        isEnabled = profile.isEQEnabled
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
            volume: volume,
            isEQEnabled: isEnabled
        )
    }

    func applyBuiltInPreset(_ preset: BuiltInPreset) {
        selectedBuiltInPreset = preset
        selectedCustomPreset = nil
        parametricBands = preset.bands
    }

    func applyCustomPreset(_ preset: CustomPreset) {
        selectedCustomPreset = preset
        selectedBuiltInPreset = nil
        parametricBands = preset.effectiveBands
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
        parametricBands[index].gain = gain
        clearPresetSelection()
    }

    func setBandFrequency(index: Int, frequency: Float) {
        guard parametricBands.indices.contains(index) else { return }
        parametricBands[index].frequency = frequency
        clearPresetSelection()
    }

    func setBandQ(index: Int, q: Float) {
        guard parametricBands.indices.contains(index) else { return }
        parametricBands[index].q = q
        clearPresetSelection()
    }

    func setBandType(index: Int, type: EQFilterType) {
        guard parametricBands.indices.contains(index) else { return }
        parametricBands[index].type = type
        clearPresetSelection()
    }

    func setBandEnabled(index: Int, isEnabled: Bool) {
        guard parametricBands.indices.contains(index) else { return }
        parametricBands[index].isEnabled = isEnabled
        clearPresetSelection()
    }

    private func saveSettings() {
        UserDefaults.standard.set(legacyGains, forKey: "eq_bands")
        if let encoded = try? JSONEncoder().encode(parametricBands) {
            UserDefaults.standard.set(encoded, forKey: parametricBandsKey)
        }
        UserDefaults.standard.set(isEnabled, forKey: "eq_enabled")
        if let preset = selectedBuiltInPreset {
            UserDefaults.standard.set(preset.rawValue, forKey: "eq_builtin_preset")
            UserDefaults.standard.removeObject(forKey: "eq_custom_preset_id")
        } else if let preset = selectedCustomPreset {
            UserDefaults.standard.set(preset.id.uuidString, forKey: "eq_custom_preset_id")
            UserDefaults.standard.removeObject(forKey: "eq_builtin_preset")
        }
    }

    private func loadSettings() {
        if let parametricData = UserDefaults.standard.data(forKey: parametricBandsKey),
           let decoded = try? JSONDecoder().decode([EQBand].self, from: parametricData),
           !decoded.isEmpty {
            parametricBands = decoded
        } else if let savedBands = UserDefaults.standard.array(forKey: "eq_bands") as? [NSNumber] {
            parametricBands = EQBand.tenBand(withGains: savedBands.map { $0.floatValue })
        }
        isEnabled = UserDefaults.standard.object(forKey: "eq_enabled") as? Bool ?? true

        if let presetName = UserDefaults.standard.string(forKey: "eq_builtin_preset"),
           let preset = BuiltInPreset(rawValue: presetName) {
            selectedBuiltInPreset = preset
        }
    }
}
