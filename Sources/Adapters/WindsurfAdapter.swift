import Foundation

final class WindsurfAdapter: ProviderAdapter {

    // MARK: - API response models

    private struct UserStatusResponse: Decodable {
        var userStatus: UserStatus?
    }

    private struct UserStatus: Decodable {
        var planStatus: PlanStatus?
    }

    private struct PlanStatus: Decodable {
        var planInfo: PlanInfo?
        var planStart: String?
        var planEnd: String?
        var availablePromptCredits: FlexibleInt?
        var availableFlowCredits: FlexibleInt?
        var availableFlexCredits: FlexibleInt?
        var dailyQuotaRemainingPercent: FlexibleInt?
        var weeklyQuotaRemainingPercent: FlexibleInt?
        var overageBalanceMicros: FlexibleInt?
        var dailyQuotaResetAtUnix: FlexibleInt?
        var weeklyQuotaResetAtUnix: FlexibleInt?
    }

    /// Handles JSON values that can be either int or string-encoded int
    private struct FlexibleInt: Decodable {
        let value: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intVal = try? container.decode(Int.self) {
                value = intVal
            } else if let strVal = try? container.decode(String.self), let parsed = Int(strVal) {
                value = parsed
            } else {
                value = 0
            }
        }
    }

    private struct PlanInfo: Decodable {
        var planName: String?
    }

    let kind: ProviderKind = .windsurf
    private let rootURL: URL
    private let fileManager: FileManager

    // Response cache to avoid rate-limiting
    private static var cachedResponse: PlanStatus?
    private static var cachedResponseDate: Date?
    private static let cacheTTL: TimeInterval = 120 // 2 minutes

    static func invalidateCaches() {
        cachedResponse = nil
        cachedResponseDate = nil
    }

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Windsurf"),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    var observedURLs: [URL] {
        [rootURL.appending(path: "User/globalStorage/state.vscdb")]
    }

    func loadSnapshot() async throws -> ProviderSnapshot {
        let databaseURL = rootURL.appending(path: "User/globalStorage/state.vscdb")

        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return .unavailable(
                provider: kind,
                sourceDescription: "Expected Windsurf globalStorage state.vscdb",
                message: "No Windsurf local state database was found."
            )
        }

        // Read API key from database
        let database = try SQLiteDatabase(readOnly: databaseURL)
        let lastUpdated = fileManager.modificationDate(for: databaseURL)

        let apiKey = readApiKey(from: database)
        let planStatus = await fetchPlanStatus(apiKey: apiKey)

        var windows: [UsageWindow] = []
        var planName: String? = nil
        var planPeriod: String? = nil

        if let ps = planStatus {
            planName = ps.planInfo?.planName

            // Plan period
            let start = ps.planStart.flatMap { parseISO8601($0) }
            let end = ps.planEnd.flatMap { parseISO8601($0) }
            planPeriod = formatPlanPeriod(start: start, end: end)

            // Daily quota usage
            if let remaining = ps.dailyQuotaRemainingPercent?.value {
                let usedPct = Double(max(0, min(100, 100 - remaining)))
                let resetDate = ps.dailyQuotaResetAtUnix.map { Date(timeIntervalSince1970: Double($0.value)) }

                windows.append(UsageWindow(
                    id: "daily_quota",
                    label: "Daily Quota Usage",
                    usedAmount: nil,
                    totalAmount: nil,
                    percentUsed: usedPct / 100.0,
                    resetDate: resetDate,
                    note: resetDate.map { "Resets \(Self.formatResetDate($0))" },
                    isFallback: false
                ))
            }

            // Weekly quota usage
            if let remaining = ps.weeklyQuotaRemainingPercent?.value {
                let usedPct = Double(max(0, min(100, 100 - remaining)))
                let resetDate = ps.weeklyQuotaResetAtUnix.map { Date(timeIntervalSince1970: Double($0.value)) }

                windows.append(UsageWindow(
                    id: "weekly_quota",
                    label: "Weekly Quota Usage",
                    usedAmount: nil,
                    totalAmount: nil,
                    percentUsed: usedPct / 100.0,
                    resetDate: resetDate,
                    note: resetDate.map { "Resets \(Self.formatResetDate($0))" },
                    isFallback: false
                ))
            }

            // Extra usage balance
            if let micros = ps.overageBalanceMicros?.value, micros > 0 {
                let balance = Double(micros) / 1_000_000.0
                windows.append(UsageWindow(
                    id: "extra_usage",
                    label: "Extra Usage Balance",
                    usedAmount: nil,
                    totalAmount: nil,
                    percentUsed: nil,
                    resetDate: nil,
                    note: String(format: "$%.2f", balance),
                    isFallback: false
                ))
            }
        }

        let accountLabel = planName.map { "Windsurf \($0)" }

        return ProviderSnapshot(
            provider: kind,
            status: windows.isEmpty ? .warning : .ok,
            lastUpdated: lastUpdated,
            sourceDescription: "Windsurf API",
            accountLabel: accountLabel,
            badge: planName,
            message: windows.isEmpty ? "Could not fetch quota data." : planPeriod,
            windows: windows
        )
    }

    // MARK: - API call

    private func debugLog(_ msg: String) {
        #if DEBUG
        let line = "[\(Date())] [Windsurf] \(msg)\n"
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

    private func fetchPlanStatus(apiKey: String?) async -> PlanStatus? {
        // Return cached if fresh
        if let cached = Self.cachedResponse,
           let cacheDate = Self.cachedResponseDate,
           Date().timeIntervalSince(cacheDate) < Self.cacheTTL {
            return cached
        }

        guard let apiKey, !apiKey.isEmpty,
              let url = URL(string: "https://server.codeium.com/exa.api_server_pb.ApiServerService/GetUserStatus") else {
            debugLog("no apiKey or bad URL. apiKey=\(apiKey != nil ? "present(\(apiKey!.prefix(15))...)" : "nil")")
            return Self.cachedResponse
        }

        debugLog("calling API with key=\(apiKey.prefix(15))...")

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.timeoutInterval = 10

            let body: [String: Any] = [
                "metadata": [
                    "ide_name": "windsurf",
                    "ide_version": "1.0.0",
                    "extension_version": "2.0.0",
                    "api_key": apiKey
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                debugLog("response is not HTTP")
                return Self.cachedResponse
            }

            debugLog("HTTP \(http.statusCode), body=\(String(data: data, encoding: .utf8)?.prefix(300) ?? "nil")")

            guard (200..<300).contains(http.statusCode) else {
                return Self.cachedResponse
            }

            let decoded = try JSONDecoder().decode(UserStatusResponse.self, from: data)
            if let ps = decoded.userStatus?.planStatus {
                debugLog("decoded: daily=\(ps.dailyQuotaRemainingPercent?.value ?? -1), weekly=\(ps.weeklyQuotaRemainingPercent?.value ?? -1)")
                Self.cachedResponse = ps
                Self.cachedResponseDate = Date()
                return ps
            } else {
                debugLog("decoded but no planStatus found")
            }
        } catch {
            debugLog("error: \(error)")
        }

        return Self.cachedResponse
    }

    // MARK: - Read API key from database

    private func readApiKey(from database: SQLiteDatabase) -> String? {
        guard let authJSON = try? database.fetchFirstString(
            query: "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus';"
        ) else {
            return nil
        }

        guard let data = authJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = json["apiKey"] as? String else {
            return nil
        }

        return apiKey
    }

    // MARK: - Formatting

    private func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func formatResetDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM, HH:mm"
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    private func formatPlanPeriod(start: Date?, end: Date?) -> String? {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"

        guard let end else { return nil }

        let daysLeft = Calendar.current.dateComponents([.day], from: Date(), to: end).day ?? 0
        let endStr = fmt.string(from: end)

        if let start {
            let startStr = fmt.string(from: start)
            return "Plan \(startStr) – \(endStr) (\(daysLeft)d left)"
        }
        return "Resets \(endStr) (\(daysLeft)d left)"
    }
}
