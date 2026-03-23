import Foundation

final class AntigravityAdapter: ProviderAdapter {
    private struct AuthStatus: Decodable {
        var name: String?
        var email: String?
        var userStatusProtoBinaryBase64: String?
    }

    struct ModelQuota {
        var name: String
        var modelId: Int
        var quotaRemaining: Double  // 0.0 to 1.0
        var refreshTimestamp: Int    // Unix epoch seconds
    }

    let kind: ProviderKind = .antigravity
    private let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Antigravity"),
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
                sourceDescription: "Expected Antigravity globalStorage state.vscdb",
                message: "No Antigravity local state database was found."
            )
        }

        let database = try SQLiteDatabase(readOnly: databaseURL)
        let query = """
        SELECT key, value
        FROM ItemTable
        WHERE key = 'antigravityAuthStatus'
           OR key = 'antigravityUnifiedStateSync.modelCredits'
           OR key = 'antigravityUnifiedStateSync.userStatus';
        """
        let values = try database.fetchKeyValueMap(query: query)
        let lastUpdated = fileManager.modificationDate(for: databaseURL)

        let authStatus = parseAuthStatus(from: values["antigravityAuthStatus"])
        let accountParts = [authStatus?.name, authStatus?.email].compactMap { $0 }.filter { !$0.isEmpty }

        // Extract plan name
        let decodedStrings = LocalSnapshotParsing.decodedASCIIStrings(fromBase64Encoded: authStatus?.userStatusProtoBinaryBase64)
        let plan = LocalSnapshotParsing.firstContainingSubstring(in: decodedStrings, substring: "Google AI Pro")
            ?? LocalSnapshotParsing.firstContainingSubstring(in: decodedStrings, substring: "Google AI Ultra")

        // Extract per-model quotas from protobuf
        let modelQuotas = extractModelQuotas(from: authStatus?.userStatusProtoBinaryBase64)

        // Extract credits
        let credits = parseModelCredits(from: values["antigravityUnifiedStateSync.modelCredits"])

        // Build windows
        var windows: [UsageWindow] = []

        // AI Credits window
        if let credits {
            let threshold = credits.minimumCreditAmountForUsage ?? 0
            windows.append(UsageWindow(
                id: "credits",
                label: "AI Credits",
                usedAmount: nil,
                totalAmount: Double(credits.availableCredits),
                percentUsed: nil,
                resetDate: nil,
                note: threshold > 0 ? "Min \(threshold) credits per use" : nil,
                isFallback: false
            ))
        }

        // Per-model quota windows
        for quota in modelQuotas {
            let used = 1.0 - quota.quotaRemaining
            let refreshDate = Date(timeIntervalSince1970: TimeInterval(quota.refreshTimestamp))

            windows.append(UsageWindow(
                id: "model_\(quota.modelId)",
                label: quota.name,
                usedAmount: nil,
                totalAmount: nil,
                percentUsed: used,
                resetDate: refreshDate,
                note: nil,
                isFallback: false
            ))
        }

        return ProviderSnapshot(
            provider: kind,
            status: !modelQuotas.isEmpty || credits != nil ? .ok : .warning,
            lastUpdated: lastUpdated,
            sourceDescription: "Local Antigravity globalStorage",
            accountLabel: accountParts.isEmpty ? nil : accountParts.joined(separator: " · "),
            badge: plan != nil ? "Pro" : nil,
            message: plan,
            windows: windows
        )
    }

    // MARK: - Per-model protobuf parsing

    private func extractModelQuotas(from base64: String?) -> [ModelQuota] {
        guard let base64, let outerData = Data(base64Encoded: base64) else {
            return []
        }

        // The userStatus protobuf may contain an inner base64-encoded protobuf
        // Try to find and parse model entries from the data
        var quotas: [ModelQuota] = []

        // Extract all length-delimited messages that look like model entries
        // Model entries have: field 1 (name string), field 2.1 (model ID varint),
        // field 15.1 (float32 quota ratio), field 15.2.1 (varint refresh timestamp)
        let modelEntries = AntigravityProtobufParser.extractModelEntries(from: outerData)
        quotas.append(contentsOf: modelEntries)

        // If we didn't find entries in the outer layer, look for an inner base64 payload
        if quotas.isEmpty {
            let strings = LocalSnapshotParsing.asciiStrings(from: outerData, minimumLength: 10)
            for string in strings {
                if let innerData = Data(base64Encoded: string) {
                    let innerEntries = AntigravityProtobufParser.extractModelEntries(from: innerData)
                    if !innerEntries.isEmpty {
                        quotas.append(contentsOf: innerEntries)
                        break
                    }
                }
            }
        }

        return quotas
    }

    // MARK: - Credits parsing

    private func parseAuthStatus(from rawValue: String?) -> AuthStatus? {
        guard let rawValue, let data = rawValue.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AuthStatus.self, from: data)
    }

    private func parseModelCredits(from rawValue: String?) -> (availableCredits: Int, minimumCreditAmountForUsage: Int?)? {
        guard let rawValue, let data = Data(base64Encoded: rawValue) else { return nil }

        let strings = LocalSnapshotParsing.asciiStrings(from: data)
        var availableCredits: Int?
        var minimumCreditAmountForUsage: Int?

        for (index, string) in strings.enumerated() {
            guard index + 1 < strings.count else { continue }

            if string == "availableCreditsSentinelKey" {
                availableCredits = LocalSnapshotParsing.decodeEmbeddedVarint(fromBase64Encoded: strings[index + 1])
            } else if string == "minimumCreditAmountForUsageKey" {
                minimumCreditAmountForUsage = LocalSnapshotParsing.decodeEmbeddedVarint(fromBase64Encoded: strings[index + 1])
            }
        }

        guard let availableCredits else { return nil }
        return (availableCredits, minimumCreditAmountForUsage)
    }
}

