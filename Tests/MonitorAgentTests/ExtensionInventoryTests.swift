import Foundation
import XCTest
@testable import MonitorAgent

final class ExtensionInventoryTests: XCTestCase {
    func testClaudeInventoryLoadsOnlyUserSkillsAndMCPStatus() throws {
        let home = temporaryHome()
        try write(
            "---\nname: personal-skill\n---\n",
            to: home.appendingPathComponent(".claude/skills/personal/SKILL.md")
        )
        try write(
            "---\nname: plugin-skill\n---\n",
            to: home.appendingPathComponent(
                ".claude/plugins/cache/market/plugin/1.0/skills/plugin/SKILL.md"
            )
        )
        try write(
            """
            {
              "mcpServers": {
                "enabled-server": { "command": "example" },
                "disabled-server": { "command": "example", "disabled": true }
              }
            }
            """,
            to: home.appendingPathComponent(".claude.json")
        )
        try write(
            """
            {
              "mcpServers": {
                "ignored-settings-server": { "command": "example" }
              }
            }
            """,
            to: home.appendingPathComponent(".claude/settings.json")
        )

        let inventory = ExtensionInventoryLoader().load(source: .claude, homeDirectory: home)

        XCTAssertEqual(inventory.skills.map(\.name), ["personal-skill"])
        XCTAssertEqual(
            inventory.mcpServers,
            [
                ConfiguredMCPServer(
                    name: "disabled-server",
                    isEnabled: false
                ),
                ConfiguredMCPServer(
                    name: "enabled-server",
                    isEnabled: true
                ),
            ]
        )
    }

    func testCodexInventoryLoadsUserSkillsAndExcludesSystemAndPluginSkills() throws {
        let home = temporaryHome()
        try write(
            "---\nname: user-skill\n---\n",
            to: home.appendingPathComponent(".codex/skills/user-skill/SKILL.md")
        )
        try write(
            "---\nname: system-skill\n---\n",
            to: home.appendingPathComponent(".codex/skills/.system/system-skill/SKILL.md")
        )
        try write(
            "---\nname: plugin-skill\n---\n",
            to: home.appendingPathComponent(
                ".codex/plugins/cache/market/plugin/1.0/skills/plugin/SKILL.md"
            )
        )
        try write(
            """
            [mcp_servers.active]
            command = "active"

            [mcp_servers."disabled.server"]
            command = "disabled"
            enabled = false

            [mcp_servers."disabled.server".env]
            TOKEN = "hidden"
            """,
            to: home.appendingPathComponent(".codex/config.toml")
        )

        let inventory = ExtensionInventoryLoader().load(source: .codex, homeDirectory: home)

        XCTAssertEqual(inventory.skills.map(\.name), ["user-skill"])
        XCTAssertEqual(inventory.mcpServers.map(\.name), ["active", "disabled.server"])
        XCTAssertEqual(inventory.mcpServers.map(\.isEnabled), [true, false])
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitorAgentExtensionInventoryTests")
            .appendingPathComponent(UUID().uuidString)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
