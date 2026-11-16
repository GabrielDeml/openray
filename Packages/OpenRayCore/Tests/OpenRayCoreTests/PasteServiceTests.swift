import Foundation
import Testing

import OpenRayCore

/// Stands in for the pasteboard, the windows and the keyboard. It records what the service did
/// to it, in order, and touches nothing real.
@MainActor private final class FakePasteHost: PasteHost {
    enum Event: Equatable {
        case write([ClipRepresentation])
        case read
        case hideLauncher
        case restoreFocus
        case post(KeyChord)
        case hud(String)
    }

    private(set) var events: [Event] = []

    /// The change count the next write reports.
    var nextChangeCount = 7
    /// The text on the pasteboard this host stands in for.
    var pasteboardText: String?
    var isOpenRayActive = false
    var frontmostAppPID: pid_t?
    /// What bringing the previous app back answers, and which app is frontmost afterwards.
    var restoreSucceeds = true
    var frontmostAppPIDAfterRestore: pid_t?

    func writePasteboard(_ representations: [ClipRepresentation]) -> Int {
        events.append(.write(representations))
        return nextChangeCount
    }

    func readPasteboardText() -> String? {
        events.append(.read)
        return pasteboardText
    }

    func hideLauncher() {
        events.append(.hideLauncher)
    }

    func restoreFocus() async -> Bool {
        events.append(.restoreFocus)
        if restoreSucceeds {
            frontmostAppPID = frontmostAppPIDAfterRestore
        }
        return restoreSucceeds
    }

    func post(_ chord: KeyChord) {
        events.append(.post(chord))
    }

    func showHUD(_ text: String) {
        events.append(.hud(text))
    }

    var postedChords: [KeyChord] {
        var chords: [KeyChord] = []
        for event in events {
            if case .post(let chord) = event {
                chords.append(chord)
            }
        }
        return chords
    }

    var hudMessages: [String] {
        var messages: [String] = []
        for event in events {
            if case .hud(let text) = event {
                messages.append(text)
            }
        }
        return messages
    }
}

@MainActor @Suite struct PasteServiceTests {
    private let host = FakePasteHost()
    private let permissions = FakePermissionChecker()
    private let preferences = Preferences(store: InMemoryPreferencesStore())
    private let service: PasteService

    private let editor = AppRef(pid: 42, bundleID: "com.example.editor")
    private let hello = PasteContent.text("hello", cursorOffsetFromEnd: nil)
    private let helloAsText = [
        ClipRepresentation(uti: "public.utf8-plain-text", data: Data("hello".utf8))
    ]
    private let commandV = KeyChord(
        keyCode: VirtualKey.ansiV, modifiers: [.command], characters: "v")
    private let leftArrow = KeyChord(keyCode: VirtualKey.leftArrow)

    init() {
        service = PasteService(host: host, permissions: permissions, preferences: preferences)
        // The usual state of things: the app the launcher was opened over is still frontmost,
        // and OpenRay may post keys.
        host.frontmostAppPID = editor.pid
        permissions.states[.accessibility] = .granted
    }

    // MARK: Copy

    @Test func copyWritesTextAsUTF8AndDoesNothingElse() {
        service.copy(.text("Größe 🦒", cursorOffsetFromEnd: nil))

        let expected = ClipRepresentation(
            uti: "public.utf8-plain-text", data: Data("Größe 🦒".utf8))
        #expect(host.events == [.write([expected])])
    }

    @Test func copyWritesEveryRepresentationItIsGiven() {
        let representations = [
            ClipRepresentation(uti: "public.rtf", data: Data([1, 2, 3])),
            ClipRepresentation(uti: "public.utf8-plain-text", data: Data("plain".utf8)),
        ]

        service.copy(.representations(representations))

        #expect(host.events == [.write(representations)])
    }