// MARK: - Protobuf parser for Antigravity model entries

enum AntigravityProtobufParser {
    static func extractModelEntries(from data: Data) -> [AntigravityAdapter.ModelQuota] {
        var quotas: [AntigravityAdapter.ModelQuota] = []
        let bytes = Array(data)

        // Known model names to match against
        let knownModels = [
            "Gemini 3.1 Pro (High)",
            "Gemini 3.1 Pro (Low)",
            "Gemini 3 Flash",
            "Claude Sonnet 4.6 (Thinking)",
            "Claude Opus 4.6 (Thinking)",
            "GPT-OSS 120B (Medium)",
        ]

        // Scan for each known model name in the binary data
        for modelName in knownModels {
            let nameBytes = Array(modelName.utf8)
            guard let nameOffset = findSubsequence(bytes, nameBytes) else {
                continue
            }

            // Find the start of the containing message by looking backwards for a length prefix
            // Then parse forward from the model name to find field 15 (quota)
            if let quota = parseModelQuotaAroundName(bytes: bytes, nameOffset: nameOffset, name: modelName) {
                quotas.append(quota)
            }
        }

        return quotas
    }

    private static func parseModelQuotaAroundName(bytes: [UInt8], nameOffset: Int, name: String) -> AntigravityAdapter.ModelQuota? {
        // After the name string, scan forward for:
        // - A model ID (field 2, which is a submessage containing field 1 varint)
        // - A quota message (field 15, containing field 1 float32 and field 2 submessage with field 1 varint timestamp)

        var modelId = 0
        var quotaRemaining: Double = 1.0
        var refreshTimestamp = 0

        // Scan a region after the name (within ~200 bytes)
        let searchStart = nameOffset + name.utf8.count
        let searchEnd = min(bytes.count, searchStart + 300)

        if searchEnd <= searchStart {
            return nil
        }

        let region = Array(bytes[searchStart..<searchEnd])

        // Look for field 2 (tag = 0x12, length-delimited) containing a varint model ID
        // field 2 wire type 2 = tag 18 (0x12)
        if let idOffset = findByte(region, 0x12) {
            let afterTag = idOffset + 1
            if afterTag < region.count {
                if let (length, lenSize) = decodeVarint(region, offset: afterTag) {
                    let contentStart = afterTag + lenSize
                    if contentStart < region.count && length > 0 && length < 10 {
                        // Inside: field 1 varint (tag 0x08)
                        if region[contentStart] == 0x08 {
                            if let (id, _) = decodeVarint(region, offset: contentStart + 1) {
                                modelId = id
                            }
                        }
                    }
                }
            }
        }

        // Look for field 15 (tag = 0x7A, length-delimited: (15 << 3) | 2 = 122 = 0x7A)
        if let f15Offset = findByte(region, 0x7A) {
            let afterTag = f15Offset + 1
            if afterTag < region.count {
                if let (length, lenSize) = decodeVarint(region, offset: afterTag) {
                    let contentStart = afterTag + lenSize
                    let contentEnd = min(region.count, contentStart + length)

                    if contentStart + 5 <= contentEnd {
                        let submsg = Array(region[contentStart..<contentEnd])

                        // field 1 (tag 0x0D = field 1 wire type 5 = 32-bit float)
                        if let floatOffset = findByte(submsg, 0x0D) {
                            let floatStart = floatOffset + 1
                            if floatStart + 4 <= submsg.count {
                                var floatValue: Float = 0
                                let floatBytes = Array(submsg[floatStart..<(floatStart + 4)])
                                withUnsafeMutableBytes(of: &floatValue) { ptr in
                                    for i in 0..<4 { ptr[i] = floatBytes[i] }
                                }
                                quotaRemaining = Double(floatValue)
                            }
                        }

                        // field 2 (tag 0x12 = field 2 wire type 2) containing field 1 varint (timestamp)
                        if let tsOffset = findByte(submsg, 0x12) {
                            let afterTsTag = tsOffset + 1
                            if afterTsTag < submsg.count {
                                if let (tsLen, tsLenSize) = decodeVarint(submsg, offset: afterTsTag) {
                                    let tsContentStart = afterTsTag + tsLenSize
                                    if tsContentStart < submsg.count && tsLen > 0 {
                                        // field 1 varint (tag 0x08)
                                        if submsg[tsContentStart] == 0x08 {
                                            if let (ts, _) = decodeVarint(submsg, offset: tsContentStart + 1) {
                                                refreshTimestamp = ts
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        guard refreshTimestamp > 0 else {
            // Still include the model even without refresh time if we found it
            return AntigravityAdapter.ModelQuota(
                name: name,
                modelId: modelId,
                quotaRemaining: quotaRemaining,
                refreshTimestamp: 0
            )
        }

        return AntigravityAdapter.ModelQuota(
            name: name,
            modelId: modelId,
            quotaRemaining: quotaRemaining,
            refreshTimestamp: refreshTimestamp
        )
    }

    private static func findSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        let limit = haystack.count - needle.count
        for i in 0...limit {
            if haystack[i..<(i + needle.count)].elementsEqual(needle) {
                return i
            }
        }
        return nil
    }

    private static func findByte(_ bytes: [UInt8], _ target: UInt8) -> Int? {
        bytes.firstIndex(of: target)
    }

    private static func decodeVarint(_ bytes: [UInt8], offset: Int) -> (value: Int, length: Int)? {
        var value = 0
        var shift = 0
        var i = offset

        while i < bytes.count {
            let byte = bytes[i]
            value |= Int(byte & 0x7F) << shift
            i += 1

            if byte & 0x80 == 0 {
                return (value, i - offset)
            }

            shift += 7
            if shift >= 63 { return nil }
        }

        return nil
    }
}
