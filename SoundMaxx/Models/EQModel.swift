import SwiftUI
import Combine

class EQModel: ObservableObject {
    private struct HistorySnapshot: Equatable {
        var parametricBands: [EQBand]
        var isEnabled: Bool
        var isEQFiltersEnabled: Bool
        var preGain: Float
        var outputGain: Float
        var limiterEnabled: Bool
        var limiterCeilingDB: Float
        var autoStopClippingEnabled: Bool
        var volume: Float
        var selectedBuiltInPresetName: String?
        var selectedCustomPresetID: String?
    }

    @Published var parametricBands: [EQBand] = EQBand.defaultTenBand
    @Published var isEnabled: Bool = true
    @Published var isEQFiltersEnabled: Bool = true
    @Published var preGain: Float = 0.0
    @Published var outputGain: Float = 0.0
    @Published var limiterEnabled: Bool = false
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
    @Published var usePerDeviceVolume: Bool = true
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    @Published private(set) var hasCompareA: Bool = false
    @Published private(set) var hasCompareB: Bool = false

    static let frequencyLabels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    static let minimumBandCount = 1
    static let preGainRange: ClosedRange<Float> = -12.0...0.0
    static let outputGainRange: ClosedRange<Float> = -40.0...40.0

    var legacyGains: [Float] {
        parametricBands.map { $0.gain }
    }

    private var cancellables = Set<AnyCancellable>()
    private let profileManager = DeviceProfileManager.shared
    private let settingsStore = AppSettingsStore.shared
    private var isLoadingProfile = false
    private var pendingCustomPresetID: String?
    private let legacyParametricBandsKey = "eq_parametric_bands"
    private let legacyPreGainKey = "eq_pre_gain"
    private let legacyBandsKey = "eq_bands"
    private let legacyEnabledKey = "eq_enabled"
    private let legacyBuiltInPresetKey = "eq_builtin_preset"
    private let legacyAutoStopClippingKey = "eq_auto_stop_clipping"
    private var undoHistory: [HistorySnapshot] = []
    private var redoHistory: [HistorySnapshot] = []
    private var compareSnapshotA: HistorySnapshot?
    private var compareSnapshotB: HistorySnapshot?
    private var isApplyingHistorySnapshot = false
    private var lastHistoryContext: String?
    private var lastHistoryContextTime: TimeInterval = 0
    private let historyMergeWindow: TimeInterval = 0.35
    private let maxHistoryDepth = 180

    private static func clampPreGain(_ value: Float) -> Float {
        min(max(value, preGainRange.lowerBound), preGainRange.upperBound)
    }

    private static func clampOutputGain(_ value: Float) -> Float {
        min(max(value, outputGainRange.lowerBound), outputGainRange.upperBound)
    }

    init() {
        loadSettings()
        clearHistory()

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

        $usePerDeviceVolume
            .sink { [weak self] _ in
                self?.saveSettings()
            }
            .store(in: &cancellables)

        $autoSaveEnabled
            .sink { [weak self] _ in
                self?.saveSettings()
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

        clearHistory()
        clearCompareSnapshots()
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
            volume: profileVolumeForSave(deviceUID: uid),
            isEQEnabled: isEnabled,
            isEQFiltersEnabled: isEQFiltersEnabled,
            selectedBuiltInPresetName: selectedBuiltInPreset?.rawValue,
            selectedCustomPresetID: selectedCustomPreset?.id.uuidString ?? pendingCustomPresetID
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
        preGain = Self.clampPreGain(profile.preGain)
        outputGain = Self.clampOutputGain(profile.outputGain)
        limiterEnabled = profile.limiterEnabled
        limiterCeilingDB = profile.limiterCeilingDB
        autoStopClippingEnabled = profile.autoStopClippingEnabled
        if usePerDeviceVolume {
            volume = profile.volume
        }
        isEnabled = profile.isEQEnabled
        isEQFiltersEnabled = profile.isEQFiltersEnabled
        applyStoredPresetSelection(
            builtInPresetName: profile.selectedBuiltInPresetName,
            customPresetID: profile.selectedCustomPresetID
        )
        isLoadingProfile = false
    }

    private func autoSaveToDeviceProfile() {
        guard autoSaveEnabled,
              !isLoadingProfile,
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
            volume: profileVolumeForSave(deviceUID: uid),
            isEQEnabled: isEnabled,
            isEQFiltersEnabled: isEQFiltersEnabled,
            selectedBuiltInPresetName: selectedBuiltInPreset?.rawValue,
            selectedCustomPresetID: selectedCustomPreset?.id.uuidString ?? pendingCustomPresetID
        )
        hasDeviceProfile = true
    }

