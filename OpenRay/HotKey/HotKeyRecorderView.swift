import AppKit
import Carbon.HIToolbox
import OpenRayCore
import SwiftUI

/// Shows the launcher hotkey and records a new one from the keyboard.
///
/// A click, Space or Return starts recording. While recording, a chord with at least one of ⌘, ⌃
/// or ⌥ becomes the hotkey, unless it is a reserved shortcut such as ⌘C; Esc cancels, and Delete
/// restores the default.
final class HotKeyRecorderView: NSView {
    private static let cornerRadius: CGFloat = 6

    private let launcherHotKey: LauncherHotKey
    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    /// The modifiers held down while recording, shown until a key completes the chord.
    private var heldModifiers: HotKey.Modifiers = []
    /// Why the last chord typed while recording was refused, shown until the next one is begun.
    private var refusal: String?

    init(launcherHotKey: LauncherHotKey) {
        self.launcherHotKey = launcherHotKey
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
        setAccessibilityLabel(String(localized: "Launcher hotkey"))

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
        } else {
            label.stringValue = HotKeyFormatter.string(for: launcherHotKey.hotKey)
            label.textColor = .labelColor
        }
        setAccessibilityValue(label.stringValue)
        needsDisplay = true
    }

    // MARK: Appearance

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

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
        launcherHotKey.record(key)
        refresh()
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }

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
                finishRecording(with: .launcherDefault)
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

/// `HotKeyRecorderView` for SwiftUI.
struct HotKeyRecorder: NSViewRepresentable {
    let launcherHotKey: LauncherHotKey

    func makeNSView(context: Context) -> HotKeyRecorderView {
        HotKeyRecorderView(launcherHotKey: launcherHotKey)
    }

    func updateNSView(_ view: HotKeyRecorderView, context: Context) {
        view.refresh()
    }
}
