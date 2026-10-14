import AppKit
import Foundation
import OnwordCore

/// Everything Onword keeps lives in ~/Library/Application Support/Onword.
/// Dictations are stored as text only (no audio, no screenshots). Meetings keep their audio so they can
/// be re-processed; delete a meeting to delete its audio.
enum AppPaths {
    static let root: URL = {
        // Test hook: ONWORD_TEST_DATA=/folder uses that folder instead (sample meetings for snapshots).
        if let test = ProcessInfo.processInfo.environment["ONWORD_TEST_DATA"] {
            let url = URL(fileURLWithPath: test, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Onword", isDirectory: true)
        // The app used to be called FlowLite: carry its history, notes, meetings and models over once.
        let legacy = base.appendingPathComponent("FlowLite", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: url)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Settings saved under the old bundle ID (com.flowlite.app), copied once into Onword's.
    static func migrateLegacySettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromFlowLite"),
              let legacy = UserDefaults(suiteName: "com.flowlite.app") else { return }
        for key in ["hotkey", "model", "language", "removeFillers", "microphoneUID", "meetingDetection", "appearance"]
        where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromFlowLite")
    }

    static let models = root.appendingPathComponent("Models", isDirectory: true)
    static let meetings = folder("Meetings")
    static let notes = folder("Notes")

    private static func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static let dictionary = root.appendingPathComponent("dictionary.json")
    static let history = root.appendingPathComponent("history.jsonl")

    /// Creates an example dictionary the first time so the user has something to edit.
    static func ensureDictionary() {
        guard !FileManager.default.fileExists(atPath: dictionary.path) else { return }
        try? UserDictionary.example.save(to: dictionary)
    }
}

struct HistoryEntry: Codable {
    var date: Date
    var app: String?
    var raw: String
    var text: String
    var seconds: Double
    var transcribeMs: Int
    var method: TextInserter.Method
}

extension Notification.Name {
    static let historyChanged = Notification.Name("Onword.historyChanged")
}

/// How long dictation history is kept (Settings › Data and Privacy).
enum HistoryRetention: String, CaseIterable, Identifiable {
    case keep, day, never
    static let key = "historyRetention"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keep: "Store data locally"
        case .day: "Auto-delete every 24 hours"
        case .never: "Never store data"
        }
    }
    static var current: HistoryRetention {
        HistoryRetention(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .keep
    }
}

enum History {
    /// Applies the retention setting: deletes everything ("never") or entries older than a day.
    static func prune() {
        defer { NotificationCenter.default.post(name: .historyChanged, object: nil) }
        switch HistoryRetention.current {
        case .keep: return
        case .never: try? FileManager.default.removeItem(at: AppPaths.history)
        case .day:
            guard let data = try? Data(contentsOf: AppPaths.history) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            let kept = data.split(separator: 0x0A).filter { line in
                (try? decoder.decode(HistoryEntry.self, from: Data(line)))?.date ?? .distantPast > cutoff
            }
            var output = Data(kept.joined(separator: [0x0A]))
            if !output.isEmpty { output.append(0x0A) }
            try? output.write(to: AppPaths.history, options: .atomic)
        }
    }

    static func append(_ entry: HistoryEntry) {
        defer { NotificationCenter.default.post(name: .historyChanged, object: nil) }
        guard HistoryRetention.current != .never else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: AppPaths.history) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: AppPaths.history, options: .atomic)
        }
    }
}

/// The user's name, asked for during setup and shown in greetings and meeting notes.
enum UserProfile {
    static let key = "userName"

    static var name: String? {
        get {
            let value = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        set { UserDefaults.standard.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key) }
    }

    /// The first name of the Mac's account, as a suggestion in setup.
    static var suggestedName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }
}
