import AppKit
import SwiftUI

/// Shows a short message near the bottom of the screen and lets it fade (docs/DESIGN.md
/// §4.1.6). It has a window of its own, so it works whether the launcher is open or not.
final class HUDController {
    /// How long a message stays before it fades.
    private static let displayTime: Duration = .milliseconds(1500)
    private static let fadeDuration: TimeInterval = 0.25
    /// The gap between the message and the bottom of the screen's usable area.
    private static let bottomInset: CGFloat = 96

    private let panel: NSPanel
    private let hostingView: NSHostingView<HUDView>
    private var dismissal: Task<Void, Never>?

    init() {
        // Like the launcher: it never takes focus, and it sits above full-screen Spaces.
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient,
            .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.level = .screenSaver

        hostingView = NSHostingView(rootView: HUDView(text: ""))
        panel.contentView = hostingView
    }

    /// Shows `text`, replacing a message that is still up.
    func show(_ text: String) {
        hostingView.rootView = HUDView(text: text)
        let size = hostingView.fittingSize
        panel.setFrame(frame(forMessageOfSize: size), display: true)
        // Through the animator and without a duration, which also ends a fade that is still
        // running. Setting the value directly would leave that fade to finish at zero.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        // The message is in a window nobody focuses, so assistive technologies are told.
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])

        dismissal?.cancel()
        dismissal = Task {
            try? await Task.sleep(for: Self.displayTime)
            if Task.isCancelled { return }
            await fadeOut()
        }
    }

    private func fadeOut() async {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion {
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            }
        }
        // A newer message has taken the window over while this one faded.
        if Task.isCancelled { return }
        panel.orderOut(nil)
    }

    /// Centred near the bottom of the display the mouse is on, where the launcher opens too.
    private func frame(forMessageOfSize size: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: (area.midX - size.width / 2).rounded(),
            y: (area.minY + Self.bottomInset).rounded())
        return NSRect(origin: origin, size: size)
    }
}

/// One line of text on a dark rounded plate.
private struct HUDView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .background(
                .black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .fixedSize()
    }
}
