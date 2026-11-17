import Observation
import os

/// The global hotkeys of commands: which item has which chord, which of them are registered,
/// and why one is not.
///
/// An assignment is kept for as long as the user leaves it, and registered while its item
/// exists and is enabled. So the hotkey of an app that is being updated, or of a script on a
/// disk that is not mounted, is back when the item is, and a disabled item's hotkey does
/// nothing without being forgotten. A hidden item keeps its hotkey working: hidden is about
/// root search, and a hotkey is not a search.
///
/// The assignments are read from the store once and are then the truth for this run, written
/// through on every change. The store is not followed the way `CommandsSettingsModel` follows
/// its store, because an emission from before a change could arrive after it and undo a chord
/// that was just registered. The only rows that go without this model knowing are those of a
/// deleted quicklink or snippet. Their assignment stays here until OpenRay quits, as that of
/// an item that is gone, which is what it is.
///
/// `HotKey.validate` and `HotKey.isReservedShortcut` are not asked again here. The second
/// needs the key press with what the key types, which only the recorder has, and the recorder
/// is the only way a chord gets here.
@MainActor @Observable public final class CommandHotKeys {
    /// Why a chord the user tried for an item was not taken. The item keeps what it had.
    public enum Refusal: Equatable, Sendable {
        /// The chord is the launcher's own hotkey.
        case opensLauncher(HotKey)
        /// The chord is the hotkey of another item.
        case belongsTo(HotKey, itemTitle: String)
        case notRegistered(HotKeyFailure)
    }

    public private(set) var assignments: [ItemID: HotKey] = [:]
    /// The items whose stored hotkey is not registered although it should be. An entry stays
    /// until the hotkey is registered, or its item is gone, disabled or without a hotkey.
    public private(set) var failures: [ItemID: HotKeyFailure] = [:]
    /// For each item, why the chord last tried for it was refused. An entry goes with the next
    /// try for that item, and all of them with `clearRefusals()`.
    public private(set) var refusals: [ItemID: Refusal] = [:]
    /// Why the hotkeys could not be read, or the last change could not be stored.
    public private(set) var errorMessage: String?

    /// The items the registry last published, by ID. Empty until the first `update`.
    private var itemsByID: [ItemID: SearchItem] = [:]
    private var overrides = CommandOverrides()
    /// The chord each command's slot is registered with.
    private var registered: [ItemID: HotKey] = [:]
    private var isLoaded = false
    private var isRecording = false

    @ObservationIgnored private let store: CommandHotKeyStore
    @ObservationIgnored private let registrar: any HotKeyRegistering
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let showSettings: @MainActor (ItemID) -> Void

    /// - Parameter showSettings: Opens Settings › Commands on the item, for "Set Hotkey…".
    public init(
        store: CommandHotKeyStore, registrar: any HotKeyRegistering, preferences: Preferences,
        showSettings: @escaping @MainActor (ItemID) -> Void
    ) {
        self.store = store
        self.registrar = registrar
        self.preferences = preferences
        self.showSettings = showSettings
    }

    /// Reads the stored hotkeys, once, at launch. When they cannot be read there are none for
    /// this run, and `errorMessage` says why.
    public func load() async {
        do {
            assignments = try await store.all()
        } catch {
            Log.storage.error("Cannot read the command hotkeys: \(error)")
            errorMessage = error.localizedDescription
        }
        isLoaded = true
        synchronizeRegistrations()
    }

    /// Takes the registry's items and overrides as it has just published them. Hotkeys whose
    /// item has appeared or was enabled are registered, those whose item is gone or disabled
    /// are released, and one that could not be registered before is tried again.
    ///
    /// - Parameter items: Everything the sources have yielded, hidden and disabled items
    ///   included (`CommandRegistry.items`).
    public func update(items: [SearchItem], overrides: CommandOverrides) {
        var itemsByID: [ItemID: SearchItem] = [:]
        for item in items {
            itemsByID[item.id] = item
        }
        self.itemsByID = itemsByID
        self.overrides = overrides
        synchronizeRegistrations()
    }

