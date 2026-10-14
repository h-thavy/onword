import AppKit
import CryptoKit
import os

/// Keeps Onword up to date from GitHub releases: checks the public "latest release" of h-thavy/onword
/// (sending nothing about you) and, with one click, downloads it, verifies its checksum and signature,
/// swaps the app in place and relaunches.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    /// Test hook: ONWORD_TEST_VERSION=0.9.0 pretends this is an older version, to try the update flow.
    static let currentVersion = ProcessInfo.processInfo.environment["ONWORD_TEST_VERSION"]
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private static let repo = "h-thavy/onword"
    private static let releases = URL(string: "https://github.com/\(repo)/releases/latest")!

    enum State: Equatable {
        case unknown, checking, upToDate, available(String)
        /// Downloading the new version (0…1).
        case downloading(String, Double)
        case installing(String)
        case failed(String)
    }
    @Published private(set) var state: State = .unknown
    private var lastCheck = Date.distantPast
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "updates")

    /// The newer version on GitHub, if one is available.
    var availableVersion: String? {
        if case .available(let version) = state { return version }
        return nil
    }

    /// Checks unless it did within `maxAge` seconds (opening Settings checks if the last look is over a minute old).
    func checkIfStale(maxAge: TimeInterval = 60) {
        if Date().timeIntervalSince(lastCheck) > maxAge { check() }
    }

    func check() {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        lastCheck = Date()
        Task {
            // github.com/…/releases/latest redirects to …/releases/tag/vX.Y.Z. Unlike the GitHub API it has no
            // 60-requests-an-hour limit per network.
            var request = URLRequest(url: Self.releases, timeoutInterval: 10)
            request.httpMethod = "HEAD"
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let tag = response.url?.lastPathComponent ?? ""
                guard tag.hasPrefix("v"), (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError("no release found")
                }
                let latest = String(tag.dropFirst())
                state = Self.isNewer(latest, than: Self.currentVersion) ? .available(latest) : .upToDate
                log.notice("Update check: latest \(latest, privacy: .public), this \(Self.currentVersion, privacy: .public)")
                if case .available = state, ProcessInfo.processInfo.environment["ONWORD_TEST_AUTOUPDATE"] != nil { update() }
            } catch {
                log.notice("Update check failed: \(error.localizedDescription, privacy: .public)")
                state = .unknown
            }
        }
    }

    /// Opens the release page (what's new).
    func openRelease() {
        NSWorkspace.shared.open(Self.releases)
    }

    // MARK: - One-click update

    /// Downloads the new release, checks it, replaces this app and relaunches.
    func update() {
        guard let version = availableVersion else { return }
        state = .downloading(version, 0)
        Task {
            do {
                let app = try await download(version)
                state = .installing(version)
                try install(app)
            } catch {
                log.error("Update failed: \(error.localizedDescription, privacy: .public)")
                state = .failed("Couldn’t update: \(error.localizedDescription)")
            }
        }
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Downloads and unpacks the release zip, verifying its SHA-256 and the app's code signature.
    private func download(_ version: String) async throws -> URL {
        let base = URL(string: "https://github.com/\(Self.repo)/releases/download/v\(version)")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OnwordUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let (checksumData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("Onword.zip.sha256"))
        let expected = String(decoding: checksumData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init) ?? ""

        let zip = try await downloadWithProgress(base.appendingPathComponent("Onword.zip"), version: version)
        let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, actual == expected else { throw UpdateError("the download didn’t match its checksum") }

        let unpacked = folder.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let app = unpacked.appendingPathComponent("Onword.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError("the download had no Onword.app") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    private func downloadWithProgress(_ url: URL, version: String) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("the download wasn’t found") }
        let total = max(1, response.expectedContentLength)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Onword-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                state = .downloading(version, Double(received) / Double(total))
            }
        }
        try handle.write(contentsOf: buffer)
        return destination
    }

    /// Hands off to a tiny script that waits for Onword to quit, swaps the bundle and opens the new one.
    private func install(_ newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("Onword can’t write to \(parent.path). Run the install command instead.")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let backup = parent.appendingPathComponent(".Onword-previous.app")
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(backup.path)"
        mv "\(current.path)" "\(backup.path)" || exit 1
        if /usr/bin/ditto "\(newApp.path)" "\(current.path)"; then
          rm -rf "\(backup.path)"
        else
          rm -rf "\(current.path)"; mv "\(backup.path)" "\(current.path)"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "\(current.path)" 2>/dev/null
        /usr/bin/open "\(current.path)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()   // keeps running after Onword quits
        log.notice("Installing update; relaunching")
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed") }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

/// Quits Onword and opens it again.
enum AppRelaunch {
    @MainActor static func now() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                             Bundle.main.bundlePath]
        try? process.run()   // keeps running after Onword quits
        NSApp.terminate(nil)
    }
}
