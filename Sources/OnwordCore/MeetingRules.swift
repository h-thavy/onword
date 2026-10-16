import Foundation

/// Which call app a meeting is on. Detection rules: a native meeting app using the
/// microphone is enough on its own; a browser or chat app also needs a window that looks like a call.
public enum MeetingPlatform: String, Codable, CaseIterable, Sendable {
    case zoom, googleMeet, teams, slack, facetime, webex, discord

    public var title: String {
        switch self {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .slack: "Slack huddle"
        case .facetime: "FaceTime"
        case .webex: "Webex"
        case .discord: "Discord"
        }
    }
}

public enum MeetingRules {
    /// Apps that are only ever on the mic for calls.
    static let nativeMeetingApps: [String: MeetingPlatform] = [
        "us.zoom.xos": .zoom,
        "com.microsoft.teams2": .teams,
        "com.microsoft.teams": .teams,
        "com.apple.FaceTime": .facetime,
        "com.cisco.webexmeetingsapp": .webex,
        "Cisco-Systems.Spark": .webex,
        "com.hnc.Discord": .discord,
    ]

    /// Apps that use the mic for many things; they also need a call-like window title.
    public static let browsersAndChat: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac", "com.apple.Safari",
        "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
        "ai.perplexity.comet", "com.tinyspeck.slackmacgap",
    ]

    /// - Parameters:
    ///   - bundleID: the app currently using the microphone
    ///   - windowTitles: that app's window titles (only needed for browsers and Slack)
    public static func platform(bundleID: String, windowTitles: [String]) -> MeetingPlatform? {
        if let platform = nativeMeetingApps[bundleID] { return platform }
        guard browsersAndChat.contains(bundleID) else { return nil }
        for title in windowTitles {
            if let platform = platform(forWindowTitle: title, isSlack: bundleID == "com.tinyspeck.slackmacgap") {
                return platform
            }
        }
        return nil
    }

    public static func platform(forWindowTitle title: String, isSlack: Bool = false) -> MeetingPlatform? {
        let t = title.lowercased()
        if isSlack { return t.contains("huddle") ? .slack : nil }
        if t.hasPrefix("meet - ") || t.hasPrefix("meet – ") || t.contains("meet.google.com") { return .googleMeet }
        if t.contains("microsoft teams") || t.contains("teams.microsoft.com") || t.contains("teams.live.com") { return .teams }
        if t.contains("zoom meeting") || t.contains("app.zoom.us") || t.contains("zoom.us/wc") { return .zoom }
        if t.contains("huddle") && t.contains("slack") { return .slack }
        return nil
    }
}

/// Who the meeting app showed as speaking at a moment during the recording.
public struct SpeakerObservation: Codable, Equatable {
    /// Seconds since the recording started (same clock as transcript segments).
    public var t: Double
    public var speaking: [String]

    public init(t: Double, speaking: [String]) {
        self.t = t
        self.speaking = speaking
    }
}

