import AppKit
import CryptoKit
import Foundation
import Network
import OnwordCore
import Security
import os

/// "Connect Google Calendar": Google sign-in in the browser (OAuth 2.0 for desktop apps, with PKCE and a
/// one-time loopback redirect to 127.0.0.1), then read-only access to your events through the Calendar API.
/// The refresh token is kept in the macOS Keychain. No server is involved.
///
/// The OAuth client is configured in Resources/GoogleOAuth.plist (keys ClientID, ClientSecret), which the
/// build copies into the app. For desktop apps Google treats the "secret" as non-confidential.
@MainActor
final class GoogleCalendar: ObservableObject {
    static let shared = GoogleCalendar()

    @Published private(set) var connectedEmail: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var lastError: String?
    /// While signing in: the Google page, and the browser it opened in. With two screens or several browser
    /// windows it can open out of sight, and your account may be in another browser, so it can be opened
    /// again, or copied to paste into the browser that has your account.
    @Published private(set) var signInURL: URL?
    @Published private(set) var openedIn: String?

    var isConfigured: Bool { config != nil }
    var isConnected: Bool { connectedEmail != nil }

    private struct Config { let clientID: String; let clientSecret: String? }
    private let config: Config? = {
        guard let url = Bundle.main.url(forResource: "GoogleOAuth", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: String],
              var id = dict["ClientID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              !id.hasPrefix("YOUR_") else { return nil }
        // A client ID pasted with its domain already on it can end up with the domain twice, which Google
        // rejects as "OAuth client was not found".
        let domain = ".apps.googleusercontent.com"
        while id.hasSuffix(domain + domain) { id.removeLast(domain.count) }
        return Config(clientID: id, clientSecret: dict["ClientSecret"])
    }()

    private let scopes = "openid email https://www.googleapis.com/auth/calendar.readonly"
    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var listener: NWListener?
    /// Counts sign-in attempts, so an older attempt's timeout doesn't end a newer one.
    private var attempt = 0
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "google")

    private init() {
        // Test builds with sample data stay away from the real Keychain (a differently signed build would
        // make macOS ask for the password).
        guard ProcessInfo.processInfo.environment["ONWORD_TEST_DATA"] == nil else { return }
        connectedEmail = Keychain.read(account: "google-email")
    }

    // MARK: - Sign in

