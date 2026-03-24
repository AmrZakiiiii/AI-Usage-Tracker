import Foundation

enum KeychainHelper {
    struct ClaudeCredentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var subscriptionType: String?
        var rateLimitTier: String?
    }

    // MARK: - Cache file path

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/ai-usage-tracker-token-cache.json")
    }

    // MARK: - Public API

    /// Reads Claude Code OAuth credentials.
    ///
    /// Strategy:
    /// 1. Try the local token cache (no prompt, no Keychain).
    /// 2. If expired/missing, re-read from Keychain via the `security` CLI
    ///    (this binary is already trusted — no password prompt).
    /// 3. Last resort: Security framework (may prompt once).
    static func readClaudeCredentials() -> ClaudeCredentials? {
        // 1. Try cached token — completely silent
        if let cached = readFromCache(), !isExpired(cached) {
            return cached
        }

        // 2. Re-read from Keychain via security CLI (no prompt)
        if let fresh = readViaSecurityCLIWithStateFile() {
            writeToCache(fresh)
            return fresh
        }

        // 3. Direct CLI without state file
        if let fresh = readViaSecurityCLI() {
            writeToCache(fresh)
            return fresh
        }

        // 4. Last resort: Security framework (may prompt)
        if let fresh = readViaSecurityFramework() {
            writeToCache(fresh)
            return fresh
        }

        return nil
    }

    /// Force re-read credentials from Keychain, bypassing cache.
    /// Called when the API returns 401 (token revoked by Claude Code refresh).
    static func forceRefreshCredentials() -> ClaudeCredentials? {
        // Try CLI first (no prompt)
        if let fresh = readViaSecurityCLIWithStateFile() {
            writeToCache(fresh)
            return fresh
        }
        if let fresh = readViaSecurityCLI() {
            writeToCache(fresh)
            return fresh
        }
        // Last resort
        if let fresh = readViaSecurityFramework() {
            writeToCache(fresh)
            return fresh
        }
        return nil
    }

    // MARK: - Local token cache

    private static func readFromCache() -> ClaudeCredentials? {
        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["accessToken"] as? String else {
            return nil
        }

        let refreshToken = json["refreshToken"] as? String
        let expiresAtMs = json["expiresAt"] as? Double
        let subscriptionType = json["subscriptionType"] as? String
        let rateLimitTier = json["rateLimitTier"] as? String

        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier
        )
    }

    private static func isExpired(_ creds: ClaudeCredentials) -> Bool {
        guard let expiresAt = creds.expiresAt else { return false }
        // Consider expired 5 minutes early to allow refresh
        return expiresAt.addingTimeInterval(-300) < Date()
    }

    static func writeToCache(_ creds: ClaudeCredentials) {
        var json: [String: Any] = ["accessToken": creds.accessToken]
        if let r = creds.refreshToken { json["refreshToken"] = r }
        if let e = creds.expiresAt { json["expiresAt"] = e.timeIntervalSince1970 * 1000 }
        if let s = creds.subscriptionType { json["subscriptionType"] = s }
        if let t = creds.rateLimitTier { json["rateLimitTier"] = t }

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return
        }

        FileManager.default.createFile(atPath: cacheURL.path, contents: data, attributes: [
            .posixPermissions: 0o600
        ])
    }

    // MARK: - Keychain via Security framework

    private static func readViaSecurityFramework() -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return parseCredentialJSON(data)
    }

    // MARK: - Keychain via security CLI + state file

    private static func readViaSecurityCLIWithStateFile() -> ClaudeCredentials? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let stateURL = homeDir.appending(path: ".claude.json")

        let billingType: String? = {
            guard let data = try? Data(contentsOf: stateURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["oauthAccount"] as? [String: Any] else {
                return nil
            }
            return account["billingType"] as? String
        }()

        guard let cliCreds = readViaSecurityCLI() else { return nil }

        return ClaudeCredentials(
            accessToken: cliCreds.accessToken,
            refreshToken: cliCreds.refreshToken,
            expiresAt: cliCreds.expiresAt,
            subscriptionType: cliCreds.subscriptionType ?? billingType,
            rateLimitTier: cliCreds.rateLimitTier
        )
    }

    private static func readViaSecurityCLI() -> ClaudeCredentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-g",
        ]

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        guard let passwordData = extractPasswordData(from: errorOutput) else {
            return nil
        }

        return parseCredentialJSON(passwordData)
    }

    // MARK: - Parsing helpers

    private static func extractPasswordData(from output: String) -> Data? {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("password: \"") && trimmed.hasSuffix("\"") {
                let start = trimmed.index(trimmed.startIndex, offsetBy: 11)
                let end = trimmed.index(trimmed.endIndex, offsetBy: -1)
                let escaped = String(trimmed[start..<end])
                let unescaped = escaped
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                    .replacingOccurrences(of: "\\n", with: "\n")
                return unescaped.data(using: .utf8)
            }

            if trimmed.hasPrefix("password: 0x") {
                let hexStart = trimmed.index(trimmed.startIndex, offsetBy: 12)
                let hex = String(trimmed[hexStart...])
                return dataFromHex(hex)
            }
        }

        return nil
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        var data = Data()
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            let byteString = String(hex[index..<nextIndex])
            guard let byte = UInt8(byteString, radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        return data
    }

    private static func parseCredentialJSON(_ data: Data) -> ClaudeCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Handle nested format: { "claudeAiOauth": { "accessToken": ... } }
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let accessToken = oauth["accessToken"] as? String {
            let refreshToken = oauth["refreshToken"] as? String
            let expiresAtMs = oauth["expiresAt"] as? Double
            let subscriptionType = oauth["subscriptionType"] as? String
            let rateLimitTier = oauth["rateLimitTier"] as? String

            return ClaudeCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                subscriptionType: subscriptionType,
                rateLimitTier: rateLimitTier
            )
        }

        // Fallback: flat format with dot-notation keys
        guard let accessToken = json["claudeAiOauth.accessToken"] as? String else {
            return nil
        }

        let refreshToken = json["claudeAiOauth.refreshToken"] as? String
        let expiresAtMs = json["claudeAiOauth.expiresAt"] as? Double
        let subscriptionType = json["claudeAiOauth.subscriptionType"] as? String
        let rateLimitTier = json["claudeAiOauth.rateLimitTier"] as? String

        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier
        )
    }
}
