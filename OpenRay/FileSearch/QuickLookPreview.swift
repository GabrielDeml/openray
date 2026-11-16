import Quartz
import SwiftUI

/// A Quick Look preview of one file, drawn inside the launcher (docs/DESIGN.md §4.8).
///
/// This is `QLPreviewView` and not `QLPreviewPanel`: the panel is a window of its own that
/// takes control through the responder chain, and a window may come up behind the launcher.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // The initializer is failable, and its documentation names no case in which it
        // fails.
        let view = QLPreviewView(frame: .zero, style: .compact)!
        // Nothing plays until the user asks for it.
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        let shownURL = view.previewItem?.previewItemURL
        if shownURL != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        // A preview view lets go of its file when it is closed, and on its own it closes
        // only with its window. The launcher's panel is never closed, only hidden.
        view.close()
    }
}
