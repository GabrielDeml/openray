// The whole file is for Debug builds only. A Release build has no probe.
#if DEBUG

    import AppKit
    import Observation
    import OpenRayCore
    import SwiftUI

    /// One of the pasteboard calls the experiment is about.
    private enum PasteboardCall: String, CaseIterable, Identifiable {
        case accessBehavior
        case changeCount
        case types
        case string = "string(forType: .string)"

        var id: String { rawValue }
    }

    /// Makes one call to the general pasteboard at a time, when its button is pressed, and
    /// writes down which call it was and what came back (docs/DESIGN.md §4.5).
    ///
    /// The experiment is to find out which of the calls makes macOS show its pasteboard
    /// privacy alert, so nothing here touches the pasteboard except the one call that was asked
    /// for. What is written down is never the pasteboard's contents: a count, the names of the
    /// types, or the length of the string.
    @Observable
    private final class PasteboardProbe {
        static let delayInSeconds = 5

        private(set) var log: [String] = []
        /// True from a press until its call has returned. The buttons are off meanwhile, so
        /// that two calls never overlap and every answer in the log belongs to one press.
        private(set) var isBusy = false
        /// Wait before the call, so that the person running the experiment can switch to
        /// another app first. The clipboard monitor would read while OpenRay is in the
        /// background, and macOS may treat that differently.
        var waitsBeforeCalling = false

        func run(_ call: PasteboardCall) {
            isBusy = true
            Task {
                defer { isBusy = false }
                if waitsBeforeCalling {
                    let seconds = Self.delayInSeconds
                    note("\(call.rawValue): in \(seconds) seconds. Switch to another app now.")
                    try? await Task.sleep(for: .seconds(seconds))
                }

                let place = NSApp.isActive ? "OpenRay is frontmost" : "OpenRay is in the background"
                note("\(call.rawValue): calling now (\(place))")
                // The line above has to be on screen before the call: if macOS asks, the call
                // may not return until the alert is answered.
                try? await Task.sleep(for: .milliseconds(200))

                let start = ContinuousClock.now
                let answer = makeCall(call)
                let elapsed = ContinuousClock.now - start
                let milliseconds = elapsed.formatted(.units(allowed: [.milliseconds]))
                note("\(call.rawValue): returned \(answer) after \(milliseconds)")
            }
        }

        private func note(_ text: String) {
            let time = Date().formatted(date: .omitted, time: .standard)
            log.append("\(time)  \(text)")
        }

        /// The one place the probe touches the pasteboard.
        private func makeCall(_ call: PasteboardCall) -> String {
            let pasteboard = NSPasteboard.general
            switch call {
            case .accessBehavior:
                return name(of: pasteboard.accessBehavior)
            case .changeCount:
                return String(pasteboard.changeCount)
            case .types:
                guard let types = pasteboard.types else { return "nil" }
                let names = types.map(\.rawValue).joined(separator: ", ")
                return "\(types.count) types: \(names)"
            case .string:
                guard let string = pasteboard.string(forType: .string) else { return "nil" }
                return "a string of \(string.count) characters"
            }
        }

        private func name(of behavior: NSPasteboard.AccessBehavior) -> String {
            switch behavior {
            case .default: return ".default"
            case .ask: return ".ask"
            case .alwaysAllow: return ".alwaysAllow"
            case .alwaysDeny: return ".alwaysDeny"
            @unknown default: return "a behavior this build does not know (\(behavior.rawValue))"
            }
        }
    }

    /// The window of the pasteboard privacy experiment. A Debug build shows it, and starts
    /// nothing else, when it is launched with `-OpenRayPasteboardProbe`.
    final class PasteboardProbeWindowController: NSWindowController, NSWindowDelegate {
        static let launchArgument = "-OpenRayPasteboardProbe"

        init() {
            let content = PasteboardProbeView(probe: PasteboardProbe())
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.styleMask = [.titled, .closable]
            window.title = "Pasteboard Probe"
            window.setContentSize(NSSize(width: 620, height: 440))
            window.center()
            window.isReleasedWhenClosed = false
            super.init(window: window)
            window.delegate = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func show() {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }

        func windowWillClose(_ notification: Notification) {
            // The probe is all this run of the app is for.
            NSApp.terminate(nil)
        }
    }

    private struct PasteboardProbeView: View {
        @Bindable var probe: PasteboardProbe

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Each button makes one call to NSPasteboard.general and nothing else. Press one, watch whether macOS shows an alert, and note it down. Contents are never shown. To keep the log, take a screenshot: copying from this window would change the pasteboard."
                )
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    ForEach(PasteboardCall.allCases) { call in
                        Button(call.rawValue) {
                            probe.run(call)
                        }
                    }
                }
                .disabled(probe.isBusy)
                Toggle(
                    "Wait \(PasteboardProbe.delayInSeconds) seconds before the call, to switch to another app first",
                    isOn: $probe.waitsBeforeCalling)

                // The text cannot be selected: copying a line of it would put OpenRay's own
                // text on the pasteboard, and the calls after that would read that back.
                ScrollView {
                    Text(probe.log.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                // The newest line stays in view. It says which call is being made, and while
                // macOS holds a call behind its alert the log cannot be scrolled.
                .defaultScrollAnchor(.bottom)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                Text(
                    "\(ProcessInfo.processInfo.operatingSystemVersionString) · \(AppInfo.bundleIdentifier)"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(minWidth: 620, minHeight: 440)
        }
    }

#endif
