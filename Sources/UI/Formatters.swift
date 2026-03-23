import Foundation

@MainActor
enum UsageFormatters {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func relativeResetText(for date: Date?) -> String {
        guard let date else {
            return "No reset date"
        }

        return "Resets \(relativeFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    static func absoluteResetText(for date: Date?) -> String {
        guard let date else {
            return ""
        }

        return absoluteFormatter.string(from: date)
    }

    static func freshnessText(for date: Date?) -> String {
        guard let date else {
            return "never"
        }

        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
