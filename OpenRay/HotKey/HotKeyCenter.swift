import Carbon.HIToolbox
import OpenRayCore

/// Registers global hotkeys with Carbon, which needs no permission.
///
/// Lives as long as the app: the Carbon event handler keeps an unretained pointer to it.
final class HotKeyCenter: HotKeyRegistering {
    /// Called on the main actor with the time of the key press, on the clock of
    /// `GetCurrentEventTime()`.
    var onPress: ((HotKeySlot, _ eventTime: TimeInterval) -> Void)?

    private struct Registration {
        var key: HotKey
        /// What Carbon hands back with a press. The slot keeps it through a change of chord and
        /// through `suspendAll`.
        let carbonID: UInt32
        /// `nil` while suspended.
        var ref: EventHotKeyRef?
    }

    /// "OpRy", the creator code in every `EventHotKeyID` this app registers.
    fileprivate nonisolated static let signature: OSType = 0x4F70_5279

    private var registrations: [HotKeySlot: Registration] = [:]
    /// The slot of every Carbon ID in `registrations`, for the event handler.
    private var slotsByCarbonID: [UInt32: HotKeySlot] = [:]
    private var lastCarbonID: UInt32 = 0
    private var handlerIsInstalled = false

    func register(_ key: HotKey, for slot: HotKeySlot) -> Result<Void, HotKeyError> {
        // The slot already has this chord. Carbon is not asked again.
        if let current = registrations[slot], current.key == key, current.ref != nil {
            return .success(())
        }
        // Nor is Carbon asked for a chord that another slot has, registered or suspended. What
        // it answers for a chord this app already holds has not been tried on a Mac
        // (docs/DESIGN.md §8, item 36). If it took the chord a second time, one press would
        // fire two slots.
        if let otherSlot = holder(of: key, otherThan: slot) {
            return .failure(.heldBySlot(otherSlot))
        }
        // Without the handler, a registered hotkey would be held but never reach `onPress`.
        let handlerStatus = installHandlerIfNeeded()
        if handlerStatus != noErr {
            return .failure(.rejected(handlerStatus))
        }

        let previous = registrations[slot]
        let carbonID = previous?.carbonID ?? makeCarbonID()

        // The new chord is taken before the old one is released, so a failure changes nothing.
        switch carbonRegister(key, carbonID: carbonID) {
        case .success(let ref):
            if let previousRef = previous?.ref {
                UnregisterEventHotKey(previousRef)
            }
            registrations[slot] = Registration(key: key, carbonID: carbonID, ref: ref)
            slotsByCarbonID[carbonID] = slot
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    private func holder(of key: HotKey, otherThan slot: HotKeySlot) -> HotKeySlot? {
        for (otherSlot, registration) in registrations {
            if otherSlot != slot && registration.key == key {
                return otherSlot
            }
        }
        return nil
    }

    /// An ID for a slot the center does not know yet. No ID is handed out twice, so a press
    /// that Carbon delivers late can never be taken for another slot's.
    private func makeCarbonID() -> UInt32 {
        lastCarbonID += 1
        return lastCarbonID
    }

    func unregister(_ slot: HotKeySlot) {
        guard let registration = registrations.removeValue(forKey: slot) else { return }
        slotsByCarbonID[registration.carbonID] = nil
        if let ref = registration.ref {
            UnregisterEventHotKey(ref)
        }
    }

    func suspendAll() {
        for (slot, registration) in registrations {
            if let ref = registration.ref {
                UnregisterEventHotKey(ref)
            }
            registrations[slot]?.ref = nil
        }
    }

    func resumeAll() -> [HotKeySlot: HotKeyError] {
        var failures: [HotKeySlot: HotKeyError] = [:]
        for (slot, registration) in registrations where registration.ref == nil {
            switch carbonRegister(registration.key, carbonID: registration.carbonID) {
            case .success(let ref):
                registrations[slot]?.ref = ref
            case .failure(let error):
                logFailedRestore(of: slot, error: error)
                // The slot is forgotten, not left suspended: it has no hotkey until the caller
                // registers one again.
                registrations[slot] = nil
                slotsByCarbonID[registration.carbonID] = nil
                failures[slot] = error
            }
        }
        return failures
    }

    private func logFailedRestore(of slot: HotKeySlot, error: HotKeyError) {
        switch slot {
        case .launcher:
            Log.launcher.error(
                "The launcher hotkey was not restored: \(error.logDescription, privacy: .public)")
        case .command(let id):
            // Private, because the ID of an app or a script can be a path.
            Log.launcher.error(
                """
                The hotkey of \(id.rawValue, privacy: .private) was not restored: \
                \(error.logDescription, privacy: .public)
                """)
        }
    }

    /// Tells `onPress` which slot's hotkey was pressed.
    /// - Returns: Whether the ID is one of this center's. An ID it does not know is the press
    ///   of a hotkey that was unregistered while its event was on the way.
    fileprivate func hotKeyWasPressed(carbonID: UInt32, at eventTime: TimeInterval) -> Bool {
        guard let slot = slotsByCarbonID[carbonID] else { return false }
        onPress?(slot, eventTime)
        return true
    }

    private func carbonRegister(
        _ key: HotKey, carbonID: UInt32
    ) -> Result<EventHotKeyRef, HotKeyError> {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: carbonID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            key.keyCode,
            key.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        if status == noErr, let ref {
            return .success(ref)
        }
        if status == OSStatus(eventHotKeyExistsErr) {
            return .failure(.inUseByAnotherApp)
        }
        return .failure(.rejected(status))
    }

    /// - Returns: `noErr` once the handler is installed, otherwise why Carbon refused it.
    private func installHandlerIfNeeded() -> OSStatus {
        guard !handlerIsInstalled else { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Carbon hands this pointer back to `handleHotKeyEvent` as its `userData`.
        let unretainedSelf = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handleHotKeyEvent,
            1,
            &eventType,
            unretainedSelf,
            nil
        )
        if status == noErr {
            handlerIsInstalled = true
        } else {
            Log.launcher.error("Hotkey handler was not installed: \(status, privacy: .public)")
        }
        return status
    }
}

/// The Carbon event handler. Carbon dispatches application-target events on the main run loop,
/// which `MainActor.assumeIsolated` checks.
private nonisolated func handleHotKeyEvent(
    _: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    // Other code in this process may register hotkeys of its own; those are not ours to handle.
    guard hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }

    let carbonID = hotKeyID.id
    let eventTime = GetEventTime(event)
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    // Which slot the ID stands for is the center's state, so it is looked up on the main actor.
    let wasHandled = MainActor.assumeIsolated {
        center.hotKeyWasPressed(carbonID: carbonID, at: eventTime)
    }
    return wasHandled ? noErr : OSStatus(eventNotHandledErr)
}
