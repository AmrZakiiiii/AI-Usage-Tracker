import Foundation

final class WindsurfAdapter: ProviderAdapter {
    private struct CachedPlanInfo: Decodable {
        var planName: String?
        var startTimestamp: Double?
        var endTimestamp: Double?
        var usage: UsageBlock?

        struct UsageBlock: Decodable {
            var duration: Int?
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

        // Windsurf stores raw values at 100× the displayed credit numbers
        let divisor: Double = 100

        let planEnd = plan.endTimestamp.map { Date(timeIntervalSince1970: $0 / 1000) }
        let planStart = plan.startTimestamp.map { Date(timeIntervalSince1970: $0 / 1000) }

        // Build plan period note
        let periodNote = formatPlanPeriod(start: planStart, end: planEnd)

        if let usage = plan.usage {
            // Prompt Credits (messages)
            if let total = usage.messages, total > 0 {
                let totalDisp = total / divisor
                let usedDisp = (usage.usedMessages ?? 0) / divisor
                let remainDisp = (usage.remainingMessages ?? (total - (usage.usedMessages ?? 0))) / divisor
                let pct = usedDisp / totalDisp

                windows.append(UsageWindow(
                    id: "prompt_credits",
                    label: "Prompt Credits",
                    usedAmount: usedDisp,
                    totalAmount: totalDisp,
                    percentUsed: pct,
                    resetDate: planEnd,
                    note: "\(Self.formatCredits(remainDisp)) remaining · \(periodNote)",
                    isFallback: false
                ))
            }

            // Add-on / Flex Credits
            if let total = usage.flexCredits, total > 0 {
                let totalDisp = total / divisor
                let usedDisp = (usage.usedFlexCredits ?? 0) / divisor
                let remainDisp = (usage.remainingFlexCredits ?? (total - (usage.usedFlexCredits ?? 0))) / divisor
                let pct = totalDisp > 0 ? usedDisp / totalDisp : 0

                windows.append(UsageWindow(
                    id: "addon_credits",
                    label: "Add-on Credits",
                    usedAmount: usedDisp,
                    totalAmount: totalDisp,
                    percentUsed: pct,
                    resetDate: planEnd,
                    note: "\(Self.formatCredits(remainDisp)) remaining",
                    isFallback: false
                ))
            }

            // Flow Actions — only show if total > 0
            if let total = usage.flowActions, total > 0 {
                let totalDisp = total / divisor
                let usedDisp = (usage.usedFlowActions ?? 0) / divisor
                let remainDisp = (usage.remainingFlowActions ?? (total - (usage.usedFlowActions ?? 0))) / divisor
                let pct = totalDisp > 0 ? usedDisp / totalDisp : 0

                windows.append(UsageWindow(
                    id: "flow_actions",
                    label: "Flow Actions",
                    usedAmount: usedDisp,
                    totalAmount: totalDisp,
                    percentUsed: pct,
                    resetDate: planEnd,
                    note: "\(Self.formatCredits(remainDisp)) remaining",
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

    private func formatPlanPeriod(start: Date?, end: Date?) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"

        guard let end else { return "Plan period" }

        let now = Date()
        let daysLeft = Calendar.current.dateComponents([.day], from: now, to: end).day ?? 0

        let endStr = fmt.string(from: end)
        if let start {
            let startStr = fmt.string(from: start)
            return "Plan \(startStr) – \(endStr) (\(daysLeft)d left)"
        }
        return "Resets \(endStr) (\(daysLeft)d left)"
    }

    private static func formatCredits(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