    // MARK: Reading

    public func hotKey(for id: ItemID) -> HotKey? {
        assignments[id]
    }

    /// Whether the item is one the sources have yielded. Anything else, such as a file or a
    /// calculator result, exists only for one query and cannot have a hotkey.
    public func canHaveHotKey(_ id: ItemID) -> Bool {
        itemsByID[id] != nil
    }

    public func title(of id: ItemID) -> String? {
        itemsByID[id]?.title
    }

    /// The item that holds the chord: it has the chord as its hotkey and is one the sources
    /// have yielded, disabled or not. The launcher's recorder asks before it takes a chord,
    /// because a hotkey that is stored and not registered at the moment is unknown to the
    /// registrar. An item that is gone does not hold its chord.
    public func holder(of key: HotKey) -> ItemID? {
        guard let id = itemAssigned(key) else { return nil }
        if itemsByID[id] == nil { return nil }
        return id
    }

    /// The item to run for a press of its hotkey, or nil when it is gone or disabled. Such an
    /// item's hotkey is not registered, but a press can be on its way while it is released.
    public func item(pressedFor id: ItemID) -> SearchItem? {
        if overrides.isDisabled(id) { return nil }
        return itemsByID[id]
    }

    /// The action that leads from an item in the launcher to where its hotkey is set, or nil
    /// for an item that cannot have one.
    public func settingsAction(for id: ItemID) -> ActionDescriptor? {
        guard canHaveHotKey(id) else { return nil }

        let title = String(
            localized: "Set Hotkey…", bundle: .module,
            comment:
                "The action that opens Settings, where the selected item can be given a global hotkey."
        )
        let showSettings = showSettings

        return ActionDescriptor(
            id: ActionID(rawValue: "set-hotkey"), title: title, icon: .symbol("keyboard")
        ) { context in
            // Settings is a window outside the panel.
            context.closeLauncher()
            showSettings(id)
            return .closeLauncher
        }
    }

    // MARK: Changing

    /// Makes `key` the hotkey of the item, or says in `refusals` why not. A chord that is
    /// refused leaves the item with the hotkey it had.
    ///
    /// Everything up to the write to the store happens before the first suspension, so the
    /// item's row shows the outcome at once.
    public func assign(_ key: HotKey, to id: ItemID) async {
        // Before the stored hotkeys are read there is nothing to check the chord against.
        guard isLoaded, canHaveHotKey(id) else { return }
        refusals[id] = nil

        if key == preferences.launcherHotKey {
            refusals[id] = .opensLauncher(key)
            return
        }

        // An item that is gone does not hold its chord: the next item that asks for it gets it.
        var goneHolder: ItemID?
        if let assigned = itemAssigned(key), assigned != id {
            if let holderItem = itemsByID[assigned] {
                refusals[id] = .belongsTo(key, itemTitle: holderItem.title)
                return
            }
            goneHolder = assigned
        }

        // A disabled item's hotkey is only stored. It is registered when the item is enabled.
        let isEnabled = !overrides.isDisabled(id)
        if isEnabled && registered[id] != key {
            switch registrar.register(key, for: .command(id)) {
            case .success:
                registered[id] = key
                failures[id] = nil
            case .failure(let error):
                // The registrar has left the item's previous hotkey as it was.
                refusals[id] = .notRegistered(HotKeyFailure(hotKey: key, error: error))
                return
            }
        }

        // The chord the item already has: recording it again was a new try at registering it,
        // and there is nothing to store.
        if assignments[id] == key { return }

        // Its row goes with the write below.
        if let goneHolder {
            assignments[goneHolder] = nil
        }
        assignments[id] = key
        await write { try await self.store.set(key, for: id) }
    }

    public func clear(_ id: ItemID) async {
        refusals[id] = nil
        failures[id] = nil
        guard assignments[id] != nil else { return }

        if registered[id] != nil {
            registrar.unregister(.command(id))
            registered[id] = nil
        }
        assignments[id] = nil
        await write { try await self.store.remove(id) }
    }

