import Foundation

final class WindsurfAdapter: ProviderAdapter {
    private struct CachedPlanInfo: Decodable {
        var planName: String?
        var startTimestamp: Double?
        var endTimestamp: Double?
        var usage: UsageBlock?

        struct UsageBlock: Decodable {
            var messages: Double?
            var usedMessages: Double?
            var remainingMessages: Double?
            var flowActions: Double?
            var usedFlowActions: Double?
            var remainingFlowActions: Double?
            var flexCredits: Double?
            var usedFlexCredits: Double?
            var remainingFlexCredits: Double?
        }
    }

    let kind: ProviderKind = .windsurf
    private let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Windsurf"),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    var observedURLs: [URL] {
        [
            rootURL.appending(path: "User/globalStorage/state.vscdb"),
        ]
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

        let database = try SQLiteDatabase(readOnly: databaseURL)
        let planJSON = try database.fetchFirstString(
            query: "SELECT value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo';"
        )

        let lastUpdated = fileManager.modificationDate(for: databaseURL)

        guard let planJSON, let planData = planJSON.data(using: .utf8),
              let plan = try? JSONDecoder().decode(CachedPlanInfo.self, from: planData) else {
            return .unavailable(
                provider: kind,
                sourceDescription: "Windsurf state.vscdb found but cachedPlanInfo missing",
                message: "Windsurf is installed but no plan info was found in local state."
            )
        }

        var windows: [UsageWindow] = []

        // Windsurf stores raw values that are 100× the displayed credit numbers
        let divisor: Double = 100

        if let usage = plan.usage {
            let resetDate = plan.endTimestamp.map { Date(timeIntervalSince1970: $0 / 1000) }

            if let total = usage.messages, total > 0 {
                let remaining = usage.remainingMessages ?? (total - (usage.usedMessages ?? 0))
                let used = total - remaining
                windows.append(UsageWindow(
                    id: "prompt_credits",
                    label: "Prompt Credits",
                    usedAmount: used / divisor,
                    totalAmount: total / divisor,
                    percentUsed: nil,
                    resetDate: resetDate,
                    note: "\(Self.formatCredits(remaining / divisor)) remaining",
                    isFallback: false
                ))
            }

            if let total = usage.flexCredits, total > 0 {
                let remaining = usage.remainingFlexCredits ?? (total - (usage.usedFlexCredits ?? 0))
                let used = total - remaining
                windows.append(UsageWindow(
                    id: "addon_credits",
                    label: "Add-on Credits",
                    usedAmount: used / divisor,
                    totalAmount: total / divisor,
                    percentUsed: nil,
                    resetDate: resetDate,
                    note: "\(Self.formatCredits(remaining / divisor)) remaining",
                    isFallback: false
                ))
            }

            if let total = usage.flowActions, total > 0 {
                let remaining = usage.remainingFlowActions ?? (total - (usage.usedFlowActions ?? 0))
                let used = total - remaining
                windows.append(UsageWindow(
                    id: "flow_actions",
                    label: "Flow Actions",
                    usedAmount: used / divisor,
                    totalAmount: total / divisor,
                    percentUsed: nil,
                    resetDate: resetDate,
                    note: "\(Self.formatCredits(remaining / divisor)) remaining",
                    isFallback: false
                ))
            }
        }

        let accountLabel = plan.planName.map { "Windsurf \($0)" }

        return ProviderSnapshot(
            provider: kind,
            status: windows.isEmpty ? .warning : .ok,
            lastUpdated: lastUpdated,
            sourceDescription: "Local Windsurf cachedPlanInfo",
            accountLabel: accountLabel,
            badge: plan.planName,
            message: windows.isEmpty ? "Plan info was found but contained no usage data." : nil,
            windows: windows
        )
    }

    private static func formatCredits(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
