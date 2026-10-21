import SwiftUI
import AppKit
import Combine

// MARK: - Palette

extension NSColor {
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

// Color appears only when something needs attention; everything else stays neutral.
enum Palette {
    static let clay = NSColor.dynamic(light: 0xD97757, dark: 0xD97757)
    static let surface = NSColor.dynamic(light: 0xFAF9F5, dark: 0x30302E)
    static let hairline = NSColor.dynamic(light: 0xDEDCD1, dark: 0x48473F)
    static let warningFill = NSColor.dynamic(light: 0xE5A50A, dark: 0xE8B339)
    static let warningText = NSColor.dynamic(light: 0x8A5A00, dark: 0xF2C665)
    static let warningBg = NSColor.dynamic(light: 0xFCF3D9, dark: 0x3A2F14)
    static let dangerFill = NSColor.dynamic(light: 0xD64545, dark: 0xE5625F)
    static let dangerText = NSColor.dynamic(light: 0xA32D2D, dark: 0xF09595)
    static let dangerBg = NSColor.dynamic(light: 0xFCEBEB, dark: 0x3D1A1A)
}

// MARK: - Model

enum Severity: Int, Comparable {
    case normal, warning, critical

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    init(server: String?, utilization: Double) {
        switch server {
        case "critical", "exceeded", "blocked": self = .critical
        case "warning": self = .warning
        case "normal": self = .normal
        // Server didn't say; fall back to thresholds close to what it uses.
        default: self = utilization >= 90 ? .critical : utilization >= 75 ? .warning : .normal
        }
    }

    var fill: NSColor? {
        switch self {
        case .normal: return nil
        case .warning: return Palette.warningFill
        case .critical: return Palette.dangerFill
        }
    }
}

struct Limit: Identifiable {
    let id: String          // raw key from the API, e.g. "five_hour"
    let label: String
    let utilization: Double // 0–100
    let resetsAt: Date?
    let severity: Severity

    var percent: Int { Int(utilization.rounded()) }
}

enum UsageError: LocalizedError {
    case cliNotInstalled
    case noCredentials
    case expired
    case rateLimited(retryAfter: TimeInterval)
    case http(Int)
    case network

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled: return "Headroom needs the Claude Code command-line tool."
        case .noCredentials: return "You're not signed in to the Claude Code command-line tool."
        case .expired: return "Your Claude Code sign-in expired."
        case .rateLimited: return "Too many requests right now."
        case .http(let code): return "Couldn't load usage (error \(code))."
        case .network: return "Couldn't reach Claude. Check your connection."
        }
    }

    var hint: String? {
        switch self {
        case .cliNotInstalled:
            return "Claude Code in the Claude app keeps its own sign-in, which Headroom can't read. "
                + "Copy the install command, paste it into Terminal, then run claude and type /login."
        case .noCredentials:
            return "Claude Code in the Claude app doesn't count. In Terminal, run claude, then type /login."
        case .expired:
            return Settings.renewSignIn
                ? "Headroom couldn't renew it. Open Terminal, run claude, then type /login."
                : "Headroom can renew it for you, or open Terminal and run claude."
        case .rateLimited(let after): return "Retrying in \(max(1, Int(after / 60))) min."
        default: return nil
        }
    }

    var canRetry: Bool {
        if case .rateLimited = self { return false }
        return true
    }

    /// One-time setup steps and temporary pauses, shown calmly rather than as failures.
    var isQuiet: Bool {
        switch self {
        case .cliNotInstalled, .noCredentials, .rateLimited: return true
        default: return false
        }
    }
}

// MARK: - Claude Code command-line tool

/// Anthropic's installer for the Claude Code command-line tool.
let claudeInstallCommand = "curl -fsSL https://claude.ai/install.sh | bash"

