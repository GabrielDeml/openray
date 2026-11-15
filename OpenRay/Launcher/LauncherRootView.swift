import AppKit
import SwiftUI

/// Hosts `LauncherBody`. It never takes first responder: the search field is the only input in
/// the panel, and a click on the list must not take the keyboard away from it.
final class LauncherBodyHostingView: NSHostingView<LauncherBody> {
    override var acceptsFirstResponder: Bool { false }
}

/// The panel's content inside the glass: the search bar above the SwiftUI body.
final class LauncherRootView: NSView {
    init(searchBar: SearchBarView, body: LauncherBodyHostingView) {
        super.init(frame: .zero)
        // The panel has a fixed size; the hosting view must not derive window constraints
        // from its SwiftUI content.
        body.sizingOptions = []
        for view in [searchBar, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
