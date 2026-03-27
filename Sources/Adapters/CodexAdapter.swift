import Foundation

final class CodexAdapter: ProviderAdapter {
    private struct Codex2xResponse: Decodable {
        var is2x: Bool
        var promoActive: Bool?

        enum CodingKeys: String, CodingKey {
            case is2x, promoActive
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

            if is2x {
                expiresInSeconds = try c.decodeIfPresent(Int.self, forKey: .twoXExpiresInSeconds)
                expiresIn = try c.decodeIfPresent(String.self, forKey: .twoXExpiresIn)
            } else {
                expiresInSeconds = try c.decodeIfPresent(Int.self, forKey: .standardExpiresInSeconds)
                expiresIn = try c.decodeIfPresent(String.self, forKey: .standardExpiresIn)
            }
        }
    }

    private struct Codex2xStatus {
        var is2x: Bool
        var expiresIn: String?
        var deadlineDate: String?
    }

    let kind: ProviderKind = .codex
    private let rootURL: URL
    private let fileManager: FileManager
    private static var cached2x: Codex2xStatus?
    private static var cached2xDate: Date?
    private static let twoXCacheTTL: TimeInterval = 60

    init(rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex"), fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    var observedURLs: [URL] {
        [
            rootURL.appending(path: ".codex-global-state.json"),
            rootURL.appending(path: "logs_1.sqlite"),
            rootURL.appending(path: "state_5.sqlite"),
        ]
    }

    func invalidateCache() {
        // Codex reads from files, no API cache to clear
        Self.cached2x = nil
        Self.cached2xDate = nil
    }

    func loadSnapshot() async throws -> ProviderSnapshot {
        let existingFiles = observedURLs.filter { fileManager.fileExists(atPath: $0.path) }

        guard !existingFiles.isEmpty else {
            return .unavailable(
                provider: kind,
                sourceDescription: "Expected local Codex state in ~/.codex",
                message: "No Codex local state was found on disk."
            )
        }

        let lastUpdated = existingFiles.compactMap { fileManager.modificationDate(for: $0) }.max()

        let appServerSnapshot = try await CodexAppServerClient.shared.readSnapshot()
        let weeklyWindow = resolveWeeklyWindow(from: appServerSnapshot)
        let twoXStatus = await fetch2xStatus()
        let accountLabel = [appServerSnapshot.account?.email, prettifiedPlanType(appServerSnapshot.account?.planType)]
            .compactMap { $0 }
            .joined(separator: " · ")

        var windows: [UsageWindow] = []
        if let weeklyWindow {
            windows.append(weeklyWindow)
        }

        var messageParts: [String] = []
        var badge = prettifiedPlanType(appServerSnapshot.account?.planType)

        if let twoX = twoXStatus, twoX.is2x {
            badge = "2×"
            var twoXParts = ["2× active"]
            if let expiresIn = twoX.expiresIn {
                twoXParts.append("ends in \(expiresIn)")
            }
            if let deadline = twoX.deadlineDate {
                twoXParts.append("until \(deadline)")
            }
            messageParts.append(twoXParts.joined(separator: " · "))
        }

        if weeklyWindow == nil {
            messageParts.append("No weekly rate limit window was found from the Codex app-server.")
        }

        return ProviderSnapshot(
            provider: kind,
            status: weeklyWindow != nil ? .ok : .warning,
            lastUpdated: lastUpdated,
            sourceDescription: "Codex Desktop app-server + iscodex2x.com",
            accountLabel: accountLabel.isEmpty ? nil : accountLabel,
            badge: badge,
            message: messageParts.isEmpty ? nil : messageParts.joined(separator: " · "),
            windows: windows
        )
    }

    private func resolveWeeklyWindow(from snapshot: CodexAccountRateLimitSnapshot) -> UsageWindow? {
        // Find the window with the longest duration (weekly)
        let candidates = [snapshot.primary, snapshot.secondary].compactMap { $0 }

        guard let weekly = candidates.max(by: { ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0) }),
              let duration = weekly.windowDurationMins, duration >= 7 * 24 * 60 else {
            // Fall back to whichever window exists
            if let first = candidates.first {
                return UsageWindow(
                    id: "weekly",
                    label: "Weekly",
                    usedAmount: nil,
                    totalAmount: nil,
                    percentUsed: first.usedPercent.map { $0 / 100.0 },
                    resetDate: first.resetsAt.map(Date.init(timeIntervalSince1970:)),
                    note: first.windowDurationMins.map { "Window: \($0 / 60)h" },
                    isFallback: false
                )
            }
            return nil
        }

