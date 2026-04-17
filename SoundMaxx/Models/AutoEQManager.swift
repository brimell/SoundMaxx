import Combine
import Foundation

// MARK: - AutoEQ Integration
// Fetches headphone correction curves from the AutoEQ project.
// https://github.com/jaakkopasanen/AutoEq

class AutoEQManager: ObservableObject {
    static let shared = AutoEQManager()

    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchResults: [AutoEQHeadphone] = []

    // Our 10 fixed frequency bands
    static let targetFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private let session: URLSession
    private var allHeadphones: [AutoEQHeadphone] = []
    private var currentQuery = ""
    private var hasLoadedIndex = false

    private init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Search

    func loadHeadphoneIndexIfNeeded(forceReload: Bool = false) {
        if hasLoadedIndex && !forceReload {
            return
        }

        fetchHeadphoneIndex()
    }

    func search(query: String) {
        currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !allHeadphones.isEmpty else {
            searchResults = []
            return
        }

        guard !currentQuery.isEmpty else {
            searchResults = allHeadphones
            return
        }

        let terms = currentQuery
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        searchResults = allHeadphones.filter { headphone in
            let haystack = [
                headphone.name,
                headphone.source,
                headphone.sourceVariant ?? "",
                headphone.type,
                headphone.sourceDisplayName,
            ]
            .joined(separator: " ")
            .lowercased()

            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: - Fetch EQ Data

    func fetchEQ(for headphone: AutoEQHeadphone, completion: @escaping (Result<AutoEQCurve, Error>) -> Void) {
        isLoading = true
        errorMessage = nil

        fetchText(at: headphone.parametricEQURL) { [weak self] parametricResult in
            guard let self = self else { return }

            switch parametricResult {
            case .success(let content):
                do {
                    let curve = try self.parseParametricEQ(content)
                    self.isLoading = false
                    completion(.success(curve))
                } catch {
                    self.fetchGraphicEQ(for: headphone, completion: completion)
                }

            case .failure:
                self.fetchGraphicEQ(for: headphone, completion: completion)
            }
        }
    }

    private func fetchGraphicEQ(for headphone: AutoEQHeadphone, completion: @escaping (Result<AutoEQCurve, Error>) -> Void) {
        fetchText(at: headphone.graphicEQURL) { [weak self] result in
            guard let self = self else { return }

            self.isLoading = false

            switch result {
            case .success(let content):
                do {
                    let curve = try self.parseGraphicEQ(content)
                    completion(.success(curve))
                } catch {
                    self.errorMessage = "Could not parse EQ data"
                    completion(.failure(error))
                }

            case .failure(let error):
                self.errorMessage = error.localizedDescription
                completion(.failure(error))
            }
        }
    }

    private func fetchText(at urlString: String, completion: @escaping (Result<String, Error>) -> Void) {

        guard let url = URL(string: urlString) else {
            completion(.failure(AutoEQError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.addValue("SoundMaxx", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(AutoEQError.invalidResponse))
                    return
                }

                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    let statusError: Error = httpResponse.statusCode == 404 ? AutoEQError.notFound : AutoEQError.invalidResponse
                    completion(.failure(statusError))
                    return
                }

                guard let data = data, let content = String(data: data, encoding: .utf8) else {
                    completion(.failure(AutoEQError.invalidResponse))
                    return
                }

                completion(.success(content))
            }
        }.resume()
    }

    // MARK: - AutoEQ Index

    private func fetchHeadphoneIndex() {
        isLoading = true
        errorMessage = nil

        guard let url = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/INDEX.md") else {
            isLoading = false
            errorMessage = "Invalid AutoEQ index URL"
            return
        }

        var request = URLRequest(url: url)
        request.addValue("text/plain", forHTTPHeaderField: "Accept")
        request.addValue("SoundMaxx", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }

                self.isLoading = false

                if let error = error {
                    self.errorMessage = "Could not load AutoEQ index: \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.errorMessage = "Invalid AutoEQ index response"
                    return
                }

                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    self.errorMessage = "Could not load AutoEQ index (\(httpResponse.statusCode))"
                    return
                }

