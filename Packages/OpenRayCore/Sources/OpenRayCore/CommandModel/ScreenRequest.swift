/// Names a screen a feature can push onto the launcher.
public struct ScreenRequest: Hashable, Sendable, Codable {
    public var feature: FeatureID
    /// Which of the feature's screens.
    public var screen: String
    public var argument: String?

    public init(feature: FeatureID, screen: String, argument: String? = nil) {
        self.feature = feature
        self.screen = screen
        self.argument = argument
    }
}

/// What the search field does while a screen is on top.
public enum SearchBarMode: Sendable, Hashable {
    case hidden
    case filter(placeholder: String)
    case input(placeholder: String)
}
