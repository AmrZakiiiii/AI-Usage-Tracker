import Foundation

struct CodexAccountRateLimitSnapshot {
    struct Account {
        var type: String?
        var email: String?
        var planType: String?
    }

    struct Window {
        var usedPercent: Double?
        var windowDurationMins: Int?
        var resetsAt: TimeInterval?
    }

    var account: Account?
    var primary: Window?
    var secondary: Window?
    var limitName: String?
}

actor CodexAppServerClient {
    static let shared = CodexAppServerClient()

    private struct RPCEnvelope<ResultType: Decodable & Sendable>: Decodable {
        struct RPCError: Decodable {
            var message: String
        }

        var id: Int?
        var result: ResultType?
        var error: RPCError?
    }

    private struct AccountReadResult: Decodable, Sendable {
        struct AccountPayload: Decodable, Sendable {
            var type: String?
            var email: String?
            var planType: String?
        }

        var account: AccountPayload?
    }

    private struct RateLimitReadResult: Decodable, Sendable {
        struct Snapshot: Decodable, Sendable {
            struct WindowPayload: Decodable, Sendable {
                var usedPercent: Double?
                var windowDurationMins: Int?
                var resetsAt: TimeInterval?
            }

            var limitName: String?
            var primary: WindowPayload?
            var secondary: WindowPayload?
        }

        var rateLimits: Snapshot?
    }

    private let serverURL = URL(string: "ws://127.0.0.1:8765")!
    private let healthURL = URL(string: "http://127.0.0.1:8765/healthz")!
    private let codexBinaryURL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")

    private var process: Process?
    private var ownsProcess = false
    private var nextRequestID = 1

    func readSnapshot() async throws -> CodexAccountRateLimitSnapshot {
        try await ensureServerRunning()

        let task = URLSession.shared.webSocketTask(with: serverURL)
        task.resume()

        defer {
            task.cancel(with: .normalClosure, reason: nil)
        }

        _ = try await sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "ai-usage-tracker",
                    "version": "0.1.0",
                ],
            ],
            over: task,
            resultType: EmptyResult.self
        )

        let accountResult = try await sendRequest(
            method: "account/read",
            params: ["refreshToken": false],
            over: task,
            resultType: AccountReadResult.self
        )

        let rateLimitResult = try await sendRequest(
            method: "account/rateLimits/read",
            params: NSNull(),
            over: task,
            resultType: RateLimitReadResult.self
        )

        return CodexAccountRateLimitSnapshot(
            account: accountResult.account.map {
                .init(type: $0.type, email: $0.email, planType: $0.planType)
            },
            primary: rateLimitResult.rateLimits?.primary.map {
                .init(
                    usedPercent: $0.usedPercent,
                    windowDurationMins: $0.windowDurationMins,
                    resetsAt: $0.resetsAt
                )
            },
            secondary: rateLimitResult.rateLimits?.secondary.map {
                .init(
                    usedPercent: $0.usedPercent,
                    windowDurationMins: $0.windowDurationMins,
                    resetsAt: $0.resetsAt
                )
            },
            limitName: rateLimitResult.rateLimits?.limitName
        )
    }

    func stopIfOwned() {
        guard ownsProcess, let process else {
            return
        }

        if process.isRunning {
            process.terminate()
        }

        self.process = nil
        ownsProcess = false
    }

    private func ensureServerRunning() async throws {
        if await isHealthy() {
            return
        }

        guard FileManager.default.fileExists(atPath: codexBinaryURL.path) else {
            throw NSError(
                domain: "CodexAppServerClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Codex Desktop binary was not found at \(codexBinaryURL.path)."]
            )
        }

        if process == nil || process?.isRunning == false {
            let process = Process()
            process.executableURL = codexBinaryURL
            process.arguments = ["app-server", "--listen", serverURL.absoluteString]

            let stdout = Pipe()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }

            let stderr = Pipe()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }

            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            self.process = process
            ownsProcess = true
        }

        try await withTimeout(seconds: 5) {
            while !Task.isCancelled {
                if await self.isHealthy() {
                    return
                }

                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 1

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func sendRequest<ResultType: Decodable & Sendable>(
        method: String,
        params: Any,
        over task: URLSessionWebSocketTask,
        resultType: ResultType.Type
    ) async throws -> ResultType {
        let id = nextRequestID
        nextRequestID += 1

        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let string = String(decoding: data, as: UTF8.self)
        try await task.send(.string(string))

        return try await withTimeout(seconds: 5) {
            while !Task.isCancelled {
                let message = try await task.receive()
                let responseData: Data

                switch message {
                case .string(let string):
                    responseData = Data(string.utf8)
                case .data(let data):
                    responseData = data
                @unknown default:
                    continue
                }

                let envelope = try JSONDecoder().decode(RPCEnvelope<ResultType>.self, from: responseData)

                guard envelope.id == id else {
                    continue
                }

                if let error = envelope.error {
                    throw NSError(
                        domain: "CodexAppServerClient",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: error.message]
                    )
                }

                guard let result = envelope.result else {
                    throw NSError(
                        domain: "CodexAppServerClient",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Codex app-server returned no result for \(method)."]
                    )
                }

                return result
            }

            throw AsyncTimeoutError.timedOut(seconds: 5)
        }
    }
}

private struct EmptyResult: Decodable, Sendable {}