/// Whether the `claude` command-line tool is installed. Apps launched from Finder don't get
/// the shell's PATH, so check the usual install locations, then ask a login shell.
func isClaudeCLIInstalled() -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "\(home)/.local/bin/claude",
        "\(home)/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "\(home)/.npm-global/bin/claude",
    ]
    if candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return true }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "command -v claude"]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return false }
    // A slow shell profile shouldn't hang the refresh.
    let deadline = Date().addingTimeInterval(3)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning { p.terminate(); return false }
    return p.terminationStatus == 0
}

func openTerminal() {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

// MARK: - Settings

enum Settings {
    /// Opt-in: let Headroom renew Claude Code's sign-in when it expires. Off by default
    /// because it writes to Claude Code's saved credentials, not just reads them.
    static var renewSignIn: Bool {
        get { UserDefaults.standard.bool(forKey: "renewSignIn") }
        set { UserDefaults.standard.set(newValue, forKey: "renewSignIn") }
    }
}

// MARK: - Credentials

let keychainService = "Claude Code-credentials"
let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/.credentials.json")

// Same values Claude Code uses to renew its own sign-in.
let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
let claudeCodeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

struct Credentials {
    let token: String
    let refreshToken: String?
    let expiresAt: Date?
    let plan: String?
    /// The whole stored document, so a renewal can write it back without dropping other keys.
    let root: [String: Any]
    let fromKeychain: Bool

    /// Treat tokens about to expire as expired, so a fetch doesn't fail halfway.
    var isStale: Bool {
        token.isEmpty || (expiresAt.map { $0.timeIntervalSinceNow < 5 * 60 } ?? false)
    }
}

@discardableResult
func runSecurity(_ args: [String], input: String? = nil) -> (status: Int32, output: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    if input != nil { p.standardInput = inp }
    do { try p.run() } catch { return (-1, Data()) }
    if let input {
        inp.fileHandleForWriting.write(Data(input.utf8))
        try? inp.fileHandleForWriting.close()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

/// Reads the OAuth token Claude Code stores. Shells out to `security` because that
/// binary is already on the keychain item's access list, so no extra prompt appears.
func loadCredentials() throws -> Credentials {
    var json: Data?
    var fromKeychain = false

    let r = runSecurity(["find-generic-password", "-s", keychainService, "-w"])
    if r.status == 0, !r.output.isEmpty {
        json = r.output
        fromKeychain = true
    } else {
        // Fallback used by Claude Code on some setups.
        json = try? Data(contentsOf: credentialsFile)
    }

    guard let data = json,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any]
    else { throw UsageError.noCredentials }

    return Credentials(
        token: oauth["accessToken"] as? String ?? "",
        refreshToken: (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 },
        expiresAt: (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
        plan: oauth["subscriptionType"] as? String,
        root: root,
        fromKeychain: fromKeychain)
}

/// Renews the sign-in with its refresh token and saves the result where Claude Code keeps it,
/// so Claude Code picks up the new token too (refresh tokens are single-use).
/// `rejectedToken` is a token the API just refused even though it hadn't reached its expiry time.
func renewCredentials(rejectedToken: String? = nil) async throws -> Credentials {
    // Re-read first: Claude Code may have renewed it moments ago, and using its
    // old refresh token would invalidate both.
    let current = try loadCredentials()
    if !current.isStale && current.token != rejectedToken { return current }
    guard let refresh = current.refreshToken else { throw UsageError.expired }

    var req = URLRequest(url: tokenURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "client_id": claudeCodeClientID,
    ])
    req.timeoutInterval = 15

    let data: Data, resp: URLResponse
    do {
        (data, resp) = try await URLSession.shared.data(for: req)
    } catch {
        throw UsageError.network
    }
    guard (resp as? HTTPURLResponse)?.statusCode == 200,
          let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let access = body["access_token"] as? String, !access.isEmpty
    else { throw UsageError.expired }

    var oauth = current.root["claudeAiOauth"] as? [String: Any] ?? [:]
    oauth["accessToken"] = access
    if let newRefresh = body["refresh_token"] as? String, !newRefresh.isEmpty {
        oauth["refreshToken"] = newRefresh
    }
    if let expiresIn = (body["expires_in"] as? NSNumber)?.doubleValue {
        oauth["expiresAt"] = Int64((Date().timeIntervalSince1970 + expiresIn) * 1000)
    }
    var root = current.root
    root["claudeAiOauth"] = oauth
    let json = try JSONSerialization.data(withJSONObject: root)

    if current.fromKeychain {
        // Same approach as Claude Code: hex payload over stdin, so the secret never
        // appears in the process list.
        let account = keychainAccount() ?? NSUserName()
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let cmd = "add-generic-password -U -a \"\(account)\" -s \"\(keychainService)\" -X \"\(hex)\"\n"
        guard runSecurity(["-i"], input: cmd).status == 0 else { throw UsageError.expired }
    } else {
        try json.write(to: credentialsFile, options: .atomic)
    }
    return try loadCredentials()
}

/// The account name on Claude Code's keychain item, so an update replaces it in place.
func keychainAccount() -> String? {
    let r = runSecurity(["find-generic-password", "-s", keychainService])
    guard r.status == 0, let text = String(data: r.output, encoding: .utf8),
          let line = text.split(separator: "\n").first(where: { $0.contains("\"acct\"") }),
          let start = line.range(of: "=\""), line.hasSuffix("\"")
    else { return nil }
    return String(line[start.upperBound..<line.index(before: line.endIndex)])
}

// MARK: - API

let labels: [String: String] = [
    "five_hour": "Current session",
    "seven_day": "Weekly limit",
    "seven_day_opus": "Weekly Opus limit",
    "seven_day_sonnet": "Weekly Sonnet limit",
    "seven_day_oauth_apps": "Weekly OAuth apps limit",
]
let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps"]

// The API's `limits` array names limits differently from the top-level keys.
let kindToKey: [String: String] = [
    "session": "five_hour",
    "weekly_all": "seven_day",
    "weekly_opus": "seven_day_opus",
    "weekly_sonnet": "seven_day_sonnet",
]

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func fetchLimits(token: String) async throws -> [Limit] {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 15

    let data: Data, resp: URLResponse
    do {
        (data, resp) = try await URLSession.shared.data(for: req)
    } catch {
        throw UsageError.network
    }
    let http = resp as? HTTPURLResponse
    switch http?.statusCode ?? 0 {
    case 200: break
    case 401: throw UsageError.expired
    case 429:
        let after = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 300
        throw UsageError.rateLimited(retryAfter: max(after, 60))
    case let code: throw UsageError.http(code)
    }

    let root = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

    var serverSeverity: [String: String] = [:]
    for item in root["limits"] as? [[String: Any]] ?? [] {
        if let kind = item["kind"] as? String, let key = kindToKey[kind] {
            serverSeverity[key] = item["severity"] as? String
        }
    }

    // Decode loosely: any top-level object with a "utilization" field is a limit,
    // so new limit types show up without code changes.
    let limits = root.compactMap { key, value -> Limit? in
        guard let obj = value as? [String: Any],
              let util = (obj["utilization"] as? NSNumber)?.doubleValue
        else { return nil }
        let label = labels[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
        return Limit(id: key, label: label, utilization: util,
                     resetsAt: parseDate(obj["resets_at"] as? String),
                     severity: Severity(server: serverSeverity[key], utilization: util))
    }
    return limits.sorted {
        (order.firstIndex(of: $0.id) ?? 99, $0.id) < (order.firstIndex(of: $1.id) ?? 99, $1.id)
    }
}

// MARK: - State

@MainActor
final class UsageStore: ObservableObject {
    @Published var limits: [Limit] = []
    @Published var error: UsageError?
    @Published var lastUpdated: Date?
    @Published var plan: String?
    @Published var loading = false

    /// Opening the popover often shouldn't hit the API each time; the endpoint rate-limits.
    private let minInterval: TimeInterval = 60
    private var blockedUntil: Date?
    private var timer: Timer?

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// `force` (the refresh button) skips the freshness check but still honours rate-limit backoff.
    @Published var renewSignIn = Settings.renewSignIn {
        didSet { Settings.renewSignIn = renewSignIn }
    }

    func refresh(force: Bool = false) async {
        guard !loading else { return }
        if let until = blockedUntil, until > Date() { return }
        if !force, error == nil, let last = lastUpdated, Date().timeIntervalSince(last) < minInterval {
            return
        }

        // Demo mode for screenshots: `defaults write app.headroom.menubar demo -bool true`.
        if UserDefaults.standard.bool(forKey: "demo") {
            let now = Date()
            plan = "pro"
            limits = [
                Limit(id: "five_hour", label: labels["five_hour"]!, utilization: 82,
                      resetsAt: now.addingTimeInterval(72 * 60), severity: .warning),
                Limit(id: "seven_day", label: labels["seven_day"]!, utilization: 47,
                      resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600), severity: .normal),
            ]
            error = nil
            lastUpdated = now
            return
        }

        loading = true
        defer { loading = false }
        do {
            var creds = try loadCredentials()
            if creds.isStale {
                guard renewSignIn else { throw UsageError.expired }
                creds = try await renewCredentials()
            }
            plan = creds.plan
            do {
                limits = try await fetchLimits(token: creds.token)
            } catch UsageError.expired where renewSignIn {
                // Refused before its stated expiry (e.g. revoked); renew once and retry.
                creds = try await renewCredentials(rejectedToken: creds.token)
                limits = try await fetchLimits(token: creds.token)
            }
            error = nil
            blockedUntil = nil
            lastUpdated = Date()
        } catch let e as UsageError {
            // Keep the last good numbers on screen; just flag them as stale.
            if case .noCredentials = e, !isClaudeCLIInstalled() {
                error = .cliNotInstalled
            } else {
                error = e
            }
            if case .rateLimited(let after) = e {
                blockedUntil = Date().addingTimeInterval(after)
            }
        } catch {
            self.error = .network
        }
    }

    var session: Limit? { limits.first { $0.id == "five_hour" } }
    var others: [Limit] { limits.filter { $0.id != "five_hour" } }

    /// The limit most in need of attention, if any is near or at its cap.
    var mostSevere: Limit? {
        limits.filter { $0.severity >= .warning }
            .max { ($0.severity, $0.utilization) < ($1.severity, $1.utilization) }
    }

    var planLabel: String? {
        guard let plan, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }
}

// MARK: - Formatting

func duration(until date: Date) -> String {
    let secs = Int(max(0, date.timeIntervalSinceNow))
    let h = secs / 3600, m = (secs % 3600) / 60
    if h == 0 { return "\(max(m, 1)) min" }
    return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
}

func clockTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(date) || date.timeIntervalSinceNow < 12 * 3600
        ? "h:mm a" : "EEE h:mm a"
    return f.string(from: date)
}

/// Within a day: "Resets in 2 hr 15 min". Further out: "Resets Sat 5:10 AM".
func resetText(_ date: Date?) -> String {
    guard let date else { return "" }
    if date.timeIntervalSinceNow <= 0 { return "Resetting now" }
    if date.timeIntervalSinceNow < 24 * 3600 { return "Resets in \(duration(until: date))" }
    return "Resets \(clockTime(date))"
}

func attentionText(_ limit: Limit) -> String {
    let name = limit.id == "five_hour" ? "session limit" : limit.label.lowercased()
    let when = limit.resetsAt.map { " It resets at \(clockTime($0))." } ?? ""
    return limit.severity == .critical
        ? "You've reached your \(name).\(when)"
        : "You're close to your \(name).\(when)"
}

// MARK: - Views

struct UsageBar: View {
    let limit: Limit
    let neutral: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(limit.severity.fill.map(Color.init) ?? neutral)
                    .frame(width: geo.size.width * min(max(limit.utilization, 0), 100) / 100)
            }
        }
        .frame(height: 4)
    }
}

