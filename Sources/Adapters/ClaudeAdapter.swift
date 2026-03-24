import Foundation

final class ClaudeAdapter: ProviderAdapter {
    // MARK: - API Response Types

    private struct UsageResponse: Decodable {
        struct Window: Decodable {
            var utilization: Double
            var resetsAt: String

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }

        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDaySonnet: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDaySonnet = "seven_day_sonnet"
        }
    }

    private struct Claude2xResponse: Decodable {
        var is2x: Bool
        var promoActive: Bool?
        var isPeak: Bool?
        var isWeekend: Bool?

        enum CodingKeys: String, CodingKey {
            case is2x, promoActive, isPeak, isWeekend
            case twoXExpiresInSeconds = "2xWindowExpiresInSeconds"
            case twoXExpiresIn = "2xWindowExpiresIn"
            case standardExpiresInSeconds = "standardWindowExpiresInSeconds"
            case standardExpiresIn = "standardWindowExpiresIn"
        }

        var expiresInSeconds: Int?
        var expiresIn: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            is2x = try c.decode(Bool.self, forKey: .is2x)
            promoActive = try c.decodeIfPresent(Bool.self, forKey: .promoActive)
            isPeak = try c.decodeIfPresent(Bool.self, forKey: .isPeak)
            isWeekend = try c.decodeIfPresent(Bool.self, forKey: .isWeekend)

            if is2x {
                expiresInSeconds = try c.decodeIfPresent(Int.self, forKey: .twoXExpiresInSeconds)
                expiresIn = try c.decodeIfPresent(String.self, forKey: .twoXExpiresIn)
            } else {
                expiresInSeconds = try c.decodeIfPresent(Int.self, forKey: .standardExpiresInSeconds)
                expiresIn = try c.decodeIfPresent(String.self, forKey: .standardExpiresIn)
            }
        }
    }

    private struct ClaudeBackup: Decodable {
        struct OAuthAccount: Decodable {
            var emailAddress: String?
            var billingType: String?
            var displayName: String?
        }

        var oauthAccount: OAuthAccount?
    }

    let kind: ProviderKind = .claude
    private let rootURL: URL
    private let fileManager: FileManager
    private let isoFormatter = ISO8601DateFormatter()

    // Cache API responses to avoid rate-limiting (429)
    private static var cachedUsage: UsageResponse?
    private static var cachedUsageDate: Date?
    private static var cached2x: Claude2xResponse?
    private static var cached2xDate: Date?
    private static let usageCacheTTL: TimeInterval = 120   // 2 minutes
    private static let twoXCacheTTL: TimeInterval = 60     // 1 minute

    /// Invalidate all caches — called on wake from sleep or manual refresh
    static func invalidateCaches() {
        cachedUsage = nil
        cachedUsageDate = nil
        cached2x = nil
        cached2xDate = nil
    }

    private func debugLog(_ msg: String) {
        #if DEBUG
        let line = "[\(Date())] \(msg)\n"
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/aitracker-debug.log")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logURL.path, contents: line.data(using: .utf8))
        }
        #endif
    }

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude"),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    var observedURLs: [URL] {
        [
            rootURL.appending(path: "backups"),
            rootURL.appending(path: "projects"),
        ]
    }

    func loadSnapshot() async throws -> ProviderSnapshot {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return .unavailable(
                provider: kind,
                sourceDescription: "Expected local Claude state in ~/.claude",
                message: "No Claude local state was found on disk."
            )
        }

        // Load account info
        let backup = latestBackupURL().flatMap(loadBackup)
        let credentials = KeychainHelper.readClaudeCredentials()
        debugLog("credentials: token=\(credentials?.accessToken.prefix(20) ?? "nil")..., sub=\(credentials?.subscriptionType ?? "nil"), expires=\(credentials?.expiresAt?.description ?? "nil")")
        let accountLabel = buildAccountLabel(backup: backup, credentials: credentials)
        let badge = credentials?.subscriptionType?.capitalized ?? prettifiedBillingType(backup?.oauthAccount?.billingType)

        // Fetch actual usage from API
        let usageData = await fetchUsage(accessToken: credentials?.accessToken)

        // Fetch 2x status
        let twoXStatus = await fetch2xStatus()

        // Build windows from API data
        var windows: [UsageWindow] = []

        if let usage = usageData {
            // Session window (5-hour)
            if let fiveHour = usage.fiveHour {
                let resetDate = parseISO8601(fiveHour.resetsAt)
                windows.append(UsageWindow(
                    id: "session",
                    label: "Session (5h)",
                    usedAmount: nil,
                    totalAmount: nil,
                    percentUsed: fiveHour.utilization / 100.0,
                    resetDate: resetDate,
                    note: "5h window",
                    isFallback: false
                ))
            }

            // Weekly window (7-day)
            if let sevenDay = usage.sevenDay {
                let resetDate = parseISO8601(sevenDay.resetsAt)
                windows.append(UsageWindow(
                    id: "weekly",
                    label: "Weekly (7d)",
                    usedAmount: nil,
                    totalAmount: nil,
                    percentUsed: sevenDay.utilization / 100.0,
                    resetDate: resetDate,
                    note: nil,
                    isFallback: false
                ))
            }

            // Sonnet-specific weekly window if present
            if let sevenDaySonnet = usage.sevenDaySonnet {
                let resetDate = parseISO8601(sevenDaySonnet.resetsAt)
                windows.append(UsageWindow(
                    id: "sonnet",
                    label: "Sonnet (7d)",
                    usedAmount: nil,
                    totalAmount: nil,
                    percentUsed: sevenDaySonnet.utilization / 100.0,
                    resetDate: resetDate,
                    note: nil,
                    isFallback: false
                ))
            }
        }

        // Build badge and message
        var messageParts: [String] = []
        var resolvedBadge = badge

        if let twoX = twoXStatus {
            if twoX.is2x {
                resolvedBadge = "2×"
                if let expiresIn = twoX.expiresIn {
                    messageParts.append("2× active · ends in \(expiresIn)")
                } else {
                    messageParts.append("2× active")
                }
            } else if twoX.isPeak == true {
                if let expiresIn = twoX.expiresIn {
                    messageParts.append("1× peak hours · ends in \(expiresIn)")
                } else {
                    messageParts.append("1× (peak hours)")
                }
            }
        }

        if windows.isEmpty {
            messageParts.append("Could not fetch usage data. Check Keychain credentials.")
        }

        let lastUpdated = latestSessionModDate() ?? fileManager.modificationDate(for: rootURL)

        return ProviderSnapshot(
            provider: kind,
            status: windows.isEmpty ? .warning : .ok,
            lastUpdated: lastUpdated,
            sourceDescription: "Claude API + isclaude2x.com",
            accountLabel: accountLabel,
            badge: resolvedBadge,
            message: messageParts.isEmpty ? nil : messageParts.joined(separator: " · "),
            windows: windows
        )
    }

    // MARK: - API Fetching

    private func fetchUsage(accessToken: String?) async -> UsageResponse? {
        // Return cached response if still fresh
        if let cached = Self.cachedUsage,
           let cacheDate = Self.cachedUsageDate,
           Date().timeIntervalSince(cacheDate) < Self.usageCacheTTL {
            debugLog("fetchUsage: returning cached (age=\(Int(Date().timeIntervalSince(cacheDate)))s)")
            return cached
        }

        // Try with the provided token first, then retry with refreshed token on 401
        if let token = accessToken {
            let result = await callUsageAPI(token: token)
            if case .success(let usage) = result {
                return usage
            }
            if case .unauthorized = result {
                // Token was revoked (Claude Code refreshed it) — re-read from Keychain
                debugLog("fetchUsage: 401 — force-refreshing credentials from Keychain")
                if let fresh = KeychainHelper.forceRefreshCredentials() {
                    debugLog("fetchUsage: got fresh token, retrying API")
                    if case .success(let usage) = await callUsageAPI(token: fresh.accessToken) {
                        return usage
                    }
                }
            }
        } else {
            debugLog("fetchUsage: no token provided")
        }

        return Self.cachedUsage
    }

    private enum APIResult {
        case success(UsageResponse)
        case unauthorized
        case rateLimited
        case error
    }

    private func callUsageAPI(token: String) async -> APIResult {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return .error
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.timeoutInterval = 8

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                debugLog("callUsageAPI: response is not HTTP")
                return .error
            }

            debugLog("callUsageAPI: HTTP \(http.statusCode)")

            if http.statusCode == 401 {
                return .unauthorized
            }

            if http.statusCode == 429 {
                debugLog("callUsageAPI: rate limited")
                return .rateLimited
            }

            guard (200..<300).contains(http.statusCode) else {
                return .error
            }

            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            debugLog("callUsageAPI: decoded fiveHour=\(decoded.fiveHour?.utilization ?? -1), sevenDay=\(decoded.sevenDay?.utilization ?? -1)")

            // Update cache
            Self.cachedUsage = decoded
            Self.cachedUsageDate = Date()

            return .success(decoded)
        } catch {
            debugLog("callUsageAPI error: \(error)")
            return .error
        }
    }

    private func fetch2xStatus() async -> Claude2xResponse? {
        // Return cached if fresh
        if let cached = Self.cached2x,
           let cacheDate = Self.cached2xDate,
           Date().timeIntervalSince(cacheDate) < Self.twoXCacheTTL {
            return cached
        }

        guard let url = URL(string: "https://isclaude2x.com/json") else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return Self.cached2x
            }

            let decoded = try JSONDecoder().decode(Claude2xResponse.self, from: data)
            Self.cached2x = decoded
            Self.cached2xDate = Date()
            return decoded
        } catch {
            return Self.cached2x
        }
    }

    // MARK: - Helpers

    private func buildAccountLabel(backup: ClaudeBackup?, credentials: KeychainHelper.ClaudeCredentials?) -> String? {
        let parts = [
            backup?.oauthAccount?.displayName,
            backup?.oauthAccount?.emailAddress,
            credentials?.subscriptionType?.capitalized ?? prettifiedBillingType(backup?.oauthAccount?.billingType),
        ].compactMap { $0 }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func latestBackupURL() -> URL? {
        let backupsURL = rootURL.appending(path: "backups")
        let files = (try? fileManager.contentsOfDirectory(
            at: backupsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return files.max {
            (fileManager.modificationDate(for: $0) ?? .distantPast) < (fileManager.modificationDate(for: $1) ?? .distantPast)
        }
    }

    private func loadBackup(from url: URL) -> ClaudeBackup? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeBackup.self, from: data)
    }

    private func latestSessionModDate() -> Date? {
        let projectsURL = rootURL.appending(path: "projects")
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: projectsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        var latest: Date?
        for dir in dirs {
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                if let mod = fileManager.modificationDate(for: file) {
                    if latest == nil || mod > latest! { latest = mod }
                }
            }
        }
        return latest
    }

    private func parseISO8601(_ string: String) -> Date? {
        isoFormatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func prettifiedBillingType(_ rawValue: String?) -> String? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        return rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