        return UsageWindow(
            id: "weekly",
            label: "Weekly",
            usedAmount: nil,
            totalAmount: nil,
            percentUsed: weekly.usedPercent.map { $0 / 100.0 },
            resetDate: weekly.resetsAt.map(Date.init(timeIntervalSince1970:)),
            note: "Window: \(duration / (24 * 60)) days",
            isFallback: false
        )
    }

    private func prettifiedPlanType(_ rawValue: String?) -> String? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }

        return rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func fetch2xStatus() async -> Codex2xStatus? {
        if let cached = Self.cached2x,
           let cacheDate = Self.cached2xDate,
           Date().timeIntervalSince(cacheDate) < Self.twoXCacheTTL {
            return cached
        }

        if let jsonStatus = await fetch2xStatusFromJSON() {
            Self.cached2x = jsonStatus
            Self.cached2xDate = Date()
            return jsonStatus
        }

        if let htmlStatus = await fetch2xStatusFromHTML() {
            Self.cached2x = htmlStatus
            Self.cached2xDate = Date()
            return htmlStatus
        }

        return Self.cached2x
    }

    private func fetch2xStatusFromJSON() async -> Codex2xStatus? {
        guard let url = URL(string: "https://iscodex2x.com/json") else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }

            let decoded = try JSONDecoder().decode(Codex2xResponse.self, from: data)
            let deadline: String? = decoded.expiresInSeconds.map {
                let endDate = Date().addingTimeInterval(Double($0))
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d, yyyy"
                return fmt.string(from: endDate)
            }
            return Codex2xStatus(is2x: decoded.is2x, expiresIn: decoded.expiresIn, deadlineDate: deadline)
        } catch {
            return nil
        }
    }

    private func fetch2xStatusFromHTML() async -> Codex2xStatus? {
        guard let url = URL(string: "https://iscodex2x.com/") else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }

            return parse2xStatusFromHTML(html)
        } catch {
            return nil
        }
    }

    private func parse2xStatusFromHTML(_ html: String) -> Codex2xStatus? {
        let normalized = html.replacingOccurrences(of: "\n", with: " ")

        guard normalized.localizedCaseInsensitiveContains("Is Codex 2x?") else {
            return nil
        }

        let is2x = normalized.localizedCaseInsensitiveContains(">YES<")
            || normalized.localizedCaseInsensitiveContains(" YES ")
            || normalized.localizedCaseInsensitiveContains("Around the clock 2x usage")

        guard is2x else {
            return Codex2xStatus(is2x: false)
        }

        let deadlineText = extractDeadlineText(from: normalized)
        let expiresIn = deadlineText.flatMap { relativeCountdownText(fromDeadlineText: $0) }
        let prettyDeadline = deadlineText.flatMap { prettyDate(fromDeadlineText: $0) }
        return Codex2xStatus(is2x: true, expiresIn: expiresIn, deadlineDate: prettyDeadline)
    }

    private func extractDeadlineText(from html: String) -> String? {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        let patterns = [
            #"Deadline\s*[—-]\s*([A-Za-z]+ \d{1,2}, \d{4})"#,
            #"deadline is\s+([A-Za-z]+ \d{1,2}, \d{4})"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
            guard let match = regex.firstMatch(in: stripped, options: [], range: range),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: stripped) else {
                continue
            }

            let text = String(stripped[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }

        return nil
    }

    private func relativeCountdownText(fromDeadlineText text: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMMM d, yyyy"

        guard let date = formatter.date(from: text) else {
            return nil
        }

        // Inference from the public page: the promo remains active through the stated deadline date.
        let deadline = Calendar(identifier: .gregorian).date(byAdding: DateComponents(day: 1, second: -1), to: date) ?? date
        let remaining = max(0, Int(deadline.timeIntervalSinceNow))

        guard remaining > 0 else {
            return nil
        }

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60

        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m \(seconds)s"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private func prettyDate(fromDeadlineText text: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "MMMM d, yyyy"

        guard let date = parser.date(from: text) else { return nil }

        let output = DateFormatter()
        output.dateFormat = "MMM d, yyyy"
        return output.string(from: date)
    }

}
