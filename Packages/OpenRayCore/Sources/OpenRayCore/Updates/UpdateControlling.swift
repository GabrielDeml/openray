import Foundation

/// The updater, as far as OpenRay's own views and commands need it (docs/DESIGN.md §6.4). The
/// app target implements it with Sparkle, which keeps both settings in the user defaults and
/// shows every window of an update itself.
@MainActor public protocol UpdateControlling: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    /// Whether an update that was found is downloaded and installed without asking. Sparkle
    /// reads this as false, and ignores a change, while automatic checks are off.
    var automaticallyDownloadsUpdates: Bool { get set }
    /// False while a check or a download is under way in the background.
    var canCheckForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    /// The check the user asks for. It shows its progress and its result, and it brings an
    /// update that is already waiting to the front.
    func checkForUpdates()
}

/// Whether this build can update itself.
public enum UpdaterAvailability: Sendable, Equatable {
    case available
    /// A Debug build, which starts no updater (§6.6).
    case developmentBuild
    /// A build whose Info.plist names no feed or no public key. The key is empty in the
    /// repository until the owner has made one.
    case notConfigured

    /// - Parameters:
    ///   - feedURL: `SUFeedURL` of the running bundle.
    ///   - publicKey: `SUPublicEDKey` of the running bundle. To Sparkle an empty key is an
    ///     invalid one, not a missing one, and an updater started with it shows an alert that
    ///     is meant for developers. So an empty key counts as none here.
    public init(isDebugBuild: Bool, feedURL: String?, publicKey: String?) {
        if isDebugBuild {
            self = .developmentBuild
        } else if Self.isBlank(feedURL) || Self.isBlank(publicKey) {
            self = .notConfigured
        } else {
            self = .available
        }
    }

    private static func isBlank(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
