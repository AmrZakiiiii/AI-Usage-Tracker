import Foundation

enum KeychainHelper {
    struct ClaudeCredentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var subscriptionType: String?
        var rateLimitTier: String?
    }

    /// Reads Claude Code OAuth credentials from the macOS Keychain.
    ///
    /// Uses the `security` CLI tool to avoid repeated Keychain authorization prompts.
    /// The user must have previously authorized access (via "Always Allow" on the
    /// security command or by adding the app to the Keychain ACL).
    static func readClaudeCredentials() -> ClaudeCredentials? {
        // Try the Security framework first (works if user clicked "Always Allow" for this app)
        if let creds = readViaSecurityFramework() {
            return creds
        }

        // Fallback: read from the .claude.json state file which may have cached tokens
        return readFromClaudeStateFile()
    }

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

    private static func readFromClaudeStateFile() -> ClaudeCredentials? {
        // Claude Code also stores a copy of the state in ~/.claude.json
        // The tokens are in the Keychain, but the state file may have a cached copy
        // after the CLI has been authorized
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let stateURL = homeDir.appending(path: ".claude.json")

        guard let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Check for oauthAccount info (no tokens here, but subscription info)
        guard let account = json["oauthAccount"] as? [String: Any] else {
            return nil
        }

        let billingType = account["billingType"] as? String

        // Try to read cached credentials from the Keychain via the `security` CLI
        // This works if the user has previously authorized via terminal
        if let cliCreds = readViaSecurityCLI() {
            return ClaudeCredentials(
                accessToken: cliCreds.accessToken,
                refreshToken: cliCreds.refreshToken,
                expiresAt: cliCreds.expiresAt,
                subscriptionType: cliCreds.subscriptionType ?? billingType,
                rateLimitTier: cliCreds.rateLimitTier
            )
        }

        return nil
    }

    private static func readViaSecurityCLI() -> ClaudeCredentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-g",  // output password
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

        // The password is output on stderr in the format: password: "..."
        // or password: 0x<hex>
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        guard let passwordData = extractPasswordData(from: errorOutput) else {
            return nil
        }

        return parseCredentialJSON(passwordData)
    }

    private static func extractPasswordData(from output: String) -> Data? {
        // Format: password: "JSON string here"
        // Or: password: 0xHEXHEXHEX
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("password: \"") && trimmed.hasSuffix("\"") {
                let start = trimmed.index(trimmed.startIndex, offsetBy: 11)
                let end = trimmed.index(trimmed.endIndex, offsetBy: -1)
                let escaped = String(trimmed[start..<end])
                // Unescape common escapes
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
