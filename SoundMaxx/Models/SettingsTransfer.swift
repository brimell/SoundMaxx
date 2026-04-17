import Foundation

struct SettingsTransferBundle: Codable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let appSettings: AppSettings
    let deviceProfiles: [String: DeviceProfile]
    let customPresets: [CustomPreset]

    init(
        appSettings: AppSettings,
        deviceProfiles: [String: DeviceProfile],
        customPresets: [CustomPreset],
        version: Int = SettingsTransferBundle.currentVersion,
        exportedAt: Date = Date()
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.appSettings = appSettings
        self.deviceProfiles = deviceProfiles
        self.customPresets = customPresets
    }
}

enum SettingsTransferError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported backup version: \(version)."
        }
    }
}

enum SettingsTransfer {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func write(_ bundle: SettingsTransferBundle, to url: URL) throws {
        let data = try encoder.encode(bundle)
        try data.write(to: url, options: [.atomic])
    }

    static func read(from url: URL) throws -> SettingsTransferBundle {
        let data = try Data(contentsOf: url)
        let bundle = try decoder.decode(SettingsTransferBundle.self, from: data)

        guard bundle.version <= SettingsTransferBundle.currentVersion else {
            throw SettingsTransferError.unsupportedVersion(bundle.version)
        }

        return bundle
    }
}
