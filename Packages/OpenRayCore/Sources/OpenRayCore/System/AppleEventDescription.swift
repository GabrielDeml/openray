/// An Apple event, described with values that can cross isolation boundaries
/// (docs/DESIGN.md §4.2.10). The app target's `AppleEventSender` builds the real descriptor
/// from it and sends it; nothing in Core sends anything.
public struct AppleEventDescription: Sendable, Hashable {
    public enum Value: Sendable, Hashable {
        case boolean(Bool)
        /// A property of the target application, reached through a chain of properties. The
        /// codes go from the property that is meant outwards: `[dark mode, appearance
        /// preferences]` is "dark mode of appearance preferences".
        case property(path: [UInt32])
    }

    public struct Parameter: Sendable, Hashable {
        public var keyword: UInt32
        public var value: Value

        public init(keyword: UInt32, value: Value) {
            self.keyword = keyword
            self.value = value
        }
    }

    /// The bundle identifier of the app the event goes to. It is also what the Automation
    /// permission for the event is about.
    public var targetBundleID: String
    public var eventClass: UInt32
    public var eventID: UInt32
    public var parameters: [Parameter]
    /// Whether the sender waits for the target to answer. An event that starts something long
    /// does not: emptying a full Trash outlasts any sensible timeout.
    public var waitsForReply: Bool

    public init(
        targetBundleID: String, eventClass: UInt32, eventID: UInt32,
        parameters: [Parameter] = [], waitsForReply: Bool = true
    ) {
        self.targetBundleID = targetBundleID
        self.eventClass = eventClass
        self.eventID = eventID
        self.parameters = parameters
        self.waitsForReply = waitsForReply
    }

    /// The Automation permission macOS asks for before it delivers the event.
    public var permission: Permission {
        .automation(bundleID: targetBundleID)
    }

    /// A four-character code as the number Apple events carry: "aevt" is 0x61657674.
    static func code(_ characters: StaticString) -> UInt32 {
        precondition(characters.utf8CodeUnitCount == 4, "A four-character code has four bytes")
        var code: UInt32 = 0
        characters.withUTF8Buffer { bytes in
            for byte in bytes {
                code = code << 8 | UInt32(byte)
            }
        }
        return code
    }
}

/// The events behind the system commands.
///
/// The codes of the first two groups are from AERegistry.h and AppleEvents.h, and from QA1134
/// for the power events. Those of the last are from Finder.sdef and SystemEvents.sdef, read on
/// macOS 27: `empty` is `fndrempt`, `appearance preferences` is `aprp` and its `dark mode`
/// property is `thme`.
extension AppleEventDescription {
    public static let loginWindowBundleID = "com.apple.loginwindow"
    public static let finderBundleID = "com.apple.finder"
    public static let systemEventsBundleID = "com.apple.systemevents"

    private static let coreEventClass = code("aevt")  // kCoreEventClass
    private static let coreSuite = code("core")  // kAECoreSuite
    private static let getData = code("getd")  // kAEGetData
    private static let setData = code("setd")  // kAESetData
    private static let directObject = code("----")  // keyDirectObject
    private static let data = code("data")  // keyAEData

    /// Running apps can cancel a restart, a shutdown or a logout; loginwindow names the app
    /// that did. The events do not wait for that to play out.
    public static let restart = AppleEventDescription(
        targetBundleID: loginWindowBundleID, eventClass: coreEventClass, eventID: code("rest"),
        waitsForReply: false)  // kAERestart

    public static let shutDown = AppleEventDescription(
        targetBundleID: loginWindowBundleID, eventClass: coreEventClass, eventID: code("shut"),
        waitsForReply: false)  // kAEShutDown

    /// Logs out without the "Are you sure" dialog; the launcher has asked already.
    public static let logOut = AppleEventDescription(
        targetBundleID: loginWindowBundleID, eventClass: coreEventClass, eventID: code("rlgo"),
        waitsForReply: false)  // kAEReallyLogOut

    public static let emptyTrash = AppleEventDescription(
        targetBundleID: finderBundleID, eventClass: code("fndr"), eventID: code("empt"),
        waitsForReply: false)

    private static let darkMode = Value.property(path: [code("thme"), code("aprp")])

    /// Answers with a Boolean: whether the Mac is in dark mode.
    public static let getDarkMode = AppleEventDescription(
        targetBundleID: systemEventsBundleID, eventClass: coreSuite, eventID: getData,
        parameters: [Parameter(keyword: directObject, value: darkMode)])

    public static func setDarkMode(_ isOn: Bool) -> AppleEventDescription {
        AppleEventDescription(
            targetBundleID: systemEventsBundleID, eventClass: coreSuite, eventID: setData,
            parameters: [
                Parameter(keyword: directObject, value: darkMode),
                Parameter(keyword: data, value: .boolean(isOn)),
            ])
    }
}
