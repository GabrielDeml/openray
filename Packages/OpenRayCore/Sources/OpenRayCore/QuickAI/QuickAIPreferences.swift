extension PreferenceKey where Value == AIModelID {
    /// The model Quick AI asks. The fastest one is the default; whether a better one is worth
    /// its wait is still open (docs/DESIGN.md §8, item 12).
    public static var aiModel: PreferenceKey {
        PreferenceKey(name: "ai.model", defaultValue: ClaudeProvider.haiku)
    }
}

extension PreferenceKey where Value == AIEffort {
    /// How much work the model puts into a reply.
    public static var aiEffort: PreferenceKey {
        PreferenceKey(name: "ai.effort", defaultValue: .low)
    }
}

extension Preferences {
    public var aiModel: AIModelID {
        get { self[.aiModel] }
        set { self[.aiModel] = newValue }
    }

    public var aiEffort: AIEffort {
        get { self[.aiEffort] }
        set { self[.aiEffort] = newValue }
    }
}
