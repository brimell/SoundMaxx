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
            // Keep the default list bounded for a responsive UI.
            searchResults = Array(allHeadphones.prefix(300))
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

    func fetchEQ(for headphone: AutoEQHeadphone, completion: @escaping (Result<[Float], Error>) -> Void) {
        isLoading = true
        errorMessage = nil

        let urlString = headphone.graphicEQURL
        guard let url = URL(string: urlString) else {
            isLoading = false
            errorMessage = "Invalid URL"
            completion(.failure(AutoEQError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.addValue("SoundMax", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    self?.errorMessage = error.localizedDescription
                    completion(.failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.errorMessage = "Invalid response from server"
                    completion(.failure(AutoEQError.invalidResponse))
                    return
                }

                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    if httpResponse.statusCode == 404 {
                        self?.errorMessage = "EQ data not found for this headphone"
                        completion(.failure(AutoEQError.notFound))
                    } else {
                        self?.errorMessage = "AutoEQ server error (\(httpResponse.statusCode))"
                        completion(.failure(AutoEQError.invalidResponse))
                    }
                    return
                }

                guard let data = data, let content = String(data: data, encoding: .utf8) else {
                    self?.errorMessage = "Could not read response"
                    completion(.failure(AutoEQError.invalidResponse))
                    return
                }

                do {
                    let bands = try self?.parseGraphicEQ(content) ?? []
                    completion(.success(bands))
                } catch {
                    self?.errorMessage = "Could not parse EQ data"
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    // MARK: - AutoEQ Index

    private func fetchHeadphoneIndex() {
        isLoading = true
        errorMessage = nil

        guard let url = URL(string: "https://api.github.com/repos/jaakkopasanen/AutoEq/git/trees/master?recursive=1") else {
            isLoading = false
            errorMessage = "Invalid AutoEQ index URL"
            return
        }

        var request = URLRequest(url: url)
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.addValue("SoundMax", forHTTPHeaderField: "User-Agent")

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

                guard let data = data else {
                    self.errorMessage = "AutoEQ index response was empty"
                    return
                }

                do {
                    let payload = try JSONDecoder().decode(GitTreeResponse.self, from: data)
                    let parsed = payload.tree.compactMap(Self.makeHeadphone(from:))

                    let unique = Dictionary(grouping: parsed, by: { $0.graphicEQPath })
                        .compactMap { $0.value.first }

                    self.allHeadphones = unique.sorted(by: Self.sortHeadphones(_:_:))
                    self.hasLoadedIndex = true
                    self.search(query: self.currentQuery)

                    if self.allHeadphones.isEmpty {
                        self.errorMessage = "No AutoEQ headphones were found"
                    }
                } catch {
                    self.errorMessage = "Could not parse AutoEQ index"
                }
            }
        }.resume()
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

    private static func makeHeadphone(from treeItem: GitTreeItem) -> AutoEQHeadphone? {
        guard treeItem.type == "blob" else {
            return nil
        }

        guard treeItem.path.hasPrefix("results/") else {
            return nil
        }

        guard treeItem.path.hasSuffix(" GraphicEQ.txt") else {
            return nil
        }

        let components = treeItem.path.split(separator: "/").map(String.init)
        guard components.count >= 4, components[0] == "results" else {
            return nil
        }

        let source = components[1]
        let name = components[components.count - 2]
        let middleSegments = Array(components[2 ..< (components.count - 2)])
        let type = detectType(in: middleSegments) ?? detectType(in: [name]) ?? "unknown"
        let sourceVariant = normalizeSourceVariant(middleSegments, detectedType: type)

        return AutoEQHeadphone(
            name: name,
            source: source,
            type: type,
            sourceVariant: sourceVariant,
            graphicEQPath: treeItem.path
        )
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

    private func parseGraphicEQ(_ content: String) throws -> [Float] {
        // Format: GraphicEQ: 20 -3.5; 22 -3.5; 23 -3.4; ...
        let lines = content.components(separatedBy: .newlines)
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

        return interpolateToTargetBands(frequencyGainMap)
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

private struct GitTreeResponse: Decodable {
    let tree: [GitTreeItem]
}

private struct GitTreeItem: Decodable {
    let path: String
    let type: String
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
