import Foundation

final class CodexAdapter: ProviderAdapter {
    let kind: ProviderKind = .codex
    private let rootURL: URL
    private let fileManager: FileManager

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
        let accountLabel = [appServerSnapshot.account?.email, prettifiedPlanType(appServerSnapshot.account?.planType)]
            .compactMap { $0 }
            .joined(separator: " · ")

        var windows: [UsageWindow] = []
        if let weeklyWindow {
            windows.append(weeklyWindow)
        }

        return ProviderSnapshot(
            provider: kind,
            status: weeklyWindow != nil ? .ok : .warning,
            lastUpdated: lastUpdated,
            sourceDescription: "Codex Desktop app-server",
            accountLabel: accountLabel.isEmpty ? nil : accountLabel,
            badge: prettifiedPlanType(appServerSnapshot.account?.planType),
            message: weeklyWindow == nil ? "No weekly rate limit window was found from the Codex app-server." : nil,
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
}