    func applyBuiltInPreset(_ preset: BuiltInPreset) {
        recordHistorySnapshot(context: "preset-built-in")
        selectedBuiltInPreset = preset
        selectedCustomPreset = nil
        pendingCustomPresetID = nil
        parametricBands = preset.bands
        preGain = 0.0
        outputGain = 0.0
    }

    func applyCustomPreset(_ preset: CustomPreset) {
        recordHistorySnapshot(context: "preset-custom")
        selectedCustomPreset = preset
        selectedBuiltInPreset = nil
        pendingCustomPresetID = nil
        parametricBands = preset.effectiveBands
        preGain = Self.clampPreGain(preset.preGain)
        outputGain = Self.clampOutputGain(preset.outputGain)
        limiterEnabled = preset.limiterEnabled
        limiterCeilingDB = preset.limiterCeilingDB
    }

    func reset() {
        applyBuiltInPreset(.flat)
    }

    func clearPresetSelection() {
        selectedBuiltInPreset = nil
        selectedCustomPreset = nil
        pendingCustomPresetID = nil
    }

    func resolvePresetSelection(using customPresets: [CustomPreset]) {
        if let pendingCustomPresetID,
           let pendingUUID = UUID(uuidString: pendingCustomPresetID),
           let resolvedPreset = customPresets.first(where: { $0.id == pendingUUID }) {
            selectedBuiltInPreset = nil
            selectedCustomPreset = resolvedPreset
            self.pendingCustomPresetID = nil
            return
        }

        guard let selectedCustomPreset else { return }
        if let updatedPreset = customPresets.first(where: { $0.id == selectedCustomPreset.id }) {
            self.selectedCustomPreset = updatedPreset
        } else {
            clearPresetSelection()
        }
    }

