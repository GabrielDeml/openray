import AppKit
import Carbon.HIToolbox
import OpenRayCore
import SwiftUI

/// What a recorder shows and changes: the launcher's hotkey, or the hotkey of one command.
struct HotKeyRecorderTarget {
    let accessibilityLabel: String
    /// nil for a command that has no hotkey.
    let current: () -> HotKey?
    let record: (HotKey) -> Void
    /// What Delete or Forward Delete does when it is pressed on its own while recording.
    let delete: () -> Void

    static func launcher(_ launcherHotKey: LauncherHotKey) -> HotKeyRecorderTarget {
        HotKeyRecorderTarget(
            accessibilityLabel: String(localized: "Launcher hotkey"),
            current: { launcherHotKey.hotKey },
            record: { key in launcherHotKey.record(key) },
            // The launcher cannot be left without a hotkey, so Delete brings back the default.
            delete: { launcherHotKey.record(.launcherDefault) })
    }

    static func command(
        _ item: ItemID, title: String, commandHotKeys: CommandHotKeys
    ) -> HotKeyRecorderTarget {
        HotKeyRecorderTarget(
            accessibilityLabel: String(localized: "Hotkey of \(title)"),
            current: { commandHotKeys.hotKey(for: item) },
            record: { key in
                Task { await commandHotKeys.assign(key, to: item) }
            },
            delete: {
                Task { await commandHotKeys.clear(item) }
            })
    }
}

/// Shows a hotkey and records a new one from the keyboard.
///
/// A click, Space or Return starts recording. While recording, a chord with at least one of ⌘, ⌃
/// or ⌥ becomes the hotkey, unless it is a reserved shortcut such as ⌘C; Esc cancels, and Delete
/// restores the launcher's default or removes a command's hotkey.
final class HotKeyRecorderView: NSView {
    private static let cornerRadius: CGFloat = 6

    private let target: HotKeyRecorderTarget
    /// Begins and ends the recording whatever the target is, because that releases every
    /// hotkey of OpenRay and not only the one being recorded.
    private let launcherHotKey: LauncherHotKey
    /// The view reports this as its intrinsic width, which is what SwiftUI lays it out with.
    private let width: CGFloat
    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    /// The modifiers held down while recording, shown until a key completes the chord.
    private var heldModifiers: HotKey.Modifiers = []
    /// Why the last chord typed while recording was refused, shown until the next one is begun.
    private var refusal: String?

