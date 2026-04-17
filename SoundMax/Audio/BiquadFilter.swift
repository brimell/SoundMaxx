import Foundation

/// Biquad filter for parametric EQ
/// Based on Audio EQ Cookbook by Robert Bristow-Johnson
class BiquadFilter {
    private var b0: Float = 1.0
    private var b1: Float = 0.0
    private var b2: Float = 0.0
    private var a1: Float = 0.0
    private var a2: Float = 0.0

    // State variables for filtering (per channel)
    private var x1: [Float] = [0, 0]  // x[n-1] for each channel
    private var x2: [Float] = [0, 0]  // x[n-2] for each channel
    private var y1: [Float] = [0, 0]  // y[n-1] for each channel
    private var y2: [Float] = [0, 0]  // y[n-2] for each channel

    var type: EQFilterType = .peak
    var frequency: Float = 1000
    var gain: Float = 0  // in dB
    var q: Float = 1.0
    var sampleRate: Float = 48000

    init() {}

    func configure(with band: EQBand, sampleRate: Float) {
        type = band.type
        frequency = band.frequency
        gain = band.gain
        q = band.q
        self.sampleRate = sampleRate
        updateCoefficients()
    }

    /// Calculate coefficients for the configured filter type.
    func updateCoefficients() {
        let limitedSampleRate = max(8000.0, sampleRate)
        let nyquist = (limitedSampleRate * 0.5) - 1.0
        let limitedFrequency = max(20.0, min(frequency, nyquist))
        let limitedQ = max(0.05, q)
        let limitedGain = max(-24.0, min(24.0, gain))

        let A = powf(10, limitedGain / 40.0)  // amplitude
        let omega = 2.0 * Float.pi * limitedFrequency / limitedSampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * limitedQ)
        let sqrtA = sqrt(A)

        var b0Raw: Float = 1.0
        var b1Raw: Float = 0.0
        var b2Raw: Float = 0.0
        var a0Raw: Float = 1.0
        var a1Raw: Float = 0.0
        var a2Raw: Float = 0.0

        switch type {
        case .peak:
            if abs(limitedGain) < 0.01 {
                // Bypass - unity gain
                b0 = 1.0
                b1 = 0.0
                b2 = 0.0
                a1 = 0.0
                a2 = 0.0
                return
            }

            b0Raw = 1.0 + alpha * A
            b1Raw = -2.0 * cosOmega
            b2Raw = 1.0 - alpha * A
            a0Raw = 1.0 + alpha / A
            a1Raw = -2.0 * cosOmega
            a2Raw = 1.0 - alpha / A

        case .lowShelf:
            if abs(limitedGain) < 0.01 {
                b0 = 1.0
                b1 = 0.0
                b2 = 0.0
                a1 = 0.0
                a2 = 0.0
                return
            }

            b0Raw = A * ((A + 1.0) - (A - 1.0) * cosOmega + 2.0 * sqrtA * alpha)
            b1Raw = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosOmega)
            b2Raw = A * ((A + 1.0) - (A - 1.0) * cosOmega - 2.0 * sqrtA * alpha)
            a0Raw = (A + 1.0) + (A - 1.0) * cosOmega + 2.0 * sqrtA * alpha
            a1Raw = -2.0 * ((A - 1.0) + (A + 1.0) * cosOmega)
            a2Raw = (A + 1.0) + (A - 1.0) * cosOmega - 2.0 * sqrtA * alpha

        case .highShelf:
            if abs(limitedGain) < 0.01 {
                b0 = 1.0
                b1 = 0.0
                b2 = 0.0
                a1 = 0.0
                a2 = 0.0
                return
            }

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

        // Normalize by a0
        b0 = b0Raw / safeA0
        b1 = b1Raw / safeA0
        b2 = b2Raw / safeA0
        a1 = a1Raw / safeA0
        a2 = a2Raw / safeA0
    }

    /// Process a single sample for a given channel
    func process(sample: Float, channel: Int) -> Float {
        let ch = min(channel, 1)

        // Direct Form II Transposed
        let output = b0 * sample + b1 * x1[ch] + b2 * x2[ch] - a1 * y1[ch] - a2 * y2[ch]

        // Update state
        x2[ch] = x1[ch]
        x1[ch] = sample
        y2[ch] = y1[ch]
        y1[ch] = output

        return output
    }

    /// Reset filter state
    func reset() {
        x1 = [0, 0]
        x2 = [0, 0]
        y1 = [0, 0]
        y2 = [0, 0]
    }
}

/// Multi-band parametric EQ using biquad filters
class ParametricEQ {
    private var filters: [BiquadFilter] = []
    private var activeBands: [EQBand] = []
    private var pendingBands: [EQBand]?
    private let updateLock = NSLock()
    private var sampleRate: Float = 48000
    var bypass: Bool = false

    init(sampleRate: Double, bands: [EQBand] = EQBand.defaultTenBand) {
        self.sampleRate = Float(sampleRate)
        applyBandsImmediately(bands)
    }

    func setBands(_ bands: [EQBand]) {
        updateLock.lock()
        pendingBands = bands
        updateLock.unlock()
    }

    func setGain(band: Int, gain: Float) {
        guard activeBands.indices.contains(band) else { return }
        var updated = activeBands
        updated[band].gain = gain
        setBands(updated)
    }

    func setAllGains(_ gains: [Float]) {
        var updated = activeBands
        for index in updated.indices where index < gains.count {
            updated[index].gain = gains[index]
        }
        setBands(updated)
    }

    /// Process audio buffer in place
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int) {
        guard !bypass else { return }

        applyPendingBandsIfNeeded()

        for frame in 0..<frameCount {
            var sample = buffer[frame]

            // Apply each enabled filter in series.
            for (filter, band) in zip(filters, activeBands) where band.isEnabled {
                sample = filter.process(sample: sample, channel: channel)
            }

            buffer[frame] = sample
        }
    }

    func reset() {
        for filter in filters {
            filter.reset()
        }
    }

    private func applyPendingBandsIfNeeded() {
        updateLock.lock()
        let nextBands = pendingBands
        pendingBands = nil
        updateLock.unlock()

        guard let nextBands else { return }
        applyBandsImmediately(nextBands)
    }

    private func applyBandsImmediately(_ bands: [EQBand]) {
        let normalizedBands = bands.isEmpty ? EQBand.defaultTenBand : bands

        if filters.count != normalizedBands.count {
            filters = normalizedBands.map { _ in BiquadFilter() }
            for filter in filters {
                filter.reset()
            }
        }

        activeBands = normalizedBands

        for index in activeBands.indices {
            filters[index].configure(with: activeBands[index], sampleRate: sampleRate)
        }
    }
}
