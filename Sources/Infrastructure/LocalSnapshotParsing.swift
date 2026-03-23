import Foundation

enum LocalSnapshotParsing {
    static func asciiStrings(from data: Data, minimumLength: Int = 4) -> [String] {
        var results: [String] = []
        var current = ""

        for byte in data {
            let scalar = UnicodeScalar(Int(byte))
            let isPrintable = scalar.map { $0.value >= 32 && $0.value <= 126 } ?? false

            if isPrintable, let scalar {
                current.unicodeScalars.append(scalar)
            } else if current.count >= minimumLength {
                results.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.removeAll(keepingCapacity: true)
            }
        }

        if current.count >= minimumLength {
            results.append(current)
        }

        return results
    }

    static func decodedASCIIStrings(fromBase64Encoded rawValue: String?) -> [String] {
        guard let rawValue, let data = Data(base64Encoded: rawValue) else {
            return []
        }

        return asciiStrings(from: data)
    }

    static func firstEmail(in strings: [String]) -> String? {
        strings.first(where: { $0.contains("@") && $0.contains(".") })
    }

    static func firstPlan(in strings: [String], candidates: [String]) -> String? {
        let normalizedCandidates = Set(candidates.map { $0.lowercased() })

        return strings.first {
            normalizedCandidates.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    static func firstContainingSubstring(in strings: [String], substring: String) -> String? {
        strings.first {
            $0.localizedCaseInsensitiveContains(substring)
        }
    }

    static func decodeEmbeddedVarint(fromBase64Encoded rawValue: String) -> Int? {
        guard let data = Data(base64Encoded: rawValue), data.count >= 2 else {
            return nil
        }

        var value = 0
        var shift = 0

        for byte in data.dropFirst() {
            value |= Int(byte & 0x7F) << shift

            if byte & 0x80 == 0 {
                return value
            }

            shift += 7
        }

        return nil
    }
}

enum AsyncTimeoutError: LocalizedError {
    case timedOut(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "The operation timed out after \(String(format: "%.1f", seconds)) seconds."
        }
    }
}

func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AsyncTimeoutError.timedOut(seconds: seconds)
        }

        guard let result = try await group.next() else {
            throw AsyncTimeoutError.timedOut(seconds: seconds)
        }

        group.cancelAll()
        return result
    }
}