    /// Starts Google sign-in in the default browser. Clicking Connect while a sign-in is waiting starts it again.
    func connect() {
        guard let config else { return }
        if isConnecting { stopListening() }
        isConnecting = true
        attempt += 1
        let thisAttempt = attempt
        lastError = nil
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(24)

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handle(connection, verifier: verifier, state: state) }
            }
            listener.stateUpdateHandler = { [weak self] newState in
                guard case .ready = newState, let port = listener.port?.rawValue else { return }
                Task { @MainActor in
                    guard let self else { return }
                    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                    components.queryItems = [
                        .init(name: "client_id", value: config.clientID),
                        .init(name: "redirect_uri", value: "http://127.0.0.1:\(port)"),
                        .init(name: "response_type", value: "code"),
                        .init(name: "scope", value: self.scopes),
                        .init(name: "code_challenge", value: challenge),
                        .init(name: "code_challenge_method", value: "S256"),
                        .init(name: "state", value: state),
                        .init(name: "access_type", value: "offline"),
                        // Always show Google's account chooser (with "Use another account"), then the consent screen.
                        .init(name: "prompt", value: "select_account consent"),
                    ]
                    self.signInURL = components.url
                    self.openSignIn()
                    self.log.notice("Opened Google sign-in in the browser (redirect port \(port))")
                }
            }
            listener.start(queue: .main)
            // Give up if the browser sign-in is abandoned.
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
                guard let self, self.isConnecting, self.attempt == thisAttempt else { return }
                self.finish(error: "Sign-in timed out. Try Connect again.")
            }
        } catch {
            finish(error: "Couldn't start sign-in: \(error.localizedDescription)")
        }
    }

    /// Opens the waiting sign-in page (again) in the default browser and brings it forward.
    func openSignIn() {
        guard let url = signInURL else { return }
        // Test hook for demo recordings: ONWORD_OAUTH_CHROME_PROFILE=<profile folder> opens it in that Chrome profile.
        if let profile = ProcessInfo.processInfo.environment["ONWORD_OAUTH_CHROME_PROFILE"] {
            let chrome = Process()
            chrome.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
            chrome.arguments = ["--profile-directory=\(profile)", url.absoluteString]
            try? chrome.run()
            openedIn = "Google Chrome"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first?.activate()
            }
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            lastError = "No browser is set up to open the Google sign-in. Copy the link and paste it into a browser."
            return
        }
        openedIn = Self.appName(app)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.log.error("Couldn't open the sign-in in \(app.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self?.lastError = "Couldn't open \(Self.appName(app)). Copy the link and paste it into a browser."
            }
        }
    }

    /// Puts the sign-in link on the clipboard, to paste into any browser or browser profile.
    func copySignInLink() {
        guard let url = signInURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Stops waiting for the browser.
    func cancelSignIn() {
        guard isConnecting else { return }
        finish(error: nil)
    }

    static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
    }

    func disconnect() {
        if let token = Keychain.read(account: "google-refresh-token") {
            // Revoke at Google too, so the access disappears from the user's Google account page.
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": token])
            URLSession.shared.dataTask(with: request).resume()
        }
        Keychain.delete(account: "google-refresh-token")
        Keychain.delete(account: "google-email")
        accessToken = nil
        connectedEmail = nil
        CalendarService.shared.refresh(force: true)
    }

    /// Reads the browser's redirect (GET /?code=…&state=…), answers it, and exchanges the code.
    private func handle(_ connection: NWConnection, verifier: String, state: String) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return }
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let items = URLComponents(string: "http://localhost\(path)")?.queryItems ?? []
                let value = { (name: String) in items.first { $0.name == name }?.value }

                let ok = value("code") != nil && value("state") == state
                self.log.notice("Browser redirect received: \(path.split(separator: "?").first.map(String.init) ?? "", privacy: .public) code=\(value("code") != nil) error=\(value("error") ?? "none", privacy: .public)")
                let message = ok ? "Onword is connected to Google Calendar. You can close this tab."
                                 : "Sign-in didn't complete (\(value("error") ?? "cancelled")). You can close this tab."
                let body = "<html><body style='font-family:-apple-system;padding:48px'><h2>\(message)</h2></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

                guard path.hasPrefix("/?") || path.hasPrefix("/?code") || !items.isEmpty else { return }  // favicon etc.
                guard ok, let code = value("code"), let port = self.listener?.port?.rawValue else {
                    self.finish(error: value("error").map { "Google sign-in: \($0)" } ?? "Sign-in was cancelled.")
                    return
                }
                await self.exchange(code: code, verifier: verifier, redirect: "http://127.0.0.1:\(port)")
            }
        }
    }

    private func exchange(code: String, verifier: String, redirect: String) async {
        guard let config else { return }
        var fields = ["code": code, "client_id": config.clientID, "code_verifier": verifier,
                      "grant_type": "authorization_code", "redirect_uri": redirect]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        do {
            let token = try await tokenRequest(fields)
            guard let refresh = token.refresh_token else { throw GoogleError.message("Google didn't return a refresh token.") }
            Keychain.save(refresh, account: "google-refresh-token")
            accessToken = token.access_token
            accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600) - 60)
            let email = try await userEmail()
            Keychain.save(email, account: "google-email")
            connectedEmail = email
            log.notice("Connected Google Calendar")
            log.notice("Token exchange OK")
            finish(error: nil)
            CalendarService.shared.refresh(force: true)
        } catch {
            finish(error: error.localizedDescription)
        }
    }

    private func finish(error: String?) {
        isConnecting = false
        lastError = error
        signInURL = nil
        openedIn = nil
        stopListening()
        if let error { log.error("Google sign-in failed: \(error, privacy: .public)") }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - API

    enum GoogleError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoogleError.message("Google token error: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// A valid access token, refreshing it with the stored refresh token when needed.
    private func validAccessToken() async throws -> String {
        if let accessToken, Date() < accessTokenExpiry { return accessToken }
        guard let config, let refresh = Keychain.read(account: "google-refresh-token") else {
            throw GoogleError.message("Not connected to Google Calendar.")
        }
        var fields = ["refresh_token": refresh, "client_id": config.clientID, "grant_type": "refresh_token"]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        do {
            let token = try await tokenRequest(fields)
            accessToken = token.access_token
            accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600) - 60)
            return token.access_token
        } catch {
            // Revoked or expired (e.g. the user removed access in their Google account): sign out locally.
            if "\(error)".contains("invalid_grant") { disconnect() }
            throw error
        }
    }

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoogleError.message("Google Calendar error: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func userEmail() async throws -> String {
        struct Info: Decodable { let email: String? }
        let info = try await get(URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!, as: Info.self)
        return info.email ?? "Google account"
    }

    struct CalendarListEntry: Decodable, Identifiable {
        let id: String
        let summary: String?
        let backgroundColor: String?
        let selected: Bool?
        let primary: Bool?
    }

    /// Calendars in the account, as Google shows them.
    func calendarList() async throws -> [CalendarListEntry] {
        struct List: Decodable { let items: [CalendarListEntry]? }
        return try await get(URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader")!,
                             as: List.self).items ?? []
    }

    /// Meetings (events with other people or a call link) between `from` and `to`.
    func meetings(from: Date, to: Date, hidden: Set<String>) async throws -> [UpcomingMeeting] {
        let calendars = try await calendarList().filter { ($0.selected ?? $0.primary ?? false) && !hidden.contains($0.id) }
        var result: [UpcomingMeeting] = []
        let iso = ISO8601DateFormatter()
        for calendar in calendars {
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendar.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendar.id)/events")!
            components.queryItems = [
                .init(name: "timeMin", value: iso.string(from: from)),
                .init(name: "timeMax", value: iso.string(from: to)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "50"),
            ]
            let events = try await get(components.url!, as: EventList.self).items ?? []
            let color = NSColor(hex: calendar.backgroundColor) ?? .systemBlue
            result += events.compactMap { $0.meeting(color: color) }
        }
        // The same event can appear in several calendars.
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }.sorted { $0.start < $1.start }
    }

    private struct EventList: Decodable { let items: [Event]? }

    private struct Event: Decodable {
        struct Time: Decodable { let dateTime: String? }
        struct Attendee: Decodable {
            let email: String?
            let displayName: String?
            let isSelf: Bool?
            let resource: Bool?
            let responseStatus: String?
            enum CodingKeys: String, CodingKey {
                case email, displayName, resource, responseStatus
                case isSelf = "self"
            }
        }
        struct Conference: Decodable {
            struct EntryPoint: Decodable { let entryPointType: String?; let uri: String? }
            let entryPoints: [EntryPoint]?
        }
        let id: String
        let status: String?
        let summary: String?
        let start: Time
        let end: Time
        let attendees: [Attendee]?
        let hangoutLink: String?
        let conferenceData: Conference?
        let location: String?
        let description: String?

        func meeting(color: NSColor) -> UpcomingMeeting? {
            let iso = ISO8601DateFormatter()
            // All-day events have only a date; skip them.
            guard status != "cancelled", let s = start.dateTime, let e = end.dateTime,
                  let startDate = iso.date(from: s), let endDate = iso.date(from: e), endDate > Date() else { return nil }
            if attendees?.first(where: { $0.isSelf == true })?.responseStatus == "declined" { return nil }

            let video = conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri ?? hangoutLink
            let link = MeetingLink.find(in: [video, location, description])
            let others = (attendees ?? []).filter { $0.isSelf != true && $0.resource != true }
            guard link != nil || video != nil || !others.isEmpty else { return nil }

            let names = others.compactMap { a -> String? in
                if let name = a.displayName, !name.isEmpty { return name }
                return a.email?.split(separator: "@").first.map { $0.replacingOccurrences(of: ".", with: " ").capitalized }
            }
            return UpcomingMeeting(
                id: "google-\(id)", title: summary?.isEmpty == false ? summary! : "Untitled meeting",
                start: startDate, end: endDate, attendees: names,
                joinURL: link?.url ?? video.flatMap(URL.init(string:)),
                platform: link?.platform ?? (video?.contains("meet.google.com") == true ? .googleMeet : nil),
                calendarColor: color)
        }
    }

    // MARK: - Helpers

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }
}

/// Minimal Keychain wrapper for the Google refresh token and account email.
enum Keychain {
    private static let service = "io.github.h-thavy.onword.google"

    static func save(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension NSColor {
    convenience init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
