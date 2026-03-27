import Foundation

enum KeychainHelper {
    struct ClaudeCredentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var subscriptionType: String?
        var rateLimitTier: String?
    }

    private enum RefreshResult {
        case success(ClaudeCredentials)
        case invalidGrant
        case failed
    }

    // MARK: - Cache file path

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/ai-usage-tracker-token-cache.json")
    }

    private static var credentialsFileCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: ".claude/.credentials.json"),
            home.appending(path: ".claude/credentials.json"),
        ]
    }

    // MARK: - Public API

    /// Reads Claude Code OAuth credentials.
    ///
    /// Strategy:
    /// 1. Try Claude Code's file-backed credential store.
    /// 2. Try the local token cache.
    /// 3. If expired/missing, re-read from Keychain via the `security` CLI
    ///    (this binary is already trusted — no password prompt).
    /// 4. Last resort: Security framework (may prompt once).
    static func readClaudeCredentials() -> ClaudeCredentials? {
        if let fileCreds = readFromCredentialsFile() {
            if !isExpired(fileCreds) {
                debugLog("using credentials from ~/.claude/.credentials.json")
                writeToCache(fileCreds)
                return fileCreds
            }
            debugLog("credentials file token expired (was \(fileCreds.expiresAt?.description ?? "nil")), trying OAuth refresh")
            if let refreshToken = fileCreds.refreshToken {
                switch refreshViaOAuth(refreshToken: refreshToken, oldCreds: fileCreds) {
                case .success(let refreshed):
                    writeToCache(refreshed)
                    return refreshed
                case .invalidGrant:
                    debugLog("credentials file refresh hit invalid_grant, re-reading live sources")
                    if let fresh = readFreshLiveCredentials() {
                        writeToCache(fresh)
                        return fresh
                    }
                case .failed:
                    break
                }
            } else {
                debugLog("no refresh token in credentials file")
            }
        } else {
            debugLog("no ~/.claude/.credentials.json found")
        }

        // While Claude Code is running, prefer live stores over our cache because tokens
        // may rotate outside this app.
        if isClaudeCodeRunning(), let liveCreds = readFromKeychainSources() {
            debugLog("Claude Code is running, preferring live Keychain credentials")
            if !isExpired(liveCreds) {
                writeToCache(liveCreds)
                return liveCreds
            }
        }

        // 2. Try cached token — completely silent
        if let cached = readFromCache() {
            if !isExpired(cached) {
                return cached
            }
            debugLog("cache expired (was \(cached.expiresAt?.description ?? "nil")), trying OAuth refresh")

            // Token expired — use refresh token to get new access token (no Keychain needed)
            if let refreshToken = cached.refreshToken {
                switch refreshViaOAuth(refreshToken: refreshToken, oldCreds: cached) {
                case .success(let refreshed):
                    writeToCache(refreshed)
                    return refreshed
                case .invalidGrant:
                    debugLog("cache refresh hit invalid_grant, re-reading live sources")
                    if let fresh = readFreshLiveCredentials() {
                        writeToCache(fresh)
                        return fresh
                    }
                case .failed:
                    break
                }
            } else {
                debugLog("no refresh token in cache")
            }
        } else {
            debugLog("no cache found")
        }

        // 3. Re-read from Keychain via security CLI (no prompt)
        debugLog("trying security CLI")
        let keychainCreds = readFromKeychainSources()

        if let kc = keychainCreds {
            // If Keychain token is also expired, try OAuth refresh with its refresh token
            if isExpired(kc), let refreshToken = kc.refreshToken {
                debugLog("keychain token also expired, trying OAuth refresh")
                switch refreshViaOAuth(refreshToken: refreshToken, oldCreds: kc) {
                case .success(let refreshed):
                    writeToCache(refreshed)
                    return refreshed
                case .invalidGrant:
                    debugLog("keychain refresh hit invalid_grant, re-reading live sources")
                    if let fresh = readFreshLiveCredentials() {
                        writeToCache(fresh)
                        return fresh
                    }
                case .failed:
                    break
                }
                // Don't cache an expired token — it just overwrites any good cache
                debugLog("OAuth refresh failed, returning expired keychain token without caching")
                return kc
            }
            writeToCache(kc)
            return kc
        }

        debugLog("all credential sources failed")
        return nil
    }

    /// Delete the local token cache file so next read re-fetches from Keychain.
    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// Force refresh credentials — tries OAuth refresh first, then Keychain.
    /// Called when the API returns 401 (token expired or revoked).
    static func forceRefreshCredentials() -> ClaudeCredentials? {
        if let fileCreds = readFromCredentialsFile(), !isExpired(fileCreds) {
            writeToCache(fileCreds)
            return fileCreds
        }

        // 1. Try OAuth refresh (no Keychain needed)
        if let cached = readFromCache(), let refreshToken = cached.refreshToken {
            switch refreshViaOAuth(refreshToken: refreshToken, oldCreds: cached) {
            case .success(let refreshed):
                writeToCache(refreshed)
                return refreshed
            case .invalidGrant:
                if let fresh = readFreshLiveCredentials() {
                    writeToCache(fresh)
                    return fresh
                }
            case .failed:
                break
            }
        }
        // 2. Try CLI
        if let fresh = readFromKeychainSources() {
            writeToCache(fresh)
            return fresh
        }
        if let fresh = readFromCredentialsFile() {
            writeToCache(fresh)
            return fresh
        }
        return nil
    }

    // MARK: - OAuth token refresh

    private static let claudeClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenEndpoint = "https://api.anthropic.com/v1/oauth/token"

    /// Use the refresh token to get a new access token via the Claude OAuth API.
    /// This works without any Keychain access or password prompts.
    private static func debugLog(_ msg: String) {
        #if DEBUG
        let line = "[\(Date())] [Keychain] \(msg)\n"
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/aitracker-debug.log")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logURL.path, contents: line.data(using: .utf8))
        }
        #endif
    }

    private static func refreshViaOAuth(refreshToken: String, oldCreds: ClaudeCredentials) -> RefreshResult {
        guard let url = URL(string: tokenEndpoint) else { return .failed }

        debugLog("refreshViaOAuth: attempting with refresh token \(refreshToken.prefix(20))...")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": claudeClientId
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Synchronous network call (we're already on a background path)
        let semaphore = DispatchSemaphore(value: 0)
        var result: RefreshResult = .failed

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                debugLog("refreshViaOAuth: error \(error.localizedDescription)")
                return
            }

            guard let data, let http = response as? HTTPURLResponse else {
                debugLog("refreshViaOAuth: no data or not HTTP")
                return
            }

            let bodyStr = String(data: data, encoding: .utf8)?.prefix(200) ?? "nil"
            debugLog("refreshViaOAuth: HTTP \(http.statusCode), body=\(bodyStr)")

            if http.statusCode == 400,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorCode = json["error"] as? String,
               errorCode == "invalid_grant" {
                debugLog("refreshViaOAuth: refresh token was rotated (invalid_grant)")
                result = .invalidGrant
                return
            }

            guard (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String else {
                return
            }

            let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
            let expiresIn = json["expires_in"] as? Double ?? 28800
            let expiresAt = Date().addingTimeInterval(expiresIn)

            debugLog("refreshViaOAuth: success! new token \(newAccessToken.prefix(20))..., expires in \(Int(expiresIn))s")

            result = ClaudeCredentials(
                accessToken: newAccessToken,
                refreshToken: newRefreshToken,
                expiresAt: expiresAt,
                subscriptionType: oldCreds.subscriptionType,
                rateLimitTier: oldCreds.rateLimitTier
            )
            result = .success(ClaudeCredentials(
                accessToken: newAccessToken,
                refreshToken: newRefreshToken,
                expiresAt: expiresAt,
                subscriptionType: oldCreds.subscriptionType,
                rateLimitTier: oldCreds.rateLimitTier
            ))
        }
        task.resume()
        semaphore.wait()
        return result
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

    // MARK: - Claude Code credentials file

    private static func readFromCredentialsFile() -> ClaudeCredentials? {
        for url in credentialsFileCandidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let creds = parseCredentialJSON(data) else {
                debugLog("failed to parse credentials file at \(url.path)")
                continue
            }

            let billingType = readBillingTypeFromStateFile()
            return ClaudeCredentials(
                accessToken: creds.accessToken,
                refreshToken: creds.refreshToken,
                expiresAt: creds.expiresAt,
                subscriptionType: creds.subscriptionType ?? billingType,
                rateLimitTier: creds.rateLimitTier
            )
        }

        return nil
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
        let billingType = readBillingTypeFromStateFile()

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

    private static func readFromKeychainSources() -> ClaudeCredentials? {
        readViaSecurityCLIWithStateFile() ?? readViaSecurityCLI() ?? readViaSecurityFramework()
    }

    private static func readFreshLiveCredentials() -> ClaudeCredentials? {
        if let fileCreds = readFromCredentialsFile(), !isExpired(fileCreds) {
            debugLog("found fresh credentials in ~/.claude/.credentials.json after refresh failure")
            return fileCreds
        }

        if let keychainCreds = readFromKeychainSources(), !isExpired(keychainCreds) {
            debugLog("found fresh credentials in Keychain after refresh failure")
            return keychainCreds
        }

        return readFromCredentialsFile() ?? readFromKeychainSources()
    }

    private static func readBillingTypeFromStateFile() -> String? {
        let stateURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else {
            return nil
        }
        return account["billingType"] as? String
    }

    private static func isClaudeCodeRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "Claude Code"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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
