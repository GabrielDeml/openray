import OpenRayCore

/// The calculator (docs/DESIGN.md §4.4): a query that is a calculation gets its answer as the
/// first row. The whole of it is in Core.
final class CalculatorFeature: Feature {
    let id = CalculatorSource.feature

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        [CalculatorSource()]
    }
}
