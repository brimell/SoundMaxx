import Foundation

// MARK: - App Settings

struct AppSettings: Codable {
    var parametricBands: [EQBand] = EQBand.defaultTenBand
    var isEnabled: Bool = true
    var preGain: Float = 0.0
    var autoStopClippingEnabled: Bool = false
    var volume: Float = 1.0
    var autoSaveEnabled: Bool = true
    var selectedBuiltInPresetName: String? = nil
    var selectedCustomPresetID: String? = nil
    var selectedInputDeviceID: Int32? = nil
    var selectedOutputDeviceID: Int32? = nil

    enum CodingKeys: String, CodingKey {
        case parametricBands
        case isEnabled
        case preGain
        case autoStopClippingEnabled
        case volume
        case autoSaveEnabled
        case selectedBuiltInPresetName
        case selectedCustomPresetID
        case selectedInputDeviceID
        case selectedOutputDeviceID
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        parametricBands = try container.decodeIfPresent([EQBand].self, forKey: .parametricBands) ?? EQBand.defaultTenBand
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        preGain = try container.decodeIfPresent(Float.self, forKey: .preGain) ?? 0.0
        autoStopClippingEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoStopClippingEnabled) ?? false
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        autoSaveEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSaveEnabled) ?? true
        selectedBuiltInPresetName = try container.decodeIfPresent(String.self, forKey: .selectedBuiltInPresetName)
        selectedCustomPresetID = try container.decodeIfPresent(String.self, forKey: .selectedCustomPresetID)
        selectedInputDeviceID = try container.decodeIfPresent(Int32.self, forKey: .selectedInputDeviceID)
        selectedOutputDeviceID = try container.decodeIfPresent(Int32.self, forKey: .selectedOutputDeviceID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(parametricBands, forKey: .parametricBands)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(preGain, forKey: .preGain)
        try container.encode(autoStopClippingEnabled, forKey: .autoStopClippingEnabled)
        try container.encode(volume, forKey: .volume)
        try container.encode(autoSaveEnabled, forKey: .autoSaveEnabled)
        try container.encode(selectedBuiltInPresetName, forKey: .selectedBuiltInPresetName)
        try container.encode(selectedCustomPresetID, forKey: .selectedCustomPresetID)
        try container.encode(selectedInputDeviceID, forKey: .selectedInputDeviceID)
        try container.encode(selectedOutputDeviceID, forKey: .selectedOutputDeviceID)
    }
}

// MARK: - App Settings Store

class AppSettingsStore {
    static let shared = AppSettingsStore()

    private let settingsKey = "SoundMaxx.AppSettings"
    private var cachedSettings: AppSettings?

    init() {
        loadFromDefaults()
    }

    /// Loads the current settings from persistent storage
    func load() -> AppSettings? {
        if let cached = cachedSettings {
            return cached
        }
        return loadFromDefaults()
    }

    /// Updates settings with a mutation closure and persists them
    func update(_ mutation: (inout AppSettings) -> Void) {
        var settings = load() ?? AppSettings()
        mutation(&settings)
        cachedSettings = settings
        persistToDefaults(settings)
    }

    // MARK: - Private Methods

    private func loadFromDefaults() -> AppSettings? {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return nil
        }
        cachedSettings = decoded
        return decoded
    }

    private func persistToDefaults(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            print("Failed to encode app settings")
            return
        }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }
}