                guard let data = data,
                      let content = String(data: data, encoding: .utf8) else {
                    self.errorMessage = "AutoEQ index response was empty"
                    return
                }

                let parsed = Self.makeHeadphones(fromIndexMarkdown: content)

                let unique = Dictionary(grouping: parsed, by: { $0.graphicEQPath })
                    .compactMap { $0.value.first }

                self.allHeadphones = unique.sorted(by: Self.sortHeadphones(_:_:))
                self.hasLoadedIndex = true
                self.search(query: self.currentQuery)

                if self.allHeadphones.isEmpty {
                    self.errorMessage = "No AutoEQ headphones were found"
                }
            }
        }.resume()
    }

    private static func makeHeadphones(fromIndexMarkdown content: String) -> [AutoEQHeadphone] {
        var headphones: [AutoEQHeadphone] = []

        for line in content.components(separatedBy: .newlines) {
            guard let relativePath = extractPathFromIndexLine(line) else {
                continue
            }

            let encodedComponents = relativePath
                .split(separator: "/")
                .map(String.init)

            guard encodedComponents.count >= 2 else {
                continue
            }

            let decodedComponents = encodedComponents.map { component in
                component.removingPercentEncoding ?? component
            }

            let source = decodedComponents[0]
            let name = decodedComponents[decodedComponents.count - 1]
            let middleSegments = Array(decodedComponents[1 ..< (decodedComponents.count - 1)])
            let type = detectType(in: middleSegments) ?? detectType(in: [name]) ?? "unknown"
            let sourceVariant = normalizeSourceVariant(middleSegments, detectedType: type)

            let folderPath = (["results"] + decodedComponents).joined(separator: "/")
            let graphicEQPath = "\(folderPath)/\(name) GraphicEQ.txt"

            headphones.append(
                AutoEQHeadphone(
                    name: name,
                    source: source,
                    type: type,
                    sourceVariant: sourceVariant,
                    graphicEQPath: graphicEQPath
                )
            )
        }

        return headphones
    }

    private static func extractPathFromIndexLine(_ line: String) -> String? {
        guard line.hasPrefix("- [") else {
            return nil
        }

        guard let markerRange = line.range(of: "](./") else {
            return nil
        }

        let pathStart = markerRange.upperBound
        guard let pathEnd = line[pathStart...].firstIndex(of: ")") else {
            return nil
        }

        let path = String(line[pathStart ..< pathEnd])
        return path.isEmpty ? nil : path
    }

    private static func sortHeadphones(_ lhs: AutoEQHeadphone, _ rhs: AutoEQHeadphone) -> Bool {
        if lhs.name.localizedCaseInsensitiveCompare(rhs.name) != .orderedSame {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        if lhs.source.localizedCaseInsensitiveCompare(rhs.source) != .orderedSame {
            return lhs.source.localizedCaseInsensitiveCompare(rhs.source) == .orderedAscending
        }

        if lhs.sourceVariant ?? "" != rhs.sourceVariant ?? "" {
            return (lhs.sourceVariant ?? "").localizedCaseInsensitiveCompare(rhs.sourceVariant ?? "") == .orderedAscending
        }

        return lhs.type.localizedCaseInsensitiveCompare(rhs.type) == .orderedAscending
    }

    private static func detectType(in segments: [String]) -> String? {
        let knownTypes = ["over-ear", "in-ear", "on-ear", "earbud"]

        for segment in segments {
            let lowercased = segment.lowercased()
            if let matched = knownTypes.first(where: { lowercased.contains($0) }) {
                return matched
            }
        }

        return nil
    }

    private static func normalizeSourceVariant(_ segments: [String], detectedType: String) -> String? {
        guard !segments.isEmpty else {
            return nil
        }

        let joined = segments.joined(separator: " / ")
        if joined.lowercased() == detectedType {
            return nil
        }

        return joined
    }

    // MARK: - Parse GraphicEQ Format

    private func parseParametricEQ(_ content: String) throws -> AutoEQCurve {
        let lines = content.components(separatedBy: .newlines)
        let preGain = parsePreamp(lines)

        let parsedBands = lines.compactMap { parseParametricFilterLine($0) }
        guard !parsedBands.isEmpty else {
            throw AutoEQError.parseError
        }

        return AutoEQCurve(
            bands: parsedBands.map { $0.gain },
            preGain: preGain,
            parametricBands: parsedBands
        )
    }

    private func parseParametricFilterLine(_ line: String) -> EQBand? {
        let tokens = line
            .replacingOccurrences(of: ":", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        guard !tokens.isEmpty else { return nil }

        let upperTokens = tokens.map { $0.uppercased() }
        guard upperTokens.first == "FILTER" else { return nil }

        var isEnabled = true
        var typeToken: String?

        if let stateIndex = upperTokens.firstIndex(where: { $0 == "ON" || $0 == "OFF" }) {
            isEnabled = upperTokens[stateIndex] == "ON"
            if upperTokens.indices.contains(stateIndex + 1) {
                typeToken = upperTokens[stateIndex + 1]
            }
        }

        if typeToken == nil {
            typeToken = upperTokens.first(where: {
                ["PK", "PEAK", "LS", "LSC", "LOWSHELF", "HS", "HSC", "HIGHSHELF", "LP", "LPF", "LOWPASS", "HP", "HPF", "HIGHPASS", "NO", "NOTCH", "BP", "BPF", "BANDPASS"].contains($0)
            })
        }

        guard let resolvedTypeToken = typeToken,
              let type = mapFilterType(token: resolvedTypeToken) else {
            return nil
        }

        guard let frequencyIndex = upperTokens.firstIndex(of: "FC"),
              upperTokens.indices.contains(frequencyIndex + 1),
              let frequency = parseFloatToken(tokens[frequencyIndex + 1]) else {
            return nil
        }

        var gain: Float = 0.0
        if let gainIndex = upperTokens.firstIndex(of: "GAIN"),
           upperTokens.indices.contains(gainIndex + 1),
           let parsedGain = parseFloatToken(tokens[gainIndex + 1]) {
            gain = parsedGain
        }

        var q: Float = 1.4
        if let qIndex = upperTokens.firstIndex(of: "Q"),
           upperTokens.indices.contains(qIndex + 1),
           let parsedQ = parseFloatToken(tokens[qIndex + 1]) {
            q = parsedQ
        }

        let limitedFrequency = min(max(frequency, 20.0), 20_000.0)
        let limitedGain = type.supportsGain ? min(max(gain, -24.0), 24.0) : 0.0
        let limitedQ = min(max(q, 0.2), 12.0)

        return EQBand(
            isEnabled: isEnabled,
            type: type,
            frequency: limitedFrequency,
            gain: limitedGain,
            q: limitedQ
        )
    }

    private func parseFloatToken(_ token: String) -> Float? {
        let cleaned = token
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Hz", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)

        return Float(cleaned)
    }

    private func mapFilterType(token: String) -> EQFilterType? {
        switch token.uppercased() {
        case "PK", "PEAK":
            return .peak
        case "LS", "LSC", "LOWSHELF":
            return .lowShelf
        case "HS", "HSC", "HIGHSHELF":
            return .highShelf
        case "LP", "LPF", "LOWPASS":
            return .lowPass
        case "HP", "HPF", "HIGHPASS":
            return .highPass
        case "NO", "NOTCH":
            return .notch
        case "BP", "BPF", "BANDPASS":
            return .bandPass
        default:
            return nil
        }
    }

    private func parseGraphicEQ(_ content: String) throws -> AutoEQCurve {
        // Format: GraphicEQ: 20 -3.5; 22 -3.5; 23 -3.4; ...
        let lines = content.components(separatedBy: .newlines)
        let preGain = parsePreamp(lines)
        guard let eqLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("GraphicEQ:") }) else {
            throw AutoEQError.parseError
        }

        let dataString = eqLine
            .replacingOccurrences(of: "GraphicEQ:", with: "")
            .trimmingCharacters(in: .whitespaces)

        let pairs = dataString.split(separator: ";", omittingEmptySubsequences: true)
        var frequencyGainMap: [(Double, Double)] = []

        for pair in pairs {
            let parts = pair
                .trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0.isWhitespace })

            if parts.count >= 2,
               let frequency = Double(parts[0]),
               let gain = Double(parts[1])
            {
                frequencyGainMap.append((frequency, gain))
            }
        }

        guard !frequencyGainMap.isEmpty else {
            throw AutoEQError.parseError
        }

        frequencyGainMap.sort { $0.0 < $1.0 }

        return AutoEQCurve(
            bands: interpolateToTargetBands(frequencyGainMap),
            preGain: preGain,
            parametricBands: nil
        )
    }

    private func parsePreamp(_ lines: [String]) -> Float {
        guard let preampLine = lines.first(where: { $0.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("preamp:") }) else {
            return 0.0
        }

        guard let separator = preampLine.firstIndex(of: ":") else { return 0.0 }

        let rawValue = preampLine[preampLine.index(after: separator)...]
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)

        guard let token = rawValue.split(whereSeparator: { $0.isWhitespace }).first,
              let preampValue = Float(token) else {
            return 0.0
        }

        return max(-24.0, min(24.0, preampValue))
    }

    // MARK: - Interpolation

    private func interpolateToTargetBands(_ data: [(Double, Double)]) -> [Float] {
        guard let firstPoint = data.first, let lastPoint = data.last else {
            return Array(repeating: 0, count: Self.targetFrequencies.count)
        }

        var result: [Float] = []

        for targetFrequency in Self.targetFrequencies {
            let gain: Double

            if targetFrequency <= firstPoint.0 {
                gain = firstPoint.1
            } else if targetFrequency >= lastPoint.0 {
                gain = lastPoint.1
            } else if let upperIndex = data.firstIndex(where: { $0.0 >= targetFrequency }) {
                let lower = data[upperIndex - 1]
                let upper = data[upperIndex]

                if lower.0 == upper.0 {
                    gain = lower.1
                } else {
                    // Interpolate in log-frequency space for perceptual consistency.
                    let logLower = log10(lower.0)
                    let logUpper = log10(upper.0)
                    let logTarget = log10(targetFrequency)
                    let ratio = (logTarget - logLower) / (logUpper - logLower)
                    gain = lower.1 + ratio * (upper.1 - lower.1)
                }
            } else {
                gain = lastPoint.1
            }

            // Clamp to our ±12 dB range.
            result.append(Float(max(-12, min(12, gain))))
        }

        return result
    }
}

