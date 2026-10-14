import AppKit
import os

/// Tells you when a newer Onword is on GitHub (the Settings sidebar footer). Only reads the public
/// "latest release" of h-thavy/onword; sends nothing about you.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private static let releases = URL(string: "https://github.com/h-thavy/onword/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/h-thavy/onword/releases/latest")!

    enum State: Equatable { case unknown, checking, upToDate, available(String) }
    @Published private(set) var state: State = .unknown
    private var lastCheck = Date.distantPast
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "updates")

    /// Checks unless it did within the last hour.
    func checkIfStale() {
        if Date().timeIntervalSince(lastCheck) > 3600 { check() }
    }

    func check() {
        guard state != .checking else { return }
        state = .checking
        lastCheck = Date()
        Task {
            var request = URLRequest(url: Self.api, timeoutInterval: 10)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let tag = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String ?? ""
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                state = Self.isNewer(latest, than: Self.currentVersion) ? .available(latest) : .upToDate
            } catch {
                log.notice("Update check failed: \(error.localizedDescription, privacy: .public)")
                state = .unknown
            }
        }
    }

    /// Opens the release page, which has the one-line install command that updates in place.
    func openRelease() {
        NSWorkspace.shared.open(Self.releases)
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