    func setBandGain(index: Int, gain: Float) {
        guard parametricBands.indices.contains(index) else { return }
        recordHistorySnapshot(context: "band-\(index)-gain")
        var updatedBands = parametricBands
        updatedBands[index].gain = min(max(gain, -24.0), 24.0)
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func setBandFrequency(index: Int, frequency: Float) {
        guard parametricBands.indices.contains(index) else { return }
        recordHistorySnapshot(context: "band-\(index)-frequency")
        var updatedBands = parametricBands
        updatedBands[index].frequency = min(max(frequency, 20.0), 20000.0)
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func setBandQ(index: Int, q: Float) {
        guard parametricBands.indices.contains(index) else { return }
        recordHistorySnapshot(context: "band-\(index)-q")
        var updatedBands = parametricBands
        updatedBands[index].q = min(max(q, 0.2), 12.0)
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func setBandType(index: Int, type: EQFilterType) {
        guard parametricBands.indices.contains(index) else { return }
        recordHistorySnapshot(context: "band-\(index)-type")
        var updatedBands = parametricBands
        updatedBands[index].type = type
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func setBandEnabled(index: Int, isEnabled: Bool) {
        guard parametricBands.indices.contains(index) else { return }
        recordHistorySnapshot(context: "band-\(index)-enabled")
        var updatedBands = parametricBands
        updatedBands[index].isEnabled = isEnabled
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func addBand() {
        addBand(after: parametricBands.indices.last)
    }

    func addBand(after index: Int?) {
        recordHistorySnapshot(context: "band-add")
        let insertionIndex: Int
        if let index, parametricBands.indices.contains(index) {
            insertionIndex = index + 1
        } else {
            insertionIndex = parametricBands.count
        }

        let newFrequency = suggestedFrequency(after: index)
        let templateBand = (index != nil && parametricBands.indices.contains(index!))
            ? parametricBands[index!]
            : (parametricBands.last ?? EQBand(frequency: 1000.0))

        var newBand = templateBand
        newBand.id = UUID()
        newBand.frequency = newFrequency
        newBand.gain = 0.0

        var updatedBands = parametricBands
        updatedBands.insert(newBand, at: min(max(0, insertionIndex), updatedBands.count))
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func removeLastBand() {
        guard parametricBands.count > Self.minimumBandCount else { return }
        recordHistorySnapshot(context: "band-remove-last")
        var updatedBands = parametricBands
        updatedBands.removeLast()
        parametricBands = updatedBands
        clearPresetSelection()
    }

    func removeBand(at index: Int) {
        guard parametricBands.count > Self.minimumBandCount else { return }
        guard parametricBands.indices.contains(index) else { return }
        recordHistorySnapshot(context: "band-remove-\(index)")
        var updatedBands = parametricBands
        updatedBands.remove(at: index)
        parametricBands = updatedBands
        clearPresetSelection()
    }

    private func suggestedFrequency(after index: Int?) -> Float {
        let minFrequency: Float = 20.0
        let maxFrequency: Float = 20_000.0

        guard !parametricBands.isEmpty else { return 1000.0 }

        if let index, parametricBands.indices.contains(index) {
            let left = min(max(parametricBands[index].frequency, minFrequency), maxFrequency)

            if parametricBands.indices.contains(index + 1) {
                let right = min(max(parametricBands[index + 1].frequency, minFrequency), maxFrequency)
                if right > left {
                    return sqrtf(left * right)
                }
            }

            if index > 0 {
                let previous = min(max(parametricBands[index - 1].frequency, minFrequency), maxFrequency)
                if left > previous {
                    return min(left * (left / previous), maxFrequency)
                }
            }

            return min(left * 1.5, maxFrequency)
        }

        if parametricBands.count >= 2 {
            let last = min(max(parametricBands[parametricBands.count - 1].frequency, minFrequency), maxFrequency)
            let previous = min(max(parametricBands[parametricBands.count - 2].frequency, minFrequency), maxFrequency)
            if last > previous {
                return min(last * (last / previous), maxFrequency)
            }
            return min(last * 1.5, maxFrequency)
        }

        return min(max(parametricBands[0].frequency * 2.0, minFrequency), maxFrequency)
    }

    func setPreGain(gain: Float) {
        recordHistorySnapshot(context: "pre-gain")
        preGain = Self.clampPreGain(gain)
        clearPresetSelection()
    }

    func setOutputGain(gain: Float) {
        recordHistorySnapshot(context: "output-gain")
        outputGain = Self.clampOutputGain(gain)
        clearPresetSelection()
    }

    func setLimiterEnabled(_ enabled: Bool) {
        recordHistorySnapshot(context: "limiter-enabled")
        limiterEnabled = enabled
        clearPresetSelection()
    }

    func setLimiterCeilingDB(_ value: Float) {
        recordHistorySnapshot(context: "limiter-ceiling")
        limiterCeilingDB = min(max(value, -6.0), -0.1)
        clearPresetSelection()
    }

    func setAudioEnabled(_ enabled: Bool) {
        recordHistorySnapshot(context: "audio-enabled")
        isEnabled = enabled
    }

    func setFiltersEnabled(_ enabled: Bool) {
        recordHistorySnapshot(context: "filters-enabled")
        isEQFiltersEnabled = enabled
    }

    func setAutoStopClippingEnabled(_ enabled: Bool) {
        recordHistorySnapshot(context: "auto-stop-clipping")
        autoStopClippingEnabled = enabled
        clearPresetSelection()
    }

    func setVolume(_ value: Float) {
        recordHistorySnapshot(context: "volume")
        volume = min(max(value, 0.0), 1.0)
    }

    func setUsePerDeviceVolume(_ enabled: Bool) {
        guard usePerDeviceVolume != enabled else { return }
        usePerDeviceVolume = enabled

        guard enabled,
              let uid = currentDeviceUID,
              let profile = profileManager.profile(for: uid) else {
            return
        }

        volume = profile.volume
    }

    func setAutoSaveEnabled(_ enabled: Bool) {
        autoSaveEnabled = enabled
        if enabled {
            autoSaveToDeviceProfile()
        }
    }

    func applyImportedBands(_ bands: [EQBand], preGain: Float) {
        recordHistorySnapshot(context: "imported-bands")
        parametricBands = bands
        self.preGain = Self.clampPreGain(preGain)
        clearPresetSelection()
    }

    func saveCompareSnapshotA() {
        compareSnapshotA = makeHistorySnapshot()
        hasCompareA = compareSnapshotA != nil
    }

    func saveCompareSnapshotB() {
        compareSnapshotB = makeHistorySnapshot()
        hasCompareB = compareSnapshotB != nil
    }

    func loadCompareSnapshotA() {
        loadCompareSnapshot(compareSnapshotA, context: "compare-a-load")
    }

    func loadCompareSnapshotB() {
        loadCompareSnapshot(compareSnapshotB, context: "compare-b-load")
    }

    func reloadFromStoredSettings() {
        loadSettings()
        clearHistory()
        clearCompareSnapshots()
    }

    func undo() {
        guard let previousSnapshot = undoHistory.popLast() else { return }
        redoHistory.append(makeHistorySnapshot())
        applyHistorySnapshot(previousSnapshot)
        updateHistoryAvailability()
    }

    func redo() {
        guard let nextSnapshot = redoHistory.popLast() else { return }
        undoHistory.append(makeHistorySnapshot())
        applyHistorySnapshot(nextSnapshot)
        updateHistoryAvailability()
    }

    private func makeHistorySnapshot() -> HistorySnapshot {
        HistorySnapshot(
            parametricBands: parametricBands,
            isEnabled: isEnabled,
            isEQFiltersEnabled: isEQFiltersEnabled,
            preGain: preGain,
            outputGain: outputGain,
            limiterEnabled: limiterEnabled,
            limiterCeilingDB: limiterCeilingDB,
            autoStopClippingEnabled: autoStopClippingEnabled,
            volume: volume,
            selectedBuiltInPresetName: selectedBuiltInPreset?.rawValue,
            selectedCustomPresetID: selectedCustomPreset?.id.uuidString ?? pendingCustomPresetID
        )
    }

    private func applyHistorySnapshot(_ snapshot: HistorySnapshot) {
        isApplyingHistorySnapshot = true
        parametricBands = snapshot.parametricBands
        isEnabled = snapshot.isEnabled
        isEQFiltersEnabled = snapshot.isEQFiltersEnabled
        preGain = snapshot.preGain
        outputGain = snapshot.outputGain
        limiterEnabled = snapshot.limiterEnabled
        limiterCeilingDB = snapshot.limiterCeilingDB
        autoStopClippingEnabled = snapshot.autoStopClippingEnabled
        volume = snapshot.volume
        applyStoredPresetSelection(
            builtInPresetName: snapshot.selectedBuiltInPresetName,
            customPresetID: snapshot.selectedCustomPresetID
        )
        isApplyingHistorySnapshot = false
    }

    private func recordHistorySnapshot(context: String) {
        guard !isLoadingProfile, !isApplyingHistorySnapshot else { return }

        let now = Date().timeIntervalSinceReferenceDate
        if context == lastHistoryContext, now - lastHistoryContextTime <= historyMergeWindow {
            return
        }

        let snapshot = makeHistorySnapshot()
        if let last = undoHistory.last, last == snapshot {
            return
        }

        undoHistory.append(snapshot)
        if undoHistory.count > maxHistoryDepth {
            undoHistory.removeFirst(undoHistory.count - maxHistoryDepth)
        }

        lastHistoryContext = context
        lastHistoryContextTime = now

        if !redoHistory.isEmpty {
            redoHistory.removeAll()
        }

        updateHistoryAvailability()
    }

    private func clearHistory() {
        undoHistory.removeAll()
        redoHistory.removeAll()
        lastHistoryContext = nil
        lastHistoryContextTime = 0
        updateHistoryAvailability()
    }

    private func clearCompareSnapshots() {
        compareSnapshotA = nil
        compareSnapshotB = nil
        hasCompareA = false
        hasCompareB = false
    }

    private func loadCompareSnapshot(_ snapshot: HistorySnapshot?, context: String) {
        guard let snapshot else { return }
        recordHistorySnapshot(context: context)
        applyHistorySnapshot(snapshot)
        updateHistoryAvailability()
    }

    private func updateHistoryAvailability() {
        canUndo = !undoHistory.isEmpty
        canRedo = !redoHistory.isEmpty
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
            settings.usePerDeviceVolume = usePerDeviceVolume
            settings.autoSaveEnabled = autoSaveEnabled

            if let preset = selectedBuiltInPreset {
                settings.selectedBuiltInPresetName = preset.rawValue
                settings.selectedCustomPresetID = nil
            } else if let preset = selectedCustomPreset {
                settings.selectedBuiltInPresetName = nil
                settings.selectedCustomPresetID = preset.id.uuidString
            } else if let pendingCustomPresetID {
                settings.selectedBuiltInPresetName = nil
                settings.selectedCustomPresetID = pendingCustomPresetID
            } else {
                settings.selectedBuiltInPresetName = nil
                settings.selectedCustomPresetID = nil
            }
        }
    }

    private func applyStoredPresetSelection(builtInPresetName: String?, customPresetID: String?) {
        if let builtInPresetName,
           let preset = BuiltInPreset(rawValue: builtInPresetName) {
            selectedBuiltInPreset = preset
            selectedCustomPreset = nil
            pendingCustomPresetID = nil
            return
        }

        if let customPresetID {
            selectedBuiltInPreset = nil
            selectedCustomPreset = nil
            pendingCustomPresetID = customPresetID
            return
        }

        clearPresetSelection()
    }

    private func loadSettings() {
        if let settings = settingsStore.load() {
            if !settings.parametricBands.isEmpty {
                parametricBands = settings.parametricBands
            }
            isEnabled = settings.isEnabled
            isEQFiltersEnabled = settings.isEQFiltersEnabled
            preGain = Self.clampPreGain(settings.preGain)
            outputGain = Self.clampOutputGain(settings.outputGain)
            limiterEnabled = settings.limiterEnabled
            limiterCeilingDB = settings.limiterCeilingDB
            autoStopClippingEnabled = settings.autoStopClippingEnabled
            volume = settings.volume
            usePerDeviceVolume = settings.usePerDeviceVolume
            autoSaveEnabled = settings.autoSaveEnabled

            if let presetName = settings.selectedBuiltInPresetName,
               let preset = BuiltInPreset(rawValue: presetName) {
                selectedBuiltInPreset = preset
                selectedCustomPreset = nil
                pendingCustomPresetID = nil
            } else if let customPresetID = settings.selectedCustomPresetID {
                selectedBuiltInPreset = nil
                selectedCustomPreset = nil
                pendingCustomPresetID = customPresetID
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

        // First launch should always start with processing enabled.
        isEnabled = true
        isEQFiltersEnabled = true
        preGain = Self.clampPreGain(UserDefaults.standard.object(forKey: legacyPreGainKey) as? Float ?? 0.0)
        outputGain = 0.0
        limiterEnabled = false
        limiterCeilingDB = -1.0
        autoStopClippingEnabled = UserDefaults.standard.object(forKey: legacyAutoStopClippingKey) as? Bool ?? false
        usePerDeviceVolume = true

        if let presetName = UserDefaults.standard.string(forKey: legacyBuiltInPresetKey),
           let preset = BuiltInPreset(rawValue: presetName) {
            selectedBuiltInPreset = preset
            selectedCustomPreset = nil
            pendingCustomPresetID = nil
        }

        // Migrate from legacy UserDefaults keys to JSON save file on first launch after upgrade.
        saveSettings()
    }

    private func profileVolumeForSave(deviceUID: String) -> Float {
        if usePerDeviceVolume {
            return volume
        }
        return profileManager.profile(for: deviceUID)?.volume ?? volume
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
