import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case codex
    case claude
    case antigravity
    case windsurf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .antigravity:
            return "Antigravity"
        case .windsurf:
            return "Windsurf"
        }
    }

    var shortLabel: String {
        switch self {
        case .codex:
            return "CX"
        case .claude:
            return "CL"
        case .antigravity:
            return "AG"
        case .windsurf:
            return "WS"
        }
    }
}

// MARK: - Usage Window

struct UsageWindow: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var usedAmount: Double?
    var totalAmount: Double?
    var percentUsed: Double?
    var resetDate: Date?
    var note: String?
    var isFallback: Bool

    var resolvedPercentUsed: Double? {
        if let percentUsed {
            return min(max(percentUsed, 0), 1)
        }

        guard let usedAmount, let totalAmount, totalAmount > 0 else {
            return nil
        }

        return min(max(usedAmount / totalAmount, 0), 1)
    }

    var usageSummary: String {
        if let used = usedAmount, let total = totalAmount {
            return "\(Self.trimmed(used)) / \(Self.trimmed(total))"
        }

        if let percent = resolvedPercentUsed {
            return "\(Int((percent * 100).rounded()))%"
        }

        return "—"
    }

    private static func trimmed(_ value: Double) -> String {
        if value.rounded() == value && value < 1_000_000 {
            return String(Int(value))
        }

        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }

        return String(format: "%.1f", value)
    }

    static func unavailable(id: String, label: String, note: String? = nil) -> UsageWindow {
        UsageWindow(
            id: id,
            label: label,
            usedAmount: nil,
            totalAmount: nil,
            percentUsed: nil,
            resetDate: nil,
            note: note,
            isFallback: false
        )
    }
}

// MARK: - Provider Snapshot

enum ProviderStatus: String, Codable, Hashable {
    case ok
    case warning
    case error

    var title: String {
        switch self {
        case .ok:
            return "Healthy"
        case .warning:
            return "Warning"
        case .error:
            return "Error"
        }
    }
}

struct ProviderSnapshot: Codable, Hashable {
    var provider: ProviderKind
    var status: ProviderStatus
    var lastUpdated: Date?
    var sourceDescription: String
    var accountLabel: String?
    var badge: String?
    var message: String?
    var windows: [UsageWindow]

    func window(id: String) -> UsageWindow? {
        windows.first(where: { $0.id == id })
    }

    var maxPercentUsed: Double? {
        windows.compactMap(\.resolvedPercentUsed).max()
    }

    static func unavailable(
        provider: ProviderKind,
        status: ProviderStatus = .warning,
        sourceDescription: String,
        message: String?
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            status: status,
            lastUpdated: nil,
            sourceDescription: sourceDescription,
            accountLabel: nil,
            badge: nil,
            message: message,
            windows: []
        )
    }
}

// MARK: - Claude 2x Status

struct Claude2xStatus: Codable, Hashable {
    var is2x: Bool
    var isPeak: Bool
    var isWeekend: Bool
    var promoActive: Bool
    var expiresInSeconds: Int?
    var expiresInText: String?
    var fetchedAt: Date

    var displayText: String {
        if is2x {
            if let text = expiresInText {
                return "2× active · ends in \(text)"
            }
            return "2× active"
        }

        if isPeak {
            if let text = expiresInText {
                return "1× (peak hours) · ends in \(text)"
            }
            return "1× (peak hours)"
        }

        return "1× standard"
    }
}

// MARK: - Bar Display Mode

enum BarDisplayMode: String, Codable, CaseIterable {
    case merged
    case separate

    var title: String {
        switch self {
        case .merged:
            return "Merged Icons"
        case .separate:
            return "Separate Icons"
        }
    }
}

// MARK: - Settings

struct ManualWindowOverride: Codable, Hashable {
    var enabled: Bool = false
    var totalLimit: Double?
    var usedAmount: Double?
    var usedPercent: Double?
    var resetDate: Date?
}

struct ManualProviderOverride: Codable, Hashable {
    var session: ManualWindowOverride = .init()
    var weekly: ManualWindowOverride = .init()

    func windowOverride(for windowId: String) -> ManualWindowOverride {
        switch windowId {
        case "session":
            return session
        case "weekly":
            return weekly
        default:
            return .init()
        }
    }
}

struct AppSettings: Codable, Hashable {
    var enabledProviders: [ProviderKind]
    var barDisplayMode: BarDisplayMode
    var refreshInterval: TimeInterval
    var manualOverrides: [String: ManualProviderOverride]

    static let `default` = AppSettings(
        enabledProviders: ProviderKind.allCases,
        barDisplayMode: .merged,
        refreshInterval: 60,
        manualOverrides: [:]
    )

    func manualOverride(for provider: ProviderKind) -> ManualProviderOverride {
        manualOverrides[provider.rawValue] ?? .init()
    }
}
