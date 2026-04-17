import Foundation
import CoreAudio

// MARK: - Device Profile

struct DeviceProfile: Codable, Identifiable {
    var id: String { deviceUID }
    let deviceUID: String
    let deviceName: String
    var eqBands: [Double]  // 10 bands, -12 to +12
    var parametricBands: [EQBand]?
    var preGain: Float     // -24.0 to +24.0
    var volume: Float      // 0.0 to 1.0 (for HDMI/software volume)
    var isEQEnabled: Bool

    init(
        deviceUID: String,
        deviceName: String,
        eqBands: [Double] = Array(repeating: 0.0, count: 10),
        parametricBands: [EQBand]? = nil,
        preGain: Float = 0.0,
        volume: Float = 1.0,
        isEQEnabled: Bool = true
    ) {
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.eqBands = eqBands
        self.parametricBands = parametricBands
        self.preGain = preGain
        self.volume = volume
        self.isEQEnabled = isEQEnabled
    }

    var effectiveBands: [EQBand] {
        if let parametricBands, !parametricBands.isEmpty {
            return parametricBands
        }
        return EQBand.tenBand(withGains: eqBands.map { Float($0) })
    }

    enum CodingKeys: String, CodingKey {
        case deviceUID
        case deviceName
        case eqBands
        case parametricBands
        case preGain
        case volume
        case isEQEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        deviceUID = try container.decode(String.self, forKey: .deviceUID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? "Unknown Device"
        eqBands = try container.decodeIfPresent([Double].self, forKey: .eqBands) ?? Array(repeating: 0.0, count: 10)
        parametricBands = try container.decodeIfPresent([EQBand].self, forKey: .parametricBands)
        preGain = try container.decodeIfPresent(Float.self, forKey: .preGain) ?? 0.0
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        isEQEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEQEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(deviceUID, forKey: .deviceUID)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(eqBands, forKey: .eqBands)
        try container.encode(parametricBands, forKey: .parametricBands)
        try container.encode(preGain, forKey: .preGain)
        try container.encode(volume, forKey: .volume)
        try container.encode(isEQEnabled, forKey: .isEQEnabled)
    }
}

// MARK: - Device Profile Manager

class DeviceProfileManager: ObservableObject {
    static let shared = DeviceProfileManager()

    @Published private(set) var profiles: [String: DeviceProfile] = [:]

    private let profilesKey = "SoundMax.DeviceProfiles"

    init() {
        loadProfiles()
    }

    // MARK: - Profile Management

    func profile(for deviceUID: String) -> DeviceProfile? {
        return profiles[deviceUID]
    }

    func saveProfile(_ profile: DeviceProfile) {
        profiles[profile.deviceUID] = profile
        persistProfiles()
    }

    func saveCurrentSettings(
        for deviceUID: String,
        deviceName: String,
        eqBands: [Double],
        parametricBands: [EQBand],
        preGain: Float,
        volume: Float,
        isEQEnabled: Bool
    ) {
        let profile = DeviceProfile(
            deviceUID: deviceUID,
            deviceName: deviceName,
            eqBands: eqBands,
            parametricBands: parametricBands,
            preGain: preGain,
            volume: volume,
            isEQEnabled: isEQEnabled
        )
        saveProfile(profile)
    }

    func deleteProfile(for deviceUID: String) {
        profiles.removeValue(forKey: deviceUID)
        persistProfiles()
    }

    func hasProfile(for deviceUID: String) -> Bool {
        return profiles[deviceUID] != nil
    }

    // MARK: - Persistence

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              let decoded = try? JSONDecoder().decode([String: DeviceProfile].self, from: data) else {
            return
        }
        profiles = decoded
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: profilesKey)
    }
}

// MARK: - Device Info Helper

struct DeviceInfo {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let hasVolumeControl: Bool
    let isHDMI: Bool

    static func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var unmanagedUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            &unmanagedUID
        )

        guard status == noErr, let deviceUID = unmanagedUID?.takeRetainedValue() else { return nil }
        return deviceUID as String
    }

    static func hasHardwareVolumeControl(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Check if volume is settable
        var isSettable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(deviceID, &propertyAddress, &isSettable)

        if status == noErr && isSettable.boolValue {
            return true
        }

        // Also check channel 1
        propertyAddress.mElement = 1
        let status2 = AudioObjectIsPropertySettable(deviceID, &propertyAddress, &isSettable)

        return status2 == noErr && isSettable.boolValue
    }

    static func isHDMIDevice(_ deviceID: AudioDeviceID) -> Bool {
        // Check transport type
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            &transportType
        )

        guard status == noErr else { return false }

        // kAudioDeviceTransportTypeHDMI = 'hdmi'
        let hdmiType = UInt32(0x68646D69) // 'hdmi' in hex
        let displayPortType = UInt32(0x6470) // 'dp' in hex

        return transportType == hdmiType || transportType == displayPortType
    }

    static func getInfo(for deviceID: AudioDeviceID, name: String) -> DeviceInfo? {
        guard let uid = getDeviceUID(deviceID) else { return nil }

        let hasVolume = hasHardwareVolumeControl(deviceID)
        let isHDMI = isHDMIDevice(deviceID)

        return DeviceInfo(
            id: deviceID,
            uid: uid,
            name: name,
            hasVolumeControl: hasVolume,
            isHDMI: isHDMI
        )
    }
}
