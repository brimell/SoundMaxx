import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isInput: Bool
    let isOutput: Bool
}

class AudioDeviceManager: ObservableObject {
    @Published var outputDevices: [AudioDevice] = []
    @Published var inputDevices: [AudioDevice] = []

    init() {
        refreshDevices()
    }

    func refreshDevices() {
        outputDevices = getDevices(forInput: false)
        inputDevices = getDevices(forInput: true)
    }

    func nextOutputDevice(after currentDeviceID: AudioDeviceID?, preferredUIDs: [String]? = nil) -> AudioDevice? {
        refreshDevices()
        let cyclingDevices = filteredOutputDevices(preferredUIDs: preferredUIDs)
        guard !cyclingDevices.isEmpty else { return nil }

        guard let currentDeviceID,
              let currentIndex = cyclingDevices.firstIndex(where: { $0.id == currentDeviceID }) else {
            return cyclingDevices.first
        }

        let nextIndex = cyclingDevices.index(after: currentIndex)
        if nextIndex == cyclingDevices.endIndex {
            return cyclingDevices.first
        }

        return cyclingDevices[nextIndex]
    }

    private func filteredOutputDevices(preferredUIDs: [String]?) -> [AudioDevice] {
        guard let preferredUIDs, !preferredUIDs.isEmpty else {
            return outputDevices
        }

        let preferredSet = Set(preferredUIDs)
        let filtered = outputDevices.filter { preferredSet.contains($0.uid) }
        return filtered.isEmpty ? outputDevices : filtered
    }

    func getDevices(forInput isInput: Bool) -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> AudioDevice? in
            guard let name = getDeviceName(deviceID),
                  let uid = getDeviceUID(deviceID),
                  hasStreams(deviceID, isInput: isInput) else {
                return nil
            }

            return AudioDevice(
                id: deviceID,
                uid: uid,
                name: name,
                isInput: isInput,
                isOutput: !isInput
            )
        }
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var unmanagedName: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &unmanagedName) { unmanagedNamePtr in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &dataSize,
                unmanagedNamePtr
            )
        }

        guard status == noErr, let deviceName = unmanagedName?.takeRetainedValue() else { return nil }
        return deviceName as String
    }

    private func hasStreams(_ deviceID: AudioDeviceID, isInput: Bool) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        return status == noErr && dataSize > 0
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var unmanagedUID: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &unmanagedUID
        )

        guard status == noErr, let deviceUID = unmanagedUID?.takeRetainedValue() else { return nil }
        return deviceUID as String
    }

    func findBlackHole() -> AudioDevice? {
        return inputDevices.first { $0.name.lowercased().contains("blackhole") }
    }

    func getDefaultOutputDevice() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        return status == noErr ? deviceID : nil
    }
}
