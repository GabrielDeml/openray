import Foundation
import Testing

@testable import OpenRayCore

@MainActor @Suite struct QuickAIPreferencesTests {
    private let store = InMemoryPreferencesStore()

    @Test func quickAIAsksTheFastestModelWithLowEffortUnlessToldOtherwise() {
        let preferences = Preferences(store: store)

        #expect(preferences.aiModel == AIModelID(rawValue: "claude-haiku-5-5"))
        #expect(preferences.aiEffort == .low)
    }

    @Test func modelAndEffortRoundTrip() {
        let preferences = Preferences(store: store)

        preferences.aiModel = ClaudeProvider.sonnet
        preferences.aiEffort = .medium

        #expect(Preferences(store: store).aiModel == ClaudeProvider.sonnet)
        #expect(Preferences(store: store).aiEffort == .medium)
    }

    // `defaults read` shows the model's name, and a name is what a later version will find
    // there, whatever `AIModelID` has become by then.
    @Test func modelAndEffortAreStoredAsPlainStrings() {
        store.set(ClaudeProvider.opus, for: .aiModel)
        store.set(AIEffort.high, for: .aiEffort)

        #expect(PreferenceKey<AIModelID>.aiModel.name == "ai.model")
        #expect(PreferenceKey<AIEffort>.aiEffort.name == "ai.effort")
        let modelAsText = PreferenceKey(name: "ai.model", defaultValue: "")
        let effortAsText = PreferenceKey(name: "ai.effort", defaultValue: "")
        #expect(store.value(for: modelAsText) == "claude-opus-5-5")
        #expect(store.value(for: effortAsText) == "high")
    }
}

@Suite struct QuickAISystemPromptTests {
    // Half past eleven at night in Greenwich, which is the next morning in Tokyo.
    private let lateEvening = Date(timeIntervalSince1970: 1_794_785_400)

    @Test func promptEndsWithTheDateWhereTheUserIs() throws {
        let greenwich = try #require(TimeZone(identifier: "GMT"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))

        let inGreenwich = QuickAISystemPrompt.text(on: lateEvening, timeZone: greenwich)
        let inTokyo = QuickAISystemPrompt.text(on: lateEvening, timeZone: tokyo)

        #expect(
            inGreenwich.hasSuffix(
                " Reply in the language of the question. Today's date is 2026-11-15."))
        #expect(inTokyo.hasSuffix(" Today's date is 2026-11-16."))
    }

    @Test func promptIsTheSameTextForTheWholeDay() throws {
        let greenwich = try #require(TimeZone(identifier: "GMT"))
        let earlier = lateEvening.addingTimeInterval(-20 * 3600)

        let prompt = QuickAISystemPrompt.text(on: lateEvening, timeZone: greenwich)

        #expect(prompt == QuickAISystemPrompt.text(on: earlier, timeZone: greenwich))
        #expect(
            prompt.hasPrefix("You answer questions typed into OpenRay, a macOS keyboard launcher."))
        // One line: the backslashes at the line ends of the source leave no line breaks.
        #expect(!prompt.contains("\n"))
        #expect(!prompt.contains("  "))
    }
}
