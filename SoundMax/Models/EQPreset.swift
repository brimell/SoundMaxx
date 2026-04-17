import Foundation

enum EQFilterType: String, CaseIterable, Codable, Identifiable {
    case peak
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch
    case bandPass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peak:
            return "Peak"
        case .lowShelf:
            return "Low Shelf"
        case .highShelf:
            return "High Shelf"
        case .lowPass:
            return "Low Pass"
        case .highPass:
            return "High Pass"
        case .notch:
            return "Notch"
        case .bandPass:
            return "Band Pass"
        }
    }

    var supportsGain: Bool {
        switch self {
        case .peak, .lowShelf, .highShelf:
            return true
        case .lowPass, .highPass, .notch, .bandPass:
            return false
        }
    }
}

struct EQBand: Codable, Identifiable, Equatable {
    var id: UUID
    var isEnabled: Bool
    var type: EQFilterType
    var frequency: Float
    var gain: Float
    var q: Float

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        type: EQFilterType = .peak,
        frequency: Float,
        gain: Float = 0,
        q: Float = 1.4
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }

    static let defaultFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    static var defaultTenBand: [EQBand] {
        defaultFrequencies.map { frequency in
            EQBand(type: .peak, frequency: frequency, gain: 0, q: 1.4)
        }
    }

    static func tenBand(withGains gains: [Float]) -> [EQBand] {
        let fallback = defaultTenBand
        return fallback.enumerated().map { index, band in
            var updated = band
            if index < gains.count {
                updated.gain = gains[index]
            }
            return updated
        }
    }
}

// Built-in presets
enum BuiltInPreset: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case trebleBoost = "Treble Boost"
    case vocal = "Vocal"
    case rock = "Rock"
    case electronic = "Electronic"
    case acoustic = "Acoustic"

    var id: String { rawValue }

    var bands: [EQBand] {
        EQBand.tenBand(withGains: values)
    }

    var values: [Float] {
        switch self {
        case .flat:
            return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost:
            return [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .trebleBoost:
            return [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]
        case .vocal:
            return [-2, -1, 0, 2, 4, 4, 3, 2, 0, -1]
        case .rock:
            return [5, 4, 2, 0, -1, 0, 2, 4, 5, 5]
        case .electronic:
            return [5, 4, 2, 0, -2, -2, 0, 2, 4, 5]
        case .acoustic:
            return [3, 2, 1, 1, 2, 2, 2, 3, 3, 2]
        }
    }
}

// Custom user preset
struct CustomPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var values: [Float]
    var parametricBands: [EQBand]?

    init(name: String, values: [Float]) {
        self.id = UUID()
        self.name = name
        self.values = values
        self.parametricBands = EQBand.tenBand(withGains: values)
    }

    init(name: String, bands: [EQBand]) {
        self.id = UUID()
        self.name = name
        self.values = bands.map { $0.gain }
        self.parametricBands = bands
    }

    var effectiveBands: [EQBand] {
        parametricBands ?? EQBand.tenBand(withGains: values)
    }
}

// Manager for custom presets
class PresetManager: ObservableObject {
    @Published var customPresets: [CustomPreset] = []

    private let presetsKey = "custom_presets"

    init() {
        loadPresets()
    }

    func savePreset(name: String, bands: [EQBand]) {
        let preset = CustomPreset(name: name, bands: bands)
        customPresets.append(preset)
        persistPresets()
    }

    func deletePreset(_ preset: CustomPreset) {
        customPresets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    func updatePreset(_ preset: CustomPreset, bands: [EQBand]) {
        if let index = customPresets.firstIndex(where: { $0.id == preset.id }) {
            customPresets[index].values = bands.map { $0.gain }
            customPresets[index].parametricBands = bands
            persistPresets()
        }
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: presetsKey)
        }
    }

    private func loadPresets() {
        if let data = UserDefaults.standard.data(forKey: presetsKey),
           let presets = try? JSONDecoder().decode([CustomPreset].self, from: data) {
            customPresets = presets
        }
    }
}
