import Foundation

enum QuotaEnvironmentDetector {
    static func isInstalled(_ provider: QuotaProviderID) -> Bool {
        let executable = provider == .claude ? "claude" : "codex"
        if provider == .codex,
           FileManager.default.fileExists(atPath: "/Applications/Codex.app") {
            return true
        }
        if fixedExecutablePaths(provider, home: FileManager.default.homeDirectoryForCurrentUser.path)
            .contains(where: FileManager.default.isExecutableFile(atPath:)) {
            return true
        }
        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent(executable).path }
            .contains(where: FileManager.default.isExecutableFile(atPath:)) == true
    }

    static func fixedExecutablePaths(_ provider: QuotaProviderID, home: String) -> [String] {
        let executable = provider == .claude ? "claude" : "codex"
        return [
            "/opt/homebrew/bin/\(executable)",
            "/usr/local/bin/\(executable)",
            "/Applications/ChatGPT.app/Contents/Resources/\(executable)",
            "/Applications/Codex.app/Contents/Resources/\(executable)",
            "\(home)/.local/bin/\(executable)",
            "\(home)/.npm-global/bin/\(executable)",
            "\(home)/.claude/local/\(executable)"
        ]
    }

    static func usesThirdPartyAPI(_ provider: QuotaProviderID) -> Bool {
        switch provider {
        case .claude: return claudeUsesThirdPartyAPI()
        case .codex: return codexUsesThirdPartyAPI()
        }
    }

    private static func claudeUsesThirdPartyAPI() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard
            let data = try? Data(contentsOf: path),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let environment = root["env"] as? [String: Any]
        else { return false }

        if let baseURL = environment["ANTHROPIC_BASE_URL"] as? String,
           !baseURL.isEmpty,
           !baseURL.contains("api.anthropic.com") {
            return true
        }
        return environment["CLAUDE_CODE_USE_BEDROCK"] != nil
            || environment["CLAUDE_CODE_USE_VERTEX"] != nil
    }

    private static func codexUsesThirdPartyAPI() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return false }

        if let provider = firstCapture(
            pattern: #"(?m)^\s*model_provider\s*=\s*[\"']([^\"']+)[\"']"#,
            text: content
        ) {
            return !["openai", "codex"].contains(provider.lowercased())
        }
        let baseURLs = captures(
            pattern: #"(?m)^\s*base_url\s*=\s*[\"']([^\"']+)[\"']"#,
            text: content
        )
        return baseURLs.contains { !$0.contains("api.openai.com") && !$0.contains("chatgpt.com") }
    }

    private static func firstCapture(pattern: String, text: String) -> String? {
        captures(pattern: pattern, text: text).first
    }

    private static func captures(pattern: String, text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}