struct SessionBlock: View {
    let limit: Limit
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(limit.label).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(limit.percent)%")
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                Text("used").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            UsageBar(limit: limit, neutral: .primary)
                .padding(.top, 8)
            Text(resetText(limit.resetsAt))
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.label), \(limit.percent) percent used, \(resetText(limit.resetsAt))")
    }
}

struct LimitRow: View {
    let limit: Limit
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(limit.label).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(limit.percent)%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(limit.severity == .normal ? Color.primary
                                     : limit.severity == .warning ? Color(Palette.warningText)
                                     : Color(Palette.dangerText))
            }
            UsageBar(limit: limit, neutral: .secondary)
                .padding(.top, 8)
            Text(resetText(limit.resetsAt))
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.label), \(limit.percent) percent used, \(resetText(limit.resetsAt))")
    }
}

struct Callout: View {
    let icon: String
    let text: String
    var detail: String? = nil
    let fg: NSColor
    let bg: NSColor
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                if let detail { Text(detail).opacity(0.8) }
                if let action {
                    Button(action.label, action: action.run)
                        .controlSize(.small)
                        .padding(.top, 3)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(fg))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(bg), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

struct ContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage").font(.system(size: 14, weight: .semibold))
                Spacer()
                if let plan = store.planLabel {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.bottom, 14)

