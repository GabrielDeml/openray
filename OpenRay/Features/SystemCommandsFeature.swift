import OpenRayCore

/// Sleep, Restart, Empty Trash and the other system commands (docs/DESIGN.md §4.2.10). The
/// commands themselves are described in Core; this only hands them the Mac to act on.
final class SystemCommandsFeature: Feature {
    let id = FeatureID(rawValue: "system")

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        [SystemCommandSource(control: env.system)]
    }
}
