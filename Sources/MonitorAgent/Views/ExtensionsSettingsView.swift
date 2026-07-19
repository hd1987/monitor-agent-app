import AppKit
import SwiftUI

struct ExtensionsSettingsView: View {
    @Binding var selectedTab: AppSourceTab
    let inventory: ExtensionInventory
    let isLoading: Bool

    var body: some View {
        InventoryPage(selectedTab: $selectedTab, isLoading: isLoading) {
            ExtensionGroup(
                title: "Skills",
                source: skillsSource,
                count: inventory.skills.count,
                emptyMessage: "No user skills found.",
                openSourceDirectory: openSkillsDirectory
            ) {
                ExtensionCardGrid {
                    ForEach(inventory.skills) { skill in
                        ExtensionItemCard {
                            Text(skill.name)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(skill.name)
                        }
                        .accessibilityLabel(skill.name)
                    }
                }
            }

            ExtensionGroup(
                title: "MCP Servers",
                source: mcpSource,
                count: inventory.mcpServers.count,
                emptyMessage: "No configured MCP servers found."
            ) {
                ExtensionCardGrid {
                    ForEach(inventory.mcpServers) { server in
                        MCPServerCard(server: server)
                    }
                }
            }
        }
    }

    private var skillsSource: String {
        inventorySource.skillsDisplayPath
    }

    private var mcpSource: String {
        inventorySource.mcpDisplayPath
    }

    private var inventorySource: ExtensionInventorySource {
        selectedTab == .claude ? .claude : .codex
    }

    private func openSkillsDirectory() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(inventorySource.skillsRelativePath, isDirectory: true)
        NSWorkspace.shared.open(url)
    }
}

private struct InventoryPage<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedTab: AppSourceTab
    let isLoading: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            AppSourceTabBar(selection: $selectedTab)
                .padding(.top, SettingsWindowLayout.contentTopPadding)

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading local extensions…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        content()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            UtilityWindowDesign.presentation(reduceMotion: reduceMotion),
            value: isLoading
        )
    }
}

private struct ExtensionGroup<Content: View>: View {
    let title: String
    let source: String
    let count: Int
    let emptyMessage: String
    var openSourceDirectory: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))

                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .accessibilityLabel("\(count) \(title)")
                }

                Spacer(minLength: 12)

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(source)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if let openSourceDirectory {
                        Button(action: openSourceDirectory) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Open Skills directory")
                        .accessibilityLabel("Open Skills directory")
                    }
                }
            }

            if count == 0 {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(emptyMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
                content()
            }
        }
        .padding(14)
        .utilityWindowGroupedSurface()
    }
}

private struct ExtensionCardGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading),
            ],
            alignment: .leading,
            spacing: 8
        ) {
            content()
        }
    }
}

private struct ExtensionItemCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
        .font(.system(size: 12, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .background(UtilityWindowDesign.nestedSurfaceFill)
        .clipShape(
            RoundedRectangle(
                cornerRadius: UtilityWindowDesign.compactCornerRadius,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: UtilityWindowDesign.compactCornerRadius,
                style: .continuous
            )
            .stroke(Color(nsColor: .separatorColor).opacity(0.38), lineWidth: 0.5)
        )
    }
}

private struct MCPServerCard: View {
    let server: ConfiguredMCPServer

    var body: some View {
        ExtensionItemCard {
            Circle()
                .fill(server.isEnabled ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(server.name)
                .fixedSize(horizontal: false, vertical: true)
                .help(server.name)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(server.name)
        .accessibilityValue(server.isEnabled ? "Enabled" : "Disabled")
    }
}