            if let error = store.error {
                Callout(icon: "exclamationmark.circle",
                        text: error.localizedDescription,
                        detail: [error.hint,
                                 store.lastUpdated.map { "Showing usage from \(clockTime($0))." }]
                            .compactMap { $0 }.joined(separator: " "),
                        // Setup steps and rate limits aren't failures; keep them calm.
                        fg: error.isQuiet ? .labelColor : Palette.dangerText,
                        bg: error.isQuiet ? NSColor.labelColor.withAlphaComponent(0.06) : Palette.dangerBg,
                        action: errorAction(error))
                    .padding(.bottom, 14)
            }

            Group {
                if let session = store.session {
                    SessionBlock(limit: session)
                }
                ForEach(store.others) { limit in
                    Divider().padding(.vertical, 12)
                    LimitRow(limit: limit)
                }
            }
            .opacity(store.error == nil ? 1 : 0.55) // stale data

            if store.limits.isEmpty && store.error == nil {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 20)
                .accessibilityLabel("Loading usage")
            }

            if store.error == nil, let limit = store.mostSevere {
                Callout(icon: "exclamationmark.triangle",
                        text: attentionText(limit),
                        fg: limit.severity == .critical ? Palette.dangerText : Palette.warningText,
                        bg: limit.severity == .critical ? Palette.dangerBg : Palette.warningBg)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                Button("View usage details", action: openUsageDetails)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Group {
                    if store.loading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            Task { await store.refresh(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .frame(width: 16, height: 16)
                .help(store.lastUpdated.map { "Updated \(clockTime($0))" } ?? "Refresh")
                .accessibilityLabel(store.loading ? "Refreshing" : "Refresh")

                Menu {
                    Toggle("Renew Claude Code sign-in automatically", isOn: $store.renewSignIn)
                    Divider()
                    Button("Quit Headroom") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.top, 16)
        }
        .padding(16)
        .frame(width: 280)
    }
}

extension ContentView {
    /// An expired sign-in offers to turn on renewal; other errors offer a retry.
    func errorAction(_ error: UsageError) -> (label: String, run: () -> Void)? {
        switch error {
        case .cliNotInstalled:
            return ("Copy command, open Terminal", {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(claudeInstallCommand, forType: .string)
                openTerminal()
            })
        case .noCredentials:
            return ("Open Terminal", openTerminal)
        default: break
        }
        if case .expired = error, !store.renewSignIn {
            return ("Renew automatically", {
                store.renewSignIn = true
                Task { await store.refresh(force: true) }
            })
        }
        return error.canRetry ? ("Retry", { Task { await store.refresh(force: true) } }) : nil
    }
}

/// Opens the usage page in the Claude desktop app when it's installed, otherwise on claude.ai.
/// `claude://claude.ai/<path>` is the desktop app's own link format for claude.ai pages.
@MainActor
func openUsageDetails() {
    let hasDesktopApp = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
    let url = hasDesktopApp
        ? URL(string: "claude://claude.ai/settings/usage")!
        : URL(string: "https://claude.ai/settings/usage")!
    NSWorkspace.shared.open(url)
    (NSApp.delegate as? AppDelegate)?.close()
}

/// Solid Claude surface instead of the system glass material.
struct PanelChrome: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        ContentView(store: store)
            .background(Color(Palette.surface), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(Palette.hairline), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .fixedSize()
    }
}