public enum SpeakerNames {
    /// Tidies names read from meeting UIs: "Dara Sok (Host)" → "Dara Sok", "Sam, active speaker" → "Sam".
    public static func clean(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(
            of: #",?\s*(active speaker|is speaking|speaking|computer audio (un)?muted|(un)?muted).*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        name = name.replacingOccurrences(
            of: #"\s*\((host|co-host|organi[sz]er|co-organi[sz]er|presenter|attendee|guest|meeting guest|me|you)\)\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        name = name.replacingOccurrences(
            of: #",\s*(organi[sz]er|co-organi[sz]er|meeting guest|presenter|attendee)$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The user's own tile ("You", "Me"), which belongs to the "me" track instead.
    public static func isSelf(_ name: String) -> Bool {
        ["you", "me", "(you)", "(me)"].contains(name.lowercased())
    }

    /// Plausible display name: 2–60 characters, contains a letter, not a timer or a UI word.
    public static func isPlausible(_ name: String) -> Bool {
        guard (2...60).contains(name.count), name.contains(where: \.isLetter) else { return false }
        let ui: Set<String> = ["mute", "unmute", "more options", "pin", "presentation", "camera", "microphone", "chat", "leave call"]
        return !ui.contains(name.lowercased())
    }

    /// Gives diarized speakers ("s1", "s2"…) real names from the meeting app's active-speaker indicator.
    ///
    /// Each observation that falls inside a segment and shows exactly one (non-self) person speaking is a
    /// vote for that person. A speaker gets a name with ≥ `minVotes` votes that make up ≥ `minShare` of
    /// its votes. Only observations within
    /// `tolerance` seconds of the segment count.
    public static func assign(segments: [TranscriptSegment], observations: [SpeakerObservation],
                              minVotes: Int = 3, minShare: Double = 0.6, tolerance: Double = 0.75) -> [String: String] {
        let sorted = observations.sorted { $0.t < $1.t }
        var votes: [String: [String: Int]] = [:]

        for segment in segments where segment.speaker != "me" {
            for observation in sorted where observation.t >= segment.start - tolerance && observation.t <= segment.end + tolerance {
                let people = observation.speaking.map(clean).filter { !isSelf($0) && isPlausible($0) }
                guard Set(people).count == 1, let person = people.first else { continue }
                votes[segment.speaker, default: [:]][person, default: 0] += 1
            }
        }

        var result: [String: String] = [:]
        for (speaker, counts) in votes {
            let total = counts.values.reduce(0, +)
            guard let (name, count) = counts.max(by: { $0.value < $1.value }),
                  count >= minVotes, Double(count) / Double(total) >= minShare else { continue }
            result[speaker] = name
        }
        return result
    }
}

/// Guards against language models inventing to-dos: an action item is kept only if its supporting quote
/// really appears in the transcript, says something like a commitment, and fits the named owner.
public enum ActionItemCheck {
    public struct Line {
        public var speaker: String
        public var text: String
        public init(speaker: String, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    static let commitment = try! NSRegularExpression(pattern: [
        #"\bI(?:'ll| will| am going to|'m going to| can| need to| have to)\b"#,
        #"\bwe(?:'ll| will| need to| have to| should)\b"#,
        #"\b(?:can|could|would|will) you\b"#, #"\bplease\b"#, #"\blet me\b"#, #"\baction item\b"#, #"\bto-?do\b"#,
        #"\bby (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|tonight|today|next week|end of)"#,
    ].joined(separator: "|"), options: .caseInsensitive)

    static let stopwords: Set<String> = ["the", "a", "an", "and", "or", "to", "of", "for", "on", "in", "it", "is",
                                         "i", "we", "you", "will", "be", "by", "this", "that", "them", "with", "at"]

    public static func isGrounded(quote: String, owner: String?, lines: [Line]) -> Bool {
        let quoteWords = contentWords(quote)
        guard quoteWords.count >= 2 else { return false }

        // The transcript line the quote came from.
        let scored = lines.map { line -> (Line, Double) in
            let words = Set(contentWords(line.text))
            return (line, Double(quoteWords.filter(words.contains).count) / Double(quoteWords.count))
        }
        guard let (line, overlap) = scored.max(by: { $0.1 < $1.1 }), overlap >= 0.6 else { return false }

        let text = line.text
        guard commitment.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }

        // The owner said it ("I'll…"), or was asked by name ("Dara, can you…").
        if let owner = owner?.trimmingCharacters(in: .whitespaces), !owner.isEmpty {
            let first = owner.split(separator: " ").first.map(String.init) ?? owner
            let sameSpeaker = line.speaker.caseInsensitiveCompare(owner) == .orderedSame
                || line.speaker.lowercased().hasPrefix(first.lowercased())
            let named = text.range(of: first, options: .caseInsensitive) != nil
            // An unnamed voice ("Speaker 3") could be that person: nothing contradicts the owner.
            let unnamed = line.speaker.range(of: #"^(Speaker \d+|Unknown|S\d+)$"#, options: [.regularExpression, .caseInsensitive]) != nil
            return sameSpeaker || named || unnamed
        }
        return true
    }

    static func contentWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init).filter { !stopwords.contains($0) && $0.count > 1 }
    }
}

/// Finds the video-call link in a calendar event (its URL, location or notes).
public enum MeetingLink {
    static let patterns: [(MeetingPlatform, String)] = [
        (.googleMeet, #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#),
        (.zoom, #"https://(?:[\w-]+\.)?zoom\.us/(?:j|my|w)/[\w?=&.\-/]+"#),
        (.teams, #"https://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s<>"]+"#),
        (.webex, #"https://[\w-]+\.webex\.com/[^\s<>"]+"#),
        (.slack, #"https://app\.slack\.com/huddle/[^\s<>"]+"#),
        (.facetime, #"https://facetime\.apple\.com/join[^\s<>"]+"#),
    ]

    /// The first call link found, searching the given texts in order.
    public static func find(in texts: [String?]) -> (url: URL, platform: MeetingPlatform)? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            for (platform, pattern) in patterns {
                if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                   let url = URL(string: String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>"))) {
                    return (url, platform)
                }
            }
        }
        return nil
    }
}

/// An app whose use of the microphone may mean a call (Wispr Flow's table, plus Opera GX).
public struct CallApp: Equatable, Sendable {
    public enum Kind: Sendable { case meetingApp, browser, chat }
    public let name: String
    public let kind: Kind
    /// For meeting apps, the platform it is; browsers and chat apps get theirs from the page or window.
    public let platform: MeetingPlatform?
}

extension MeetingRules {
    /// Bundle ID (lower-case) → app. Any of these taking the mic shows "Meeting detected".
    static let callApps: [String: CallApp] = {
        func app(_ name: String, _ kind: CallApp.Kind, _ platform: MeetingPlatform? = nil, _ ids: [String]) -> [(String, CallApp)] {
            ids.map { ($0, CallApp(name: name, kind: kind, platform: platform)) }
        }
        let rows: [[(String, CallApp)]] = [
            app("FaceTime", .meetingApp, .facetime, ["com.apple.facetime", "com.apple.avconferenced"]),
            app("Webex", .meetingApp, .webex, ["com.cisco.webexmeetingsapp", "cisco-systems.spark"]),
            app("Dialpad Meetings", .meetingApp, nil, ["com.electron.uberconference"]),
            app("Gather", .meetingApp, nil, ["com.gather.gather"]),
            app("Lark", .meetingApp, nil, ["com.larksuite.larkapp"]),
            app("Microsoft Teams", .meetingApp, .teams, ["com.microsoft.teams", "com.microsoft.teams2", "com.microsoft.teams2.modulehost"]),
            app("VooV Meeting", .meetingApp, nil, ["com.tencent.tencentmeeting"]),
            app("Zoom", .meetingApp, .zoom, ["us.zoom.xos"]),
            app("Arc", .browser, nil, ["company.thebrowser.browser"]),
            app("Dia", .browser, nil, ["company.thebrowser.dia"]),
            app("ChatGPT Atlas", .browser, nil, ["com.openai.atlas"]),
            app("Brave", .browser, nil, ["com.brave.browser"]),
            app("Chrome", .browser, nil, ["com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary",
                                           "com.google.chrome.dev", "org.chromium.chromium"]),
            app("Comet", .browser, nil, ["ai.perplexity.comet"]),
            app("Microsoft Edge", .browser, nil, ["com.microsoft.edgemac"]),
            app("Firefox", .browser, nil, ["org.mozilla.firefox"]),
            app("Opera", .browser, nil, ["com.operasoftware.opera"]),
            app("Opera GX", .browser, nil, ["com.operasoftware.operagx"]),
            app("Safari", .browser, nil, ["com.apple.safari", "com.apple.webkit.gpu"]),
            app("Vivaldi", .browser, nil, ["com.vivaldi.vivaldi"]),
            app("Zen Browser", .browser, nil, ["app.zen-browser.zen"]),
            app("Slack", .chat, nil, ["com.tinyspeck.slackmacgap"]),
            app("Discord", .chat, nil, ["com.hnc.discord"]),
            app("WhatsApp", .chat, nil, ["net.whatsapp.whatsapp"]),
            app("Aircall", .chat, nil, ["io.aircall.phone", "io.aircall.workspace"]),
            app("Dialpad", .chat, nil, ["com.electron.dialpad"]),
            app("ClickUp", .chat, nil, ["com.clickup.desktop-app"]),
            app("Tuple", .chat, nil, ["app.tuple.app"]),
        ]
        return Dictionary(rows.flatMap { $0 }, uniquingKeysWith: { first, _ in first })
    }()

    /// The call app for a mic holder's bundle ID; helper processes ("….helper", "….helper.renderer") count as
    /// their app.
    public static func callApp(bundleID: String) -> CallApp? {
        var id = bundleID.trimmingCharacters(in: .whitespaces).lowercased()
        if let app = callApps[id] { return app }
        for suffix in [".helper.renderer", ".helper.plugin", ".helper.gpu", ".web.helper", ".helper"] where id.hasSuffix(suffix) {
            id.removeLast(suffix.count)
            return callApps[id]
        }
        return nil
    }

    /// The meeting platform of a page address (Google Meet, Zoom's web client, Teams, Webex, a Slack huddle,
    /// a Discord voice channel).
    public static func platform(forURL url: String) -> MeetingPlatform? {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased(),
              ["https", "http"].contains(components.scheme?.lowercased() ?? "") else { return nil }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        let path = components.path.lowercased()
        if on("meet.google.com") { return .googleMeet }
        if on("zoom.us") || on("zoomgov.com") { return .zoom }
        if on("teams.microsoft.com") || on("teams.live.com") { return .teams }
        if on("webex.com") { return .webex }
        if on("slack.com"), path.contains("/huddle/") { return .slack }
        if on("discord.com"), path.hasPrefix("/channels/") { return .discord }
        return nil
    }

    /// The meeting's code in a Google Meet or Zoom address ("abc-defg-hij", "84512345678"), to find its
    /// calendar event.
    public static func meetingCode(inURL url: String) -> String? {
        let text = url.lowercased()
        let patterns = [#"meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})"#,
                        #"(?:zoom\.us|zoomgov\.com)/(?:j|s|wc/join)/(\d+)"#, #"(?:zoom\.us|zoomgov\.com)/wc/(\d+)/(?:join|start)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }

    /// Whether a detected call may start the Notetaker by itself ("Start automatically"): a meeting app, a
    /// browser on a Meet/Teams/Zoom page, a Slack huddle, or a call matched to a calendar event (not browsers).
    public static func mayAutoStart(_ app: CallApp, pagePlatform: MeetingPlatform?, calendarMatched: Bool) -> Bool {
        switch app.kind {
        case .meetingApp: return true
        case .browser: return [.googleMeet, .teams, .zoom].contains(pagePlatform)
        case .chat: return pagePlatform == .slack || calendarMatched
        }
    }
}

/// Whether you're muted in the call app, read from its controls' accessibility labels.
public enum CallMuteState: Sendable { case muted, unmuted, unknown }

extension MeetingRules {
    /// The mute state from a call app's labels. Zoom's and Google Meet's own wording comes first (the labels
    /// Wispr Flow's helper reads); a button that starts with "Unmute" / "Mute" (Teams) is the fallback, as
    /// "Mute" buttons next to other people (Zoom's participant list) would otherwise mislead.
    public static func muteState(labels: [String]) -> CallMuteState {
        let texts = labels.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        for text in texts {
            if text.contains("currently unmuted") || text == "computer audio unmuted" || text.contains("your microphone is on")
                || text.hasPrefix("turn off microphone") { return .unmuted }
            if text.contains("currently muted") || text == "computer audio muted" || text.contains("your microphone is off")
                || text.hasPrefix("turn on microphone") { return .muted }
        }
        for text in texts {
            if text.hasPrefix("unmute") { return .muted }
            if text == "mute" || text.hasPrefix("mute (") || text.hasPrefix("mute mic") || text.hasPrefix("mute microphone")
                || text.hasPrefix("mute my") { return .unmuted }
        }
        return .unknown
    }
}