    /// Forgets every refusal. The Commands pane calls this when it appears, so that it does
    /// not open on what went wrong the last time it was used.
    public func clearRefusals() {
        refusals = [:]
    }

    // MARK: Recording

    /// A recorder has released every hotkey to see the chords itself (`suspendAll`). Until it
    /// has ended nothing is registered here: a chord registered now would never reach it.
    public func recorderDidBegin() {
        isRecording = true
    }

    /// The recorder has ended and the hotkeys were registered again (`resumeAll`).
    ///
    /// - Parameter notRestored: What `resumeAll` returned. The registrar has forgotten these
    ///   slots, so each command among them is asked for again right away, and becomes that
    ///   item's failure if the chord is still refused.
    public func recorderDidEnd(notRestored: [HotKeySlot: HotKeyError]) {
        isRecording = false
        for slot in notRestored.keys {
            if case .command(let id) = slot {
                registered[id] = nil
            }
        }
        synchronizeRegistrations()
    }

    // MARK: The launcher's hotkey

    /// The launcher was given another hotkey. A command that was refused its chord because
    /// the launcher was on it, as its fallback, can have it now.
    public func launcherHotKeyDidChange() {
        synchronizeRegistrations()
    }

    // MARK: Registering

    /// Brings the registrations in line with the assignments: a hotkey is registered while its
    /// item exists and is enabled.
    private func synchronizeRegistrations() {
        if isRecording { return }

        // By ID, so that the registrar is asked in the same order on every run.
        let idsInOrder = assignments.keys.sorted { first, second in
            first.rawValue < second.rawValue
        }

        for id in idsInOrder {
            guard let hotKey = assignments[id] else { continue }

            let isAvailable = itemsByID[id] != nil && !overrides.isDisabled(id)
            if isAvailable {
                // Also asked for when it was refused before: the app that had the chord may
                // have let go of it.
                if registered[id] != hotKey {
                    registerStoredHotKey(hotKey, for: id)
                }
            } else {
                if registered[id] != nil {
                    registrar.unregister(.command(id))
                    registered[id] = nil
                }
                failures[id] = nil
            }
        }
    }

    private func registerStoredHotKey(_ hotKey: HotKey, for id: ItemID) {
        switch registrar.register(hotKey, for: .command(id)) {
        case .success:
            registered[id] = hotKey
            failures[id] = nil
            // The row may still say that this chord was refused, from a try in the recorder
            // while the other app had it.
            if case .notRegistered(let refused) = refusals[id], refused.hotKey == hotKey {
                refusals[id] = nil
            }
        case .failure(let error):
            let failure = HotKeyFailure(hotKey: hotKey, error: error)
            // The registry publishes often, and every time this is tried again. Only a new
            // answer is worth a line in the log.
            if failures[id] != failure {
                failures[id] = failure
                // The ID is private because that of an app or a script can be a path.
                Log.launcher.error(
                    """
                    The hotkey of \(id.rawValue, privacy: .private) was not registered: \
                    \(error.logDescription, privacy: .public)
                    """)
            }
        }
    }

    /// The item whose hotkey the chord is, whether or not the item is still there. There is
    /// at most one: `assign` gives a chord to one item only.
    private func itemAssigned(_ key: HotKey) -> ItemID? {
        for (id, hotKey) in assignments {
            if hotKey == key {
                return id
            }
        }
        return nil
    }

    // MARK: Writing

    /// Runs one change to the store. When it fails the change still holds until OpenRay
    /// quits, like a pick that could not be written, and `errorMessage` says why it will not
    /// be there afterwards.
    private func write(_ change: () async throws -> Void) async {
        do {
            try await change()
            errorMessage = nil
        } catch {
            Log.storage.error("Cannot store a command hotkey: \(error)")
            errorMessage = error.localizedDescription
        }
    }
}
