import Foundation

extension PreferenceKey where Value == Bool {
    /// Whether the user has been told that pasting directly needs the Accessibility
    /// permission. The HUD says it the first time a paste could only copy, and not again.
    public static var pasteAccessibilityHintShown: PreferenceKey {
        PreferenceKey(name: "paste.accessibilityHintShown", defaultValue: false)
    }
}

extension Preferences {
    public var pasteAccessibilityHintShown: Bool {
        get { self[.pasteAccessibilityHintShown] }
        set { self[.pasteAccessibilityHintShown] = newValue }
    }
}

/// Puts content on the pasteboard and pastes it into the app the launcher was opened over
/// (docs/DESIGN.md §4.1.7). Every feature that copies or pastes goes through this, by way of
/// `ActionContext.copy` and `ActionContext.paste`.
///
/// The steps and their order are here, where they can be tested. What they do to the Mac is
/// the `PasteHost`'s.
@MainActor public final class PasteService {
    /// One write of OpenRay's to the general pasteboard.
    public struct Write: Sendable, Equatable {
        /// The pasteboard's change count for the write.
        public var changeCount: Int
        public var representations: [ClipRepresentation]

        public init(changeCount: Int, representations: [ClipRepresentation]) {
            self.changeCount = changeCount
            self.representations = representations
        }
    }

    /// Called after every write. This is for the clipboard monitor, which sees the pasteboard
    /// change and must not take OpenRay's own write for something the user copied in the app
    /// that happens to be frontmost: it skips the change count it is told here and records
    /// the content with OpenRay as its source. Nothing listens until clipboard history exists.
    public var onWrite: (@MainActor (Write) -> Void)?

    /// The type plain text is written as.
    public static let plainTextType = "public.utf8-plain-text"

    private static let pasteChord = KeyChord(
        keyCode: VirtualKey.ansiV, modifiers: [.command], characters: "v")
    private static let leftArrow = KeyChord(keyCode: VirtualKey.leftArrow)

    private let host: any PasteHost
    private let permissions: any PermissionChecking
    private let preferences: Preferences

    public init(
        host: any PasteHost, permissions: any PermissionChecking, preferences: Preferences
    ) {
        self.host = host
        self.permissions = permissions
        self.preferences = preferences
    }

    public func copy(_ content: PasteContent) {
        write(content)
    }

    /// Copies the content and then types ⌘V into `target`, the app the launcher was opened
    /// over.
    ///
    /// The content is on the pasteboard whatever happens next. When the paste itself cannot be
    /// done, the HUD tells the user to press ⌘V, so the callers have nothing to add.
    public func paste(_ content: PasteContent, into target: AppRef?) async -> PasteResult {
        write(content)
        host.hideLauncher()

        guard let target else { return finishByCopyingOnly(because: .noTarget) }

        // Usually the target is still frontmost, because the launcher never took its place.
        // It has to be brought back only when OpenRay itself is active: the launcher was
        // opened over Settings.
        if host.isOpenRayActive {
            let cameForward = await host.restoreFocus()
            if !cameForward { return finishByCopyingOnly(because: .targetChanged) }
        }
        // The keys go to whichever app is frontmost. If that is not the one the user came
        // from, because it quit or another app came forward, nothing is typed into it.
        if host.frontmostAppPID != target.pid { return finishByCopyingOnly(because: .targetChanged) }

        let accessibility = await permissions.state(.accessibility)
        if accessibility != .granted { return finishByCopyingOnly(because: .noAccessibility) }

        host.post(Self.pasteChord)
        for _ in 0..<Self.leftArrowPresses(after: content) {
            host.post(Self.leftArrow)
        }
        return .pasted
    }

    private func write(_ content: PasteContent) {
        let representations = Self.representations(of: content)
        let changeCount = host.writePasteboard(representations)
        onWrite?(Write(changeCount: changeCount, representations: representations))
    }

    private static func representations(of content: PasteContent) -> [ClipRepresentation] {
        switch content {
        case .text(let text, _):
            return [ClipRepresentation(uti: plainTextType, data: Data(text.utf8))]
        case .representations(let representations):
            return representations
        }
    }

    /// How often ← is pressed after the paste, to leave the caret where the content asks for
    /// it. Never more often than the text has characters.
    private static func leftArrowPresses(after content: PasteContent) -> Int {
        guard case .text(let text, let cursorOffsetFromEnd?) = content else { return 0 }
        let offset = max(cursorOffsetFromEnd, 0)
        return min(offset, text.count)
    }

    /// Ends a paste that could only copy: says so in the HUD and returns the result.
    private func finishByCopyingOnly(because reason: PasteResult.Reason) -> PasteResult {
        var message = String(
            localized: "Copied — press ⌘V", bundle: .module,
            comment:
                "HUD message when content was copied but could not be pasted into the previous app."
        )
        // What is missing is said once. After that the user knows, and may well have decided
        // to do without.
        if reason == .noAccessibility && !preferences.pasteAccessibilityHintShown {
            preferences.pasteAccessibilityHintShown = true
            message = String(
                localized:
                    "Copied — press ⌘V. Grant Accessibility in Settings to paste directly.",
                bundle: .module,
                comment:
                    "HUD message the first time a paste could only copy because OpenRay lacks the Accessibility permission."
            )
        }
        host.showHUD(message)
        return .copiedOnly(reason)
    }
}

extension ActionOutcome {
    /// What the HUD says after something was copied.
    static var copiedToClipboardMessage: String {
        String(
            localized: "Copied to Clipboard", bundle: .module,
            comment: "HUD message after an action copied something.")
    }

    /// What an action returns after it has copied something: the launcher closes and the HUD
    /// says that the content is on the clipboard.
    public static var copiedToClipboard: ActionOutcome {
        .showHUD(copiedToClipboardMessage)
    }
}