// MARK: - Models

struct AutoEQHeadphone: Identifiable, Hashable {
    let id: String
    let name: String
    let source: String
    let type: String // over-ear, in-ear, on-ear, earbud, unknown
    let sourceVariant: String?
    let graphicEQPath: String // Full path in the AutoEq repository

    init(name: String, source: String, type: String, sourceVariant: String? = nil, graphicEQPath: String) {
        self.name = name
        self.source = source
        self.type = type
        self.sourceVariant = sourceVariant
        self.graphicEQPath = graphicEQPath
        self.id = graphicEQPath
    }

    var graphicEQURL: String {
        let encodedPath = graphicEQPath
            .split(separator: "/")
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
            }
            .joined(separator: "/")

        return "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/\(encodedPath)"
    }

    var parametricEQPath: String {
        graphicEQPath.replacingOccurrences(of: " GraphicEQ.txt", with: " ParametricEQ.txt")
    }

    var parametricEQURL: String {
        let encodedPath = parametricEQPath
            .split(separator: "/")
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
            }
            .joined(separator: "/")

        return "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/\(encodedPath)"
    }

    var displayType: String {
        switch type {
        case "over-ear": return "Over-ear"
        case "in-ear": return "In-ear"
        case "on-ear": return "On-ear"
        case "earbud": return "Earbud"
        default: return "Unknown"
        }
    }

    var sourceDisplayName: String {
        guard let sourceVariant, !sourceVariant.isEmpty else {
            return source
        }

        return "\(source) / \(sourceVariant)"
    }
}

struct AutoEQCurve {
    let bands: [Float]
    let preGain: Float
    let parametricBands: [EQBand]?
}

// MARK: - Errors

enum AutoEQError: LocalizedError {
    case invalidURL
    case invalidResponse
    case notFound
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response from server"
        case .notFound: return "EQ data not found for this headphone"
        case .parseError: return "Could not parse EQ data"
        }
    }
}
