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
        /// `nil` while suspended.
        var ref: EventHotKeyRef?
    }

    /// "OpRy", the creator code in every `EventHotKeyID` this app registers.
    fileprivate nonisolated static let signature: OSType = 0x4F70_5279

    private var registrations: [HotKeySlot: Registration] = [:]
    private var handlerIsInstalled = false

    func register(_ key: HotKey, for slot: HotKeySlot) -> Result<Void, HotKeyError> {
        // Registering a chord this app already holds exclusively would fail.
        if let current = registrations[slot], current.key == key, current.ref != nil {
            return .success(())
        }
        installHandlerIfNeeded()

        // The new chord is taken before the old one is released, so a failure changes nothing.
        switch carbonRegister(key, for: slot) {
        case .success(let ref):
            unregister(slot)
            registrations[slot] = Registration(key: key, ref: ref)
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func unregister(_ slot: HotKeySlot) {
        guard let registration = registrations.removeValue(forKey: slot) else { return }
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

    func resumeAll() {
        for (slot, registration) in registrations where registration.ref == nil {
            switch carbonRegister(registration.key, for: slot) {
            case .success(let ref):
                registrations[slot]?.ref = ref
            case .failure(let error):
                Log.launcher.error(
                    "Hotkey \(slot.rawValue, privacy: .public) was not restored: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func carbonRegister(
        _ key: HotKey, for slot: HotKeySlot
    ) -> Result<EventHotKeyRef, HotKeyError> {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
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

    private func installHandlerIfNeeded() {
        guard !handlerIsInstalled else { return }
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
    guard let slot = HotKeySlot(rawValue: hotKeyID.id) else { return OSStatus(eventNotHandledErr) }

    let eventTime = GetEventTime(event)
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        center.onPress?(slot, eventTime)
    }
    return noErr
}
