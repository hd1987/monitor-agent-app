import AppKit
import SwiftUI

enum SourcePathKind {
    case directory
    case file

    var helpText: String {
        switch self {
        case .directory: "Open directory in Finder"
        case .file: "Show file in Finder"
        }
    }
}

enum SourcePathPresentation {
    static func fileName(for path: String) -> String {
        NSString(string: path).lastPathComponent
    }
}

enum FinderPathAction: Equatable {
    case open(URL)
    case reveal(URL)
}

enum FinderPathResolver {
    static func action(
        for path: String,
        kind: SourcePathKind,
        fileManager: FileManager = .default
    ) -> FinderPathAction? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(
            fileURLWithPath: expandedPath,
            isDirectory: kind == .directory
        )

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if kind == .directory, isDirectory.boolValue {
                return .open(url)
            }
            if kind == .file, !isDirectory.boolValue {
                return .reveal(url)
            }
        }

        var candidate = url.deletingLastPathComponent()
        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return .open(candidate)
            }
            candidate.deleteLastPathComponent()
        }

        return fileManager.fileExists(atPath: "/") ? .open(candidate) : nil
    }
}

enum FinderPathOpener {
    static func open(path: String, kind: SourcePathKind) {
        guard let action = FinderPathResolver.action(for: path, kind: kind) else { return }

        switch action {
        case let .open(url):
            NSWorkspace.shared.open(url)
        case let .reveal(url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

struct SourcePathView: View {
    let path: String
    var finderKind: SourcePathKind?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let finderKind {
                Button {
                    FinderPathOpener.open(path: path, kind: finderKind)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(finderKind.helpText)
                .accessibilityLabel(finderKind.helpText)
            }
        }
    }
}

struct SourcePathHeader<Leading: View>: View {
    let path: String
    var finderKind: SourcePathKind?
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leading()

            Spacer(minLength: 12)

            SourcePathView(path: path, finderKind: finderKind)
        }
    }
}
