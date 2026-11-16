import AppKit
import OpenRayCore

/// The only place Apple events are sent from (docs/DESIGN.md §4.2.10).
///
/// Sending blocks until the target has answered, so the sender is an actor on a queue of its
/// own: a slow target then holds up neither the main thread nor a thread of the cooperative
/// pool. The descriptor is built inside the actor, because `NSAppleEventDescriptor` is not
/// `Sendable`; callers describe the event with Core's `AppleEventDescription`.
actor AppleEventSender {
    enum SendError: Error, LocalizedError {
        /// The target answered with an error of its own.
        case targetFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .targetFailed(let status):
                // As text, because a number would be shown with a thousands separator.
                return String(localized: "The command failed (error \(String(status))).")
            }
        }
    }

    /// How long a target gets to answer an event that waits for a reply.
    private static let replyTimeout: TimeInterval = 30

    private let queue = DispatchSerialQueue(label: "\(AppInfo.bundleIdentifier).apple-events")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Sends the event. A target that is not running is launched in the background and the
    /// event is sent once more.
    ///
    /// - Returns: The reply's direct object when it is a Boolean, otherwise nil.
    @discardableResult
    func send(_ event: AppleEventDescription) async throws -> Bool? {
        do {
            return try deliver(event)
        } catch let error as NSError where Self.saysTargetIsNotRunning(error) {
            try await launchInBackground(appWithBundleID: event.targetBundleID)
            return try deliver(event)
        }
    }

    private static func saysTargetIsNotRunning(_ error: NSError) -> Bool {
        error.domain == NSOSStatusErrorDomain
            && error.code == Int(AutomationPermission.targetNotRunning)
    }

    private func deliver(_ event: AppleEventDescription) throws -> Bool? {
        let target = NSAppleEventDescriptor(bundleIdentifier: event.targetBundleID)
        let descriptor = NSAppleEventDescriptor(
            eventClass: event.eventClass, eventID: event.eventID, targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        for parameter in event.parameters {
            descriptor.setParam(
                Self.descriptor(for: parameter.value), forKeyword: parameter.keyword)
        }

        let options: NSAppleEventDescriptor.SendOptions =
            event.waitsForReply ? [.waitForReply, .neverInteract] : [.noReply]
        let reply = try descriptor.sendEvent(options: options, timeout: Self.replyTimeout)
        if !event.waitsForReply { return nil }

        // A target reports a failure of its own in the reply, not through `sendEvent`.
        if let errorNumber = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)) {
            let status = errorNumber.int32Value
            if status != noErr { throw SendError.targetFailed(status) }
        }
        return Self.booleanValue(of: reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
    }

    private static func descriptor(
        for value: AppleEventDescription.Value
    ) -> NSAppleEventDescriptor {
        switch value {
        case .boolean(let isOn):
            return NSAppleEventDescriptor(boolean: isOn)
        case .property(let path):
            // Built from the outside in: the application, then each property of what came
            // before, until the property that is meant.
            var specifier = NSAppleEventDescriptor.null()
            for code in path.reversed() {
                specifier = propertySpecifier(code, of: specifier)
            }
            return specifier
        }
    }

    /// An object specifier for "property `code` of `container`", as AppleScript builds one.
    private static func propertySpecifier(
        _ code: UInt32, of container: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        // The four parts of an object specifier: what kind of thing is wanted, how it is
        // named, its name, and what it is a part of.
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(
            NSAppleEventDescriptor(typeCode: OSType(cProperty)),
            forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(
            NSAppleEventDescriptor(enumCode: OSType(formPropertyID)),
            forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(
            NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        // A record with these four keys always coerces to an object specifier.
        return record.coerce(toDescriptorType: typeObjectSpecifier) ?? record
    }

    private static func booleanValue(of descriptor: NSAppleEventDescriptor?) -> Bool? {
        guard let descriptor else { return nil }
        let booleanTypes = [typeBoolean, typeTrue, typeFalse]
        guard booleanTypes.contains(descriptor.descriptorType) else { return nil }
        return descriptor.booleanValue
    }
}