/// Borderless panel that can take clicks (links, buttons) without activating the app.
final class UsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Menu bar

/// Builds the status item title: clay gauge (matching the app icon), session %, and a dot
/// when any limit needs attention.
/// Done in AppKit because MenuBarExtra renders its label as a monochrome template.
@MainActor
func statusTitle(for store: UsageStore) -> NSAttributedString {
    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let title = NSMutableAttributedString()

    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        .applying(.init(paletteColors: [Palette.clay]))
    if let gauge = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        gauge.isTemplate = false
        let attachment = NSTextAttachment()
        attachment.image = gauge
        attachment.bounds = CGRect(x: 0, y: -2, width: gauge.size.width, height: gauge.size.height)
        title.append(NSAttributedString(attachment: attachment))
    }

    let pct = store.session.map { "\($0.percent)%" } ?? "--"
    title.append(NSAttributedString(string: " \(pct)", attributes: [.font: font]))

    if let fill = store.mostSevere?.severity.fill {
        title.append(NSAttributedString(string: " ●", attributes: [
            .font: NSFont.systemFont(ofSize: 7),
            .foregroundColor: fill,
            .baselineOffset: 2,
        ]))
    }
    return title
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var panel: UsagePanel!
    var hosting: NSHostingView<PanelChrome>!
    var outsideClickMonitor: Any?
    var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hosting = NSHostingView(rootView: PanelChrome(store: store))
        panel = UsagePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = hosting

        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        updateTitle()

        // objectWillChange fires before the new values land, so read them on the next turn.
        cancellable = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.updateTitle()
                if self?.panel.isVisible == true { self?.positionPanel() } // content height may change
            }
        }
    }

    func updateTitle() {
        guard let button = statusItem.button else { return }
        button.attributedTitle = statusTitle(for: store)
        let pct = store.session.map { "\($0.percent) percent" } ?? "unavailable"
        button.setAccessibilityLabel("Claude session usage \(pct)"
            + (store.mostSevere != nil ? ", a limit needs attention" : ""))
    }

    @objc func toggle() {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(lastClosed) > 0.25 {
            // The same click that just closed the panel shouldn't reopen it.
            open()
        }
    }

    var lastClosed = Date.distantPast

    /// The status item's frame on screen, so clicks on it aren't treated as "outside".
    var buttonScreenFrame: NSRect {
        guard let button = statusItem.button, let w = button.window else { return .zero }
        return w.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func open() {
        guard let button = statusItem.button else { return }
        Task { await store.refresh() } // throttled, so opening often is cheap
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)

        // Close on any click outside the panel, like a menu.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, !self.buttonScreenFrame.contains(point) else { return }
                self.close()
            }
        }
    }

    /// Anchors below the status item, centred on it, kept inside the screen.
    func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = hosting.fittingSize
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6,
                              width: size.width, height: size.height), display: true)
    }

    func close() {
        guard panel.isVisible else { return }
        lastClosed = Date()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }
}

@main
enum Headroom {
    static let delegate = MainActor.assumeIsolated { AppDelegate() }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
