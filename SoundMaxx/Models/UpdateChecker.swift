import Foundation
import AppKit

@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    enum State {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, dmgURL: URL)
        case failed
    }

    enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double)
        case openingInstaller
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var downloadState: DownloadState = .idle

    private static let apiURL = URL(string: "https://api.github.com/repos/brimell/SoundMax/releases/latest")!
    private static let checkInterval: TimeInterval = 3600
    private static let dmgAssetName = "SoundMaxx-Installer.dmg"

    private var timer: Timer?
    private var downloadSession: URLSession?

    func startPeriodicChecks() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.check() }
        }
    }

    func check() async {
        state = .checking
        do {
            var request = URLRequest(url: Self.apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            guard Self.isNewer(latestVersion, than: currentVersion) else {
                state = .upToDate
                return
            }
            let dmgURL = release.assets
                .first { $0.name == Self.dmgAssetName }
                .flatMap { URL(string: $0.browserDownloadURL) }
                ?? URL(string: "https://github.com/brimell/SoundMax/releases/download/\(release.tagName)/\(Self.dmgAssetName)")!
            state = .updateAvailable(version: latestVersion, dmgURL: dmgURL)
        } catch {
            state = .failed
        }
    }

    func downloadAndInstall(from dmgURL: URL) {
        downloadState = .downloading(progress: 0)
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        downloadSession = session
        session.downloadTask(with: dmgURL).resume()
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(candidateParts.count, currentParts.count)
        for i in 0..<maxLen {
            let c = i < candidateParts.count ? candidateParts[i] : 0
            let cur = i < currentParts.count ? currentParts[i] : 0
            if c != cur { return c > cur }
        }
        return false
    }
}

extension UpdateChecker: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UpdateChecker.dmgAssetName)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)
        Task { @MainActor in
            self.downloadState = .openingInstaller
            NSWorkspace.shared.open(dest)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.downloadState = .idle
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor in
            self.downloadState = .downloading(progress: progress)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard error != nil else { return }
        Task { @MainActor in
            self.downloadState = .failed
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}
