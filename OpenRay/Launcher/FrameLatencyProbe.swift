import AppKit
import OpenRayCore
import os

/// A path of the latency budget (docs/DESIGN.md §4.1.9).
nonisolated enum LatencyPath: Hashable {
    case hotkeyToFirstFrame
    case keystrokeToResults

    var signpostName: StaticString {
        switch self {
        case .hotkeyToFirstFrame: return Signposts.hotkeyToFirstFrame
        case .keystrokeToResults: return Signposts.keystrokeToResults
        }
    }
}

/// Emits one signpost interval per measured path, from an input event to the first display
/// refresh after the launcher has committed what the event asked for.
///
/// A signpost interval cannot begin in the past, so it begins when the event is handled; the
/// time since the event itself is in the interval's end message.
final class FrameLatencyProbe: NSObject {
    private struct Measurement {
        let state: OSSignpostIntervalState
        /// When the input event happened, on the `systemUptime` clock.
        let eventTime: TimeInterval
        var awaitsFrame = false
    }

    private let view: NSView
    private var measurements: [LatencyPath: Measurement] = [:]
    private var displayLink: CADisplayLink?

    /// - Parameter view: A view in the launcher panel; its display supplies the refresh ticks.
    init(view: NSView) {
        self.view = view
    }

    /// Starts measuring `path` for an event that happened `eventAge` seconds ago. A measurement
    /// of the same path that has not reached a frame is abandoned.
    func begin(_ path: LatencyPath, eventAge: TimeInterval) {
        abandon(path)
        measurements[path] = Measurement(
            state: Signposts.signposter.beginInterval(path.signpostName),
            eventTime: ProcessInfo.processInfo.systemUptime - eventAge)
    }

    /// Ends the measurement of `path` at the next display refresh. Does nothing if `path` is
    /// not being measured.
    func endAtNextFrame(_ path: LatencyPath) {
        guard measurements[path] != nil else { return }
        measurements[path]?.awaitsFrame = true
        guard displayLink == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(displayDidRefresh))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Abandons every measurement: the panel left the screen, so no frame will come.
    func cancel() {
        for path in Array(measurements.keys) {
            abandon(path)
        }
        stopDisplayLink()
    }

    private func abandon(_ path: LatencyPath) {
        guard let measurement = measurements.removeValue(forKey: path) else { return }
        Signposts.signposter.endInterval(path.signpostName, measurement.state, "abandoned")
    }

    @objc private func displayDidRefresh(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        for (path, measurement) in measurements where measurement.awaitsFrame {
            let milliseconds = (now - measurement.eventTime) * 1000
            Signposts.signposter.endInterval(
                path.signpostName, measurement.state,
                "\(milliseconds, format: .fixed(precision: 1)) ms since the event")
            measurements[path] = nil
        }
        stopDisplayLink()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
}
