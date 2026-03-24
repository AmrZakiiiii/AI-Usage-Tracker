import Foundation

final class WindsurfAdapter: ProviderAdapter {

    // MARK: - Data models

    /// Legacy billing-period plan data from cachedPlanInfo JSON
    private struct CachedPlanInfo: Decodable {
        var planName: String?
        var startTimestamp: Double?
        var endTimestamp: Double?
        var billingStrategy: String?
        var quotaUsage: QuotaUsage?
        var usage: UsageBlock?

        struct QuotaUsage: Decodable {
            var dailyRemainingPercent: Double?
            var weeklyRemainingPercent: Double?
            var overageBalanceMicros: Double?
            var dailyResetAtUnix: Double?
            var weeklyResetAtUnix: Double?
        }

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

    /// Quota data extracted from the protobuf in windsurfAuthStatus
    private struct ProtobufQuota {
        var dailyRemainingPercent: Int = 100
        var weeklyRemainingPercent: Int = 100
        var overageBalanceMicros: Int = 0
        var dailyResetUnix: Int = 0
        var weeklyResetUnix: Int = 0
        var totalMessages: Int = 0
        var totalFlowActions: Int = 0
        var totalFlexCredits: Int = 0
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

        let database = try SQLiteDatabase(readOnly: databaseURL)
        let lastUpdated = fileManager.modificationDate(for: databaseURL)

        // Read plan info for plan name and period
        let planJSON = try database.fetchFirstString(
            query: "SELECT value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo';"
        )
        let plan: CachedPlanInfo? = planJSON.flatMap { json in
            json.data(using: .utf8).flatMap { try? JSONDecoder().decode(CachedPlanInfo.self, from: $0) }
        }

        // Read quota data from protobuf in windsurfAuthStatus
        let authJSON = try database.fetchFirstString(
            query: "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus';"
        )
        let quota = authJSON.flatMap { parseQuotaFromAuthStatus($0) }

        var windows: [UsageWindow] = []

        if let q = quota {
            let dailyUsedPct = Double(100 - q.dailyRemainingPercent)
            let weeklyUsedPct = Double(100 - q.weeklyRemainingPercent)

            let dailyReset = q.dailyResetUnix > 0
                ? Date(timeIntervalSince1970: Double(q.dailyResetUnix))
                : nil
            let weeklyReset = q.weeklyResetUnix > 0
                ? Date(timeIntervalSince1970: Double(q.weeklyResetUnix))
                : nil

            // Daily quota usage
            windows.append(UsageWindow(
                id: "daily_quota",
                label: "Daily Quota Usage",
                usedAmount: nil,
                totalAmount: nil,
                percentUsed: dailyUsedPct / 100.0,
                resetDate: dailyReset,
                note: dailyReset.map { "Resets \(Self.formatResetDate($0))" },
                isFallback: false
            ))

            // Weekly quota usage
            windows.append(UsageWindow(
                id: "weekly_quota",
                label: "Weekly Quota Usage",
                usedAmount: nil,
                totalAmount: nil,
                percentUsed: weeklyUsedPct / 100.0,
                resetDate: weeklyReset,
                note: weeklyReset.map { "Resets \(Self.formatResetDate($0))" },
                isFallback: false
            ))

            // Extra usage balance
            if q.overageBalanceMicros > 0 {
                let balance = Double(q.overageBalanceMicros) / 1_000_000.0
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
        } else {
            // Fallback: use cachedPlanInfo if protobuf parsing fails
            if let plan, let usage = plan.usage {
                let divisor: Double = 100
                let planEnd = plan.endTimestamp.map { Date(timeIntervalSince1970: $0 / 1000) }

                if let total = usage.messages, total > 0 {
                    let usedDisp = (usage.usedMessages ?? 0) / divisor
                    let totalDisp = total / divisor
                    let remainDisp = (usage.remainingMessages ?? (total - (usage.usedMessages ?? 0))) / divisor
                    windows.append(UsageWindow(
                        id: "prompt_credits",
                        label: "Prompt Credits",
                        usedAmount: usedDisp,
                        totalAmount: totalDisp,
                        percentUsed: usedDisp / totalDisp,
                        resetDate: planEnd,
                        note: "\(Self.formatCredits(remainDisp)) remaining",
                        isFallback: false
                    ))
                }
            }
        }

        let planEnd = plan?.endTimestamp.map { Date(timeIntervalSince1970: $0 / 1000) }
        let planStart = plan?.startTimestamp.map { Date(timeIntervalSince1970: $0 / 1000) }
        let accountLabel = plan?.planName.map { "Windsurf \($0)" }
        let planPeriod = formatPlanPeriod(start: planStart, end: planEnd)

        return ProviderSnapshot(
            provider: kind,
            status: windows.isEmpty ? .warning : .ok,
            lastUpdated: lastUpdated,
            sourceDescription: "Local Windsurf state",
            accountLabel: accountLabel,
            badge: plan?.planName,
            message: windows.isEmpty ? "No quota data found." : planPeriod,
            windows: windows
        )
    }