    @Test func everyWriteIsReportedWithItsChangeCount() async {
        var writes: [PasteService.Write] = []
        service.onWrite = { write in writes.append(write) }

        host.nextChangeCount = 11
        service.copy(hello)
        host.nextChangeCount = 12
        _ = await service.paste(hello, into: editor)

        #expect(
            writes == [
                PasteService.Write(changeCount: 11, representations: helloAsText),
                PasteService.Write(changeCount: 12, representations: helloAsText),
            ])
    }

    // MARK: Paste

    @Test func pasteCopiesHidesTheLauncherAndTypesCommandV() async {
        let result = await service.paste(hello, into: editor)

        #expect(result == .pasted)
        #expect(host.events == [.write(helloAsText), .hideLauncher, .post(commandV)])
    }

    @Test func pasteDoesNotBringTheTargetBackWhenItNeverLeftTheFront() async {
        _ = await service.paste(hello, into: editor)

        #expect(!host.events.contains(.restoreFocus))
    }

    @Test func pasteBringsTheTargetBackFirstWhenOpenRayIsActive() async {
        // The launcher was opened over Settings.
        host.isOpenRayActive = true
        host.frontmostAppPID = 1
        host.frontmostAppPIDAfterRestore = editor.pid

        let result = await service.paste(hello, into: editor)

        #expect(result == .pasted)
        #expect(
            host.events == [.write(helloAsText), .hideLauncher, .restoreFocus, .post(commandV)])
    }

    @Test func pasteOnlyCopiesWhenTheTargetDoesNotComeBack() async {
        host.isOpenRayActive = true
        host.restoreSucceeds = false

        let result = await service.paste(hello, into: editor)

        #expect(result == .copiedOnly(.targetChanged))
        #expect(host.postedChords.isEmpty)
        #expect(host.hudMessages == ["Copied — press ⌘V"])
    }

    @Test func pasteOnlyCopiesWhenAnotherAppIsFrontmost() async {
        host.frontmostAppPID = 99

        let result = await service.paste(hello, into: editor)

        #expect(result == .copiedOnly(.targetChanged))
        #expect(host.events.first == .write(helloAsText))
        #expect(host.postedChords.isEmpty)
        #expect(host.hudMessages == ["Copied — press ⌘V"])
    }

    @Test func pasteOnlyCopiesWhenNoAppIsFrontmost() async {
        host.frontmostAppPID = nil

        let result = await service.paste(hello, into: editor)

        #expect(result == .copiedOnly(.targetChanged))
        #expect(host.postedChords.isEmpty)
    }

    @Test func pasteOnlyCopiesWhenThereIsNoTarget() async {
        let result = await service.paste(hello, into: nil)

        #expect(result == .copiedOnly(.noTarget))
        #expect(
            host.events == [.write(helloAsText), .hideLauncher, .hud("Copied — press ⌘V")])
    }

    // MARK: Accessibility

    @Test(arguments: [PermissionState.denied, .notDetermined, .unknown])
    func pasteOnlyCopiesWithoutAccessibility(_ state: PermissionState) async {
        permissions.states[.accessibility] = state

        let result = await service.paste(hello, into: editor)

        #expect(result == .copiedOnly(.noAccessibility))
        #expect(host.postedChords.isEmpty)
        // Pasting degrades to copying. It never asks for the permission.
        #expect(permissions.requested.isEmpty)
    }

    @Test func hintAboutAccessibilityIsGivenOnceAndRemembered() async {
        permissions.states[.accessibility] = .denied

        _ = await service.paste(hello, into: editor)
        _ = await service.paste(hello, into: editor)

        #expect(
            host.hudMessages == [
                "Copied — press ⌘V. Grant Accessibility in Settings to paste directly.",
                "Copied — press ⌘V",
            ])
        #expect(preferences.pasteAccessibilityHintShown)
    }

    @Test func pasteThatFailsForAnotherReasonDoesNotUseUpTheHint() async {
        _ = await service.paste(hello, into: nil)

        #expect(!preferences.pasteAccessibilityHintShown)
    }

    // MARK: Caret

    @Test func caretIsMovedBackByTheOffsetTheContentAsksFor() async {
        let greeting = PasteContent.text("Dear ,", cursorOffsetFromEnd: 1)

        _ = await service.paste(greeting, into: editor)

        #expect(host.postedChords == [commandV, leftArrow])
    }

    @Test(arguments: [(-3, 0), (0, 0), (2, 2), (5, 5), (600, 5)])
    func caretNeverMovesFurtherThanTheTextIsLong(_ offset: Int, _ expectedPresses: Int) async {
        _ = await service.paste(.text("hello", cursorOffsetFromEnd: offset), into: editor)

        let arrowPresses = host.postedChords.filter { $0 == leftArrow }
        #expect(arrowPresses.count == expectedPresses)
    }

    // MARK: Reading the clipboard

    @Test func clipboardTextIsWhatThePasteboardHoldsAndNothingIsWritten() {
        var writes: [PasteService.Write] = []
        service.onWrite = { write in writes.append(write) }
        host.pasteboardText = "from another app"

        #expect(service.clipboardText() == "from another app")
        #expect(host.events == [.read])
        #expect(writes.isEmpty)
    }

    @Test func clipboardWithoutTextReadsAsNil() {
        #expect(service.clipboardText() == nil)
    }

    @Test func copyAndPasteNeverReadTheClipboard() async {
        host.pasteboardText = "from another app"

        service.copy(hello)
        _ = await service.paste(hello, into: editor)

        #expect(!host.events.contains(.read))
    }

    // MARK: Copied outcome

    @Test func copiedOutcomeClosesTheLauncherAndSaysSo() {
        #expect(ActionOutcome.copiedToClipboard == .showHUD("Copied to Clipboard"))
    }
}
