import OpenRayCore
import SwiftUI

/// The shared permission screen (docs/DESIGN.md §5.1). The launcher pushes it in place of an
/// action whose permission is missing. It has no commands of its own.
final class PermissionsFeature: Feature {
    let id = PermissionScreen.feature

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        []
    }

    func makeScreen(
        _ request: ScreenRequest, context: any ScreenContext, env: FeatureEnvironment
    ) -> ScreenSpec? {
        guard request.screen == PermissionScreen.name else { return nil }
        guard let argument = request.argument,
            let permission = Permission(screenArgument: argument)
        else { return nil }

        // Which commands the permission is for is read off the commands themselves.
        let uses = PermissionUse.uses(in: env.currentItems())
        let commandTitles = uses.first { $0.permission == permission }?.commandTitles ?? []

        let model = PermissionScreenModel(
            permission: permission, commandTitles: commandTitles, checker: env.permissions,
            context: context)
        model.followState()
        return .custom(
            title: permission.title, searchBar: .hidden, view: PermissionScreenView(model: model))
    }
}

/// Says what a permission is for and what its state is. Return runs the screen's one action,
/// which the footer names.
private struct PermissionScreenView: View {
    let model: PermissionScreenModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.permission.title)
                .font(.system(size: 17, weight: .semibold))
            Text(model.explanation)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label {
                Text(model.state.label)
            } icon: {
                Image(systemName: model.state == .granted ? "checkmark.circle.fill" : "circle")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(model.state == .granted ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
