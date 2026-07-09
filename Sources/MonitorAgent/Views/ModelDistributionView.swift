import SwiftUI

struct ModelDistributionView: View {
    @EnvironmentObject var store: AppStore

    private var totalRequests: Int {
        store.modelDistribution.reduce(0) { $0 + $1.requests }
    }

    /// Model name → display color
    private let modelColors: [String: Color] = [
        "claude-opus-4-6": .blue,
        "anthropic.claude-4-6-opus": .blue,
        "claude-sonnet-4-6": .cyan,
        "claude-haiku-4-5-20251001": .teal,
        "anthropic.claude-4-5-haiku": .teal,
        "gpt-5.5": .green,
        "codex-auto-review": .orange,
        "mimo-v2.5-pro": .purple,
        "mimo-v2.5": .purple,
    ]

    private func color(for model: String) -> Color {
        modelColors[model] ?? .gray
    }

    private func shortName(_ model: String) -> String {
        let map: [String: String] = [
            "claude-opus-4-6": "Opus 4.6",
            "anthropic.claude-4-6-opus": "Opus 4.6",
            "claude-sonnet-4-6": "Sonnet 4.6",
            "claude-haiku-4-5-20251001": "Haiku 4.5",
            "anthropic.claude-4-5-haiku": "Haiku 4.5",
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