    // MARK: - Protobuf parsing

    /// Parse quota data from the windsurfAuthStatus JSON (contains base64 protobuf)
    private func parseQuotaFromAuthStatus(_ jsonString: String) -> ProtobufQuota? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["userStatusProtoBinaryBase64"] as? String,
              let protoData = Data(base64Encoded: b64) else {
            return nil
        }

        // Parse top-level protobuf to find field 13 (plan status)
        let topFields = parseProtobuf(Array(protoData))
        guard let planField = topFields.first(where: { $0.fieldNum == 13 }),
              case .lengthDelimited(let planBytes) = planField.value else {
            return nil
        }

        // Parse field 13 to find the quota sub-fields
        let planFields = parseProtobuf(planBytes)
        var quota = ProtobufQuota()

        for field in planFields {
            switch field.fieldNum {
            case 4:
                if case .varint(let v) = field.value { quota.totalFlexCredits = Int(v) }
            case 8:
                if case .varint(let v) = field.value { quota.totalMessages = Int(v) }
            case 9:
                if case .varint(let v) = field.value { quota.totalFlowActions = Int(v) }
            case 14:
                if case .varint(let v) = field.value { quota.dailyRemainingPercent = Int(v) }
            case 15:
                if case .varint(let v) = field.value { quota.weeklyRemainingPercent = Int(v) }
            case 16:
                if case .varint(let v) = field.value { quota.overageBalanceMicros = Int(v) }
            case 17:
                if case .varint(let v) = field.value { quota.dailyResetUnix = Int(v) }
            case 18:
                if case .varint(let v) = field.value { quota.weeklyResetUnix = Int(v) }
            default:
                break
            }
        }

        // Validate we got meaningful data
        guard quota.dailyResetUnix > 0 || quota.weeklyResetUnix > 0 else {
            return nil
        }

        return quota
    }

    // MARK: - Minimal protobuf wire-format decoder

    private struct ProtoField {
        let fieldNum: Int
        let value: ProtoValue
    }

    private enum ProtoValue {
        case varint(UInt64)
        case fixed64(UInt64)
        case lengthDelimited([UInt8])
        case fixed32(UInt32)
    }

    private func parseProtobuf(_ data: [UInt8]) -> [ProtoField] {
        var fields: [ProtoField] = []
        var i = 0

        while i < data.count {
            guard let (tag, nextI) = readVarint(data, at: i) else { break }
            i = nextI
            let fieldNum = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            switch wireType {
            case 0: // varint
                guard let (val, nextI) = readVarint(data, at: i) else { break }
                i = nextI
                fields.append(ProtoField(fieldNum: fieldNum, value: .varint(val)))
            case 1: // 64-bit
                guard i + 8 <= data.count else { break }
                let val = data[i..<i+8].withUnsafeBufferPointer { ptr -> UInt64 in
                    ptr.baseAddress!.withMemoryRebound(to: UInt64.self, capacity: 1) { $0.pointee }
                }
                i += 8
                fields.append(ProtoField(fieldNum: fieldNum, value: .fixed64(val)))
            case 2: // length-delimited
                guard let (length, nextI) = readVarint(data, at: i) else { break }
                i = nextI
                let len = Int(length)
                guard i + len <= data.count else { break }
                fields.append(ProtoField(fieldNum: fieldNum, value: .lengthDelimited(Array(data[i..<i+len]))))
                i += len
            case 5: // 32-bit
                guard i + 4 <= data.count else { break }
                let val = data[i..<i+4].withUnsafeBufferPointer { ptr -> UInt32 in
                    ptr.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
                }
                i += 4
                fields.append(ProtoField(fieldNum: fieldNum, value: .fixed32(val)))
            default:
                return fields // unknown wire type, stop
            }
        }

        return fields
    }

    private func readVarint(_ data: [UInt8], at start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start

        while i < data.count {
            let byte = data[i]
            result |= UInt64(byte & 0x7F) << shift
            shift += 7
            i += 1
            if byte & 0x80 == 0 {
                return (result, i)
            }
            if shift >= 64 { return nil }
        }

        return nil
    }

    // MARK: - Formatting helpers

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

    private static func formatCredits(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
