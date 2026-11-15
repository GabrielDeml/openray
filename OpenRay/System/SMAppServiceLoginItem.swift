import OpenRayCore
import ServiceManagement

/// Launch at login through `SMAppService` (docs/DESIGN.md §4.3.6). macOS keeps the state and
/// shows its own "login item added" notification; no permission prompt is involved.
final class SMAppServiceLoginItem: LoginItemControlling {
    private let service = SMAppService.mainApp

    var status: LoginItemStatus {
        switch service.status {
        case .notRegistered: return .disabled
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func setEnabled(_ on: Bool) throws {
        if on {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
