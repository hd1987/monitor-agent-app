import SwiftUI

enum ModelColorResolver {
    static let palette: [Color] = [
        .blue, .green, .orange,
        Color(red: 0.58, green: 0.48, blue: 0.88), // softened violet, closer in tone to the rest
        .cyan, .pink, .teal, .indigo,
        Color(red: 0.82, green: 0.20, blue: 0.26),
        Color(red: 0.55, green: 0.35, blue: 0.90),
        Color(red: 0.15, green: 0.55, blue: 0.32),
        Color(red: 0.90, green: 0.48, blue: 0.12),
        Color(red: 0.10, green: 0.48, blue: 0.72),
        Color(red: 0.72, green: 0.28, blue: 0.62),
        Color(red: 0.42, green: 0.52, blue: 0.12),
        Color(red: 0.62, green: 0.38, blue: 0.20),
    ]

    private static let preferredIndices: [String: Int] = [
        "claude-opus-4-8": 3,
        "claude-opus-4-6": 3,
        "anthropic.claude-4-6-opus": 3,
        "claude-sonnet-5": 0,
        "claude-sonnet-4-6": 0,
        "claude-haiku-4-5-20251001": 6,
        "anthropic.claude-4-5-haiku": 6,
        "gpt-5.6-sol": 1,
        "gpt-5.6": 1,
        "gpt-5.5": 1,
        "codex-auto-review": 2,
        "mimo-v2.5-pro": 4,
        "mimo-v2.5": 12,
    ]

    static func paletteIndices(for models: [String]) -> [String: Int] {
        let uniqueModels = Array(Set(models)).sorted()
        var result: [String: Int] = [:]
        var usedIndices = Set<Int>()

        // First pass: honor a preferred color only if no earlier model already claimed it,
        // so two co-present models never collapse onto the same swatch.
        for model in uniqueModels {
            if let preferredIndex = preferredIndices[model], !usedIndices.contains(preferredIndex) {
                result[model] = preferredIndex
                usedIndices.insert(preferredIndex)
            }
        }

        // Second pass: deterministically hash-assign the rest around used indices.
        for model in uniqueModels where result[model] == nil {
            let startingIndex = stableHash(model) % palette.count
            let availableIndex = (0..<palette.count)
                .map { (startingIndex + $0) % palette.count }
                .first { !usedIndices.contains($0) }
            let index = availableIndex ?? startingIndex
            result[model] = index
            usedIndices.insert(index)
        }

        return result
    }

    private static func stableHash(_ value: String) -> Int {
        value.utf8.reduce(5381) { hash, byte in
            ((hash << 5) &+ hash) &+ Int(byte)
        } & Int.max
    }
}

struct ModelDistributionView: View {
    @EnvironmentObject var store: AppStore

    private var totalRequests: Int {
        store.modelDistribution.reduce(0) { $0 + $1.requests }
    }

    private var modelColorIndices: [String: Int] {
        ModelColorResolver.paletteIndices(for: store.modelDistribution.map(\.model))
    }

    private func color(for model: String) -> Color {
        let index = modelColorIndices[model] ?? 0
        return ModelColorResolver.palette[index]
    }

    private func shortName(_ model: String) -> String {
        let map: [String: String] = [
            "claude-opus-4-8": "Opus 4.8",
            "claude-opus-4-6": "Opus 4.6",
            "anthropic.claude-4-6-opus": "Opus 4.6",
            "claude-sonnet-5": "Sonnet 5",
            "claude-sonnet-4-6": "Sonnet 4.6",
            "claude-haiku-4-5-20251001": "Haiku 4.5",
            "anthropic.claude-4-5-haiku": "Haiku 4.5",
            "gpt-5.6-sol": "GPT-5.6",
            "gpt-5.6": "GPT-5.6",
            "gpt-5.5": "GPT-5.5",
            "codex-auto-review": "Codex Review",
            "mimo-v2.5-pro": "Mimo Pro",
            "mimo-v2.5": "Mimo",
        ]
        return map[model] ?? model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            // Stacked bar
            if totalRequests > 0 {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(store.modelDistribution) { model in
                            let fraction = CGFloat(model.requests) / CGFloat(totalRequests)
                            let width = max(fraction * geo.size.width, 2)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(for: model.model))
                                .frame(width: width)
                                .help("\(shortName(model.model)): \(model.requests) requests (\(String(format: "%.1f", fraction * 100))%)")
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Legend
            let items = store.modelDistribution.prefix(6)
            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
            ], spacing: 6) {
                ForEach(items) { model in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color(for: model.model))
                            .frame(width: 6, height: 6)
                        Text(shortName(model.model))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(formatCount(model.requests))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
