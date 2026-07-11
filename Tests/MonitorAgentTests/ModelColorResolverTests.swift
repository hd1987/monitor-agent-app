import XCTest
@testable import MonitorAgent

final class ModelColorResolverTests: XCTestCase {
    func testUnknownModelsReceiveDistinctColors() {
        let models = ["gpt-5.6-sol", "claude-opus-4-8", "future-model"]

        let indices = ModelColorResolver.paletteIndices(for: models)

        XCTAssertEqual(Set(models.compactMap { indices[$0] }).count, models.count)
    }

    func testColorAssignmentDoesNotDependOnInputOrder() {
        let models = ["gpt-5.6-sol", "claude-opus-4-8", "future-model"]

        XCTAssertEqual(
            ModelColorResolver.paletteIndices(for: models),
            ModelColorResolver.paletteIndices(for: Array(models.reversed()))
        )
    }

    func testKnownAliasesKeepTheirSharedColor() {
        let models = ["claude-opus-4-6", "anthropic.claude-4-6-opus"]
        let indices = ModelColorResolver.paletteIndices(for: models)

        XCTAssertEqual(indices[models[0]], indices[models[1]])
    }
}
