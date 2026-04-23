import Foundation

// MARK: - App Settings

struct AppSettings: Codable {
    var parametricBands: [EQBand] = EQBand.defaultTenBand
    var isEnabled: Bool = true
    var isEQFiltersEnabled: Bool = true
    var preGain: Float = 0.0
    var outputGain: Float = 0.0
    var limiterEnabled: Bool = false
    var limiterCeilingDB: Float = -1.0
    var autoStopClippingEnabled: Bool = false
    var volume: Float = 1.0
    var usePerDeviceVolume: Bool = true
    var autoSaveEnabled: Bool = true
    var selectedBuiltInPresetName: String? = nil
    var selectedCustomPresetID: String? = nil
    var selectedInputDeviceID: Int32? = nil
    var selectedOutputDeviceID: Int32? = nil
    var shortcutOutputDeviceUIDs: [String]? = nil
    var normalizeSpectrumAnalyzer: Bool = false
    var preferredIOBufferFrames: Int32 = Int32(AudioEngine.defaultIOBufferFrames)
    var ringBufferCapacityMultiplier: Int32 = Int32(AudioEngine.defaultRingBufferCapacityMultiplier)
    var latencyTargetMultiplier: Int32 = Int32(AudioEngine.defaultLatencyTargetMultiplier)

    enum CodingKeys: String, CodingKey {
        case parametricBands
        case isEnabled
        case isEQFiltersEnabled
        case preGain
        case outputGain
        case limiterEnabled
        case limiterCeilingDB
        case autoStopClippingEnabled
        case volume
        case usePerDeviceVolume
        case autoSaveEnabled
        case selectedBuiltInPresetName
        case selectedCustomPresetID
        case selectedInputDeviceID
        case selectedOutputDeviceID
        case shortcutOutputDeviceUIDs
        case normalizeSpectrumAnalyzer
        case preferredIOBufferFrames
        case ringBufferCapacityMultiplier
        case latencyTargetMultiplier
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        parametricBands = try container.decodeIfPresent([EQBand].self, forKey: .parametricBands) ?? EQBand.defaultTenBand
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isEQFiltersEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEQFiltersEnabled) ?? true
        preGain = try container.decodeIfPresent(Float.self, forKey: .preGain) ?? 0.0
        outputGain = try container.decodeIfPresent(Float.self, forKey: .outputGain) ?? 0.0
        limiterEnabled = try container.decodeIfPresent(Bool.self, forKey: .limiterEnabled) ?? false
        limiterCeilingDB = try container.decodeIfPresent(Float.self, forKey: .limiterCeilingDB) ?? -1.0
        autoStopClippingEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoStopClippingEnabled) ?? false
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        usePerDeviceVolume = try container.decodeIfPresent(Bool.self, forKey: .usePerDeviceVolume) ?? true
        autoSaveEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSaveEnabled) ?? true
        selectedBuiltInPresetName = try container.decodeIfPresent(String.self, forKey: .selectedBuiltInPresetName)
        selectedCustomPresetID = try container.decodeIfPresent(String.self, forKey: .selectedCustomPresetID)
        selectedInputDeviceID = try container.decodeIfPresent(Int32.self, forKey: .selectedInputDeviceID)
        selectedOutputDeviceID = try container.decodeIfPresent(Int32.self, forKey: .selectedOutputDeviceID)
        shortcutOutputDeviceUIDs = try container.decodeIfPresent([String].self, forKey: .shortcutOutputDeviceUIDs)
        normalizeSpectrumAnalyzer = try container.decodeIfPresent(Bool.self, forKey: .normalizeSpectrumAnalyzer) ?? false
        preferredIOBufferFrames = try container.decodeIfPresent(Int32.self, forKey: .preferredIOBufferFrames) ?? Int32(AudioEngine.defaultIOBufferFrames)
        ringBufferCapacityMultiplier = try container.decodeIfPresent(Int32.self, forKey: .ringBufferCapacityMultiplier) ?? Int32(AudioEngine.defaultRingBufferCapacityMultiplier)
        latencyTargetMultiplier = try container.decodeIfPresent(Int32.self, forKey: .latencyTargetMultiplier) ?? Int32(AudioEngine.defaultLatencyTargetMultiplier)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(parametricBands, forKey: .parametricBands)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isEQFiltersEnabled, forKey: .isEQFiltersEnabled)
        try container.encode(preGain, forKey: .preGain)
        try container.encode(outputGain, forKey: .outputGain)
        try container.encode(limiterEnabled, forKey: .limiterEnabled)
        try container.encode(limiterCeilingDB, forKey: .limiterCeilingDB)
        try container.encode(autoStopClippingEnabled, forKey: .autoStopClippingEnabled)
        try container.encode(volume, forKey: .volume)
        try container.encode(usePerDeviceVolume, forKey: .usePerDeviceVolume)
        try container.encode(autoSaveEnabled, forKey: .autoSaveEnabled)
        try container.encode(selectedBuiltInPresetName, forKey: .selectedBuiltInPresetName)
        try container.encode(selectedCustomPresetID, forKey: .selectedCustomPresetID)
        try container.encode(selectedInputDeviceID, forKey: .selectedInputDeviceID)
        try container.encode(selectedOutputDeviceID, forKey: .selectedOutputDeviceID)
        try container.encode(shortcutOutputDeviceUIDs, forKey: .shortcutOutputDeviceUIDs)
        try container.encode(normalizeSpectrumAnalyzer, forKey: .normalizeSpectrumAnalyzer)
        try container.encode(preferredIOBufferFrames, forKey: .preferredIOBufferFrames)
        try container.encode(ringBufferCapacityMultiplier, forKey: .ringBufferCapacityMultiplier)
        try container.encode(latencyTargetMultiplier, forKey: .latencyTargetMultiplier)
    }
}

// MARK: - App Settings Store

class AppSettingsStore {
    static let shared = AppSettingsStore()

    private let settingsKey = "SoundMaxx.AppSettings"
    private var cachedSettings: AppSettings?
    private var cachedEncodedSettings: Data?

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

    /// Returns current settings or defaults if none are stored yet.
    func current() -> AppSettings {
        load() ?? AppSettings()
    }

    /// Updates settings with a mutation closure and persists them
    func update(_ mutation: (inout AppSettings) -> Void) {
        var settings = load() ?? AppSettings()
        mutation(&settings)
        cachedSettings = settings
        persistToDefaults(settings)
    }

    /// Replaces all app settings with imported values.
    func replace(with settings: AppSettings) {
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
        cachedEncodedSettings = data
        return decoded
    }

    private func persistToDefaults(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            print("Failed to encode app settings")
            return
        }

        if let cachedEncodedSettings, cachedEncodedSettings == data {
            return
        }

        if cachedEncodedSettings == nil,
           let storedData = UserDefaults.standard.data(forKey: settingsKey),
           storedData == data {
            cachedEncodedSettings = storedData
            return
        }

        cachedEncodedSettings = data
        UserDefaults.standard.set(data, forKey: settingsKey)
    }
}