    init(target: HotKeyRecorderTarget, launcherHotKey: LauncherHotKey, width: CGFloat = 150) {
        self.target = target
        self.launcherHotKey = launcherHotKey
        self.width = width
        super.init(frame: .zero)
        wantsLayer = true
        focusRingType = .exterior

        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(target.accessibilityLabel)

        // The key's name depends on the keyboard layout.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refresh),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the current hotkey, or the recording prompt.
    @objc func refresh() {
        if isRecording {
            if let refusal {
                label.stringValue = refusal
            } else if heldModifiers.isEmpty {
                label.stringValue = String(localized: "Type shortcut")
            } else {
                label.stringValue = HotKeyFormatter.symbols(for: heldModifiers)
            }
            label.textColor = .secondaryLabelColor
        } else if let hotKey = target.current() {
            label.stringValue = HotKeyFormatter.string(for: hotKey)
            label.textColor = .labelColor
        } else {
            label.stringValue = String(localized: "Record Hotkey")
            label.textColor = .secondaryLabelColor
        }
        setAccessibilityValue(label.stringValue)
        needsDisplay = true
    }

    // MARK: Appearance

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: 26) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = Self.cornerRadius
        layer.backgroundColor = NSColor.quaternarySystemFill.cgColor
        if isRecording {
            layer.borderWidth = 2
            layer.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            layer.borderWidth = 1
            layer.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
        ).fill()
    }

    // MARK: Starting and stopping

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        // Carbon would otherwise consume the current hotkey before this view saw it.
        launcherHotKey.beginRecording()
        heldModifiers = []
        refusal = nil
        refresh()
    }

    /// Stops without changing the hotkey. Also runs when the window stops being the key window.
    @objc private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        launcherHotKey.endRecording()
        heldModifiers = []
        refusal = nil
        refresh()
    }

    /// Recording ends first: that restores the current hotkey, which the new one then replaces.
    private func finishRecording(with key: HotKey) {
        stopRecording()
        target.record(key)
        refresh()
    }

    /// As `finishRecording(with:)`, for Delete.
    private func finishRecordingByDeleting() {
        stopRecording()
        target.delete()
        refresh()
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }

    /// The label must never be the hit view. In a row of Settings › Commands the list is a
    /// table view, which keeps a click on a text field in a cell for itself, and the recorder
    /// would not see a click on its own text.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if super.hitTest(point) == nil { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        startRecording()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            keyPressedWhileRecording(event)
            return
        }
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Space || keyCode == kVK_Return {
            startRecording()
        } else {
            super.keyDown(with: event)
        }
    }

    /// ⌘ chords arrive here first; without this a ⌘W typed while recording would close the window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyPressedWhileRecording(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        let nowHeld = HotKey.Modifiers(eventModifierFlags: event.modifierFlags.rawValue)
        // A modifier going down begins the next chord. Letting go of the modifiers of a refused
        // chord must not clear the reason, or it would be gone before anyone could read it.
        let modifierWentDown = !nowHeld.isSubset(of: heldModifiers)
        if modifierWentDown {
            refusal = nil
        }
        heldModifiers = nowHeld
        refresh()
    }

    private func keyPressedWhileRecording(_ event: NSEvent) {
        // A held key repeats. Its first press was answered, and answering every repeat would
        // beep for as long as a refused key is held down.
        if event.isARepeat { return }

        let keyCode = Int(event.keyCode)
        let modifiers = HotKey.Modifiers(eventModifierFlags: event.modifierFlags.rawValue)

        // Esc and Delete are commands only when pressed on their own. With a modifier they are
        // chords like any other, so ⌘⎋ can be recorded.
        if modifiers.isEmpty {
            if keyCode == kVK_Escape {
                stopRecording()
                return
            }
            if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
                finishRecordingByDeleting()
                return
            }
        }

        let key = HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        if key.validate() == .needsModifier {
            refuse(because: String(localized: "Add ⌘, ⌃ or ⌥"))
            return
        }
        // A reserved shortcut is told by the letter its key types with ⌘ held. On most layouts
        // that is the letter it types without ⌘, but not on "Dvorak – QWERTY ⌘", where the key
        // that types "j" is ⌘C.
        let typed =
            modifiers.contains(.command) ? event.characters : event.charactersIgnoringModifiers
        let pressed = KeyChord(keyCode: event.keyCode, modifiers: modifiers, characters: typed)
        if HotKey.isReservedShortcut(pressed) {
            let chord = HotKeyFormatter.string(for: key)
            refuse(because: String(localized: "\(chord) is reserved"))
            return
        }
        finishRecording(with: key)
    }

    /// Keeps recording, and says in the recorder why the chord was not taken.
    private func refuse(because reason: String) {
        NSSound.beep()
        refusal = reason
        refresh()
    }

    // MARK: Leaving

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        // The view may have come from another window, which it must stop watching.
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else {
            stopRecording()
            return
        }
        center.addObserver(
            self, selector: #selector(stopRecording),
            name: NSWindow.didResignKeyNotification, object: window)
    }
}

/// `HotKeyRecorderView` for SwiftUI, on the launcher's hotkey.
struct HotKeyRecorder: NSViewRepresentable {
    let launcherHotKey: LauncherHotKey

    func makeNSView(context: Context) -> HotKeyRecorderView {
        HotKeyRecorderView(target: .launcher(launcherHotKey), launcherHotKey: launcherHotKey)
    }

    func updateNSView(_ view: HotKeyRecorderView, context: Context) {
        view.refresh()
    }
}

/// `HotKeyRecorderView` for SwiftUI, on the hotkey of one command, for its row in
/// Settings › Commands.
struct CommandHotKeyRecorder: NSViewRepresentable {
    /// Wide enough for "Record Hotkey" and for the reasons a chord is refused with, of which
    /// "⇧⌘Z is reserved" is the longest: about 110 points of text, and 8 of padding on each
    /// side.
    private static let width: CGFloat = 130

    let item: ItemID
    let title: String
    /// The item's hotkey as the row read it. The view asks `commandHotKeys` itself; this is
    /// here so that SwiftUI sees a change and calls `updateNSView`. A change arrives a moment
    /// after the recorder has ended, because assigning and clearing are asynchronous.
    let hotKey: HotKey?
    let commandHotKeys: CommandHotKeys
    let launcherHotKey: LauncherHotKey

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let target = HotKeyRecorderTarget.command(
            item, title: title, commandHotKeys: commandHotKeys)
        return HotKeyRecorderView(
            target: target, launcherHotKey: launcherHotKey, width: Self.width)
    }

    func updateNSView(_ view: HotKeyRecorderView, context: Context) {
        view.refresh()
    }
}
