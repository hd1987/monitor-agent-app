import Foundation

enum ExtensionInventorySource {
    case claude
    case codex

    var skillsRelativePath: String {
        switch self {
        case .claude: ".claude/skills"
        case .codex: ".codex/skills"
        }
    }

    var mcpRelativePath: String {
        switch self {
        case .claude: ".claude.json"
        case .codex: ".codex/config.toml"
        }
    }

    var skillsDisplayPath: String { "~/\(skillsRelativePath)" }
    var mcpDisplayPath: String { "~/\(mcpRelativePath)" }
}

struct InstalledSkill: Identifiable {
    let name: String
    let path: String

    var id: String { path }
}

struct ConfiguredMCPServer: Identifiable, Equatable {
    let name: String
    let isEnabled: Bool

    var id: String { name }
}

struct ExtensionInventory {
    let skills: [InstalledSkill]
    let mcpServers: [ConfiguredMCPServer]

    static let empty = ExtensionInventory(skills: [], mcpServers: [])
}

struct ExtensionInventoryLoader {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load(source: ExtensionInventorySource, homeDirectory: URL) -> ExtensionInventory {
        let skills = loadSkills(
            root: homeDirectory.appendingPathComponent(source.skillsRelativePath),
            homeDirectory: homeDirectory
        )
        let mcpServers: [ConfiguredMCPServer]
        switch source {
        case .claude:
            mcpServers = loadClaudeMCPServers(homeDirectory: homeDirectory)
        case .codex:
            mcpServers = loadCodexMCPServers(homeDirectory: homeDirectory)
        }
        return ExtensionInventory(skills: skills, mcpServers: mcpServers)
    }

    private func loadSkills(
        root: URL,
        homeDirectory: URL
    ) -> [InstalledSkill] {
        var discovered: [String: InstalledSkill] = [:]
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
            let name = skillName(at: url) ?? url.deletingLastPathComponent().lastPathComponent
            let skill = InstalledSkill(
                name: name,
                path: abbreviatedPath(url.path, homeDirectory: homeDirectory)
            )
            discovered[url.standardizedFileURL.path] = skill
        }

        return discovered.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func skillName(at url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n", maxSplits: 50, omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("name:") else { continue }
            let value = text.dropFirst("name:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func loadClaudeMCPServers(homeDirectory: URL) -> [ConfiguredMCPServer] {
        let url = homeDirectory.appendingPathComponent(
            ExtensionInventorySource.claude.mcpRelativePath
        )
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["mcpServers"] as? [String: Any]
        else { return [] }

        let servers = entries.map { name, rawValue in
            let configuration = rawValue as? [String: Any]
            let isEnabled = configuration?["disabled"] as? Bool != true
                && configuration?["enabled"] as? Bool != false
            return ConfiguredMCPServer(
                name: name,
                isEnabled: isEnabled
            )
        }

        return servers.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func loadCodexMCPServers(homeDirectory: URL) -> [ConfiguredMCPServer] {
        let url = homeDirectory.appendingPathComponent(
            ExtensionInventorySource.codex.mcpRelativePath
        )
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var enabledByName: [String: Bool] = [:]
        var currentBaseServer: String?

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                let section = String(line.dropFirst().dropLast())
                if let parsed = codexMCPSection(section) {
                    currentBaseServer = parsed.isBaseSection ? parsed.name : nil
                    enabledByName[parsed.name] = enabledByName[parsed.name] ?? true
                } else {
                    currentBaseServer = nil
                }
                continue
            }

            guard let currentBaseServer, line.hasPrefix("enabled") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if parts.count == 2, parts[0] == "enabled" {
                enabledByName[currentBaseServer] = parts[1].lowercased() != "false"
            }
        }

        return enabledByName.map { name, isEnabled in
            ConfiguredMCPServer(
                name: name,
                isEnabled: isEnabled
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func codexMCPSection(_ section: String) -> (name: String, isBaseSection: Bool)? {
        let prefix = "mcp_servers."
        guard section.hasPrefix(prefix) else { return nil }
        let remainder = String(section.dropFirst(prefix.count))
        guard !remainder.isEmpty else { return nil }

        if remainder.hasPrefix("\"") {
            guard let closingQuote = remainder.dropFirst().firstIndex(of: "\"") else { return nil }
            let name = String(remainder[remainder.index(after: remainder.startIndex)..<closingQuote])
            let suffix = remainder[remainder.index(after: closingQuote)...]
            return (name, suffix.isEmpty)
        }

        let components = remainder.split(separator: ".", maxSplits: 1)
        guard let name = components.first, !name.isEmpty else { return nil }
        return (String(name), components.count == 1)
    }

    private func abbreviatedPath(_ path: String, homeDirectory: URL) -> String {
        let home = homeDirectory.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
