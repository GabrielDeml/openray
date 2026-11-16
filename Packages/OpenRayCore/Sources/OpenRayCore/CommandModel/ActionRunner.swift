import os

/// Takes one action from its confirmation to its outcome (docs/DESIGN.md §4.1.4). The launcher
/// starts this in a task for every action it performs; the steps are here, and not in the app
/// target, so that their order can be tested without a window.
@MainActor public enum ActionRunner {
    public enum Ending {
        /// What the launcher does next. `.keepOpen` also when the action did not run: the user
        /// declined, a permission was refused, or Esc cancelled the task.
        case outcome(ActionOutcome)
        /// The action threw. The launcher stays as it is and shows the error.
        case failure(any Error)
    }

    /// - Parameter recordPick: Counts the pick for ranking. Called once the action is certain to
    ///   run, so that a command the user backed out of does not rise in the results.
    public static func run(
        _ action: ActionDescriptor, context: any ActionContext,
        permissions: any PermissionChecking, recordPick: () -> Void
    ) async -> Ending {
        if let confirmation = action.confirmation {
            let isConfirmed = await context.confirm(confirmation)
            if !isConfirmed { return .outcome(.keepOpen) }
        }

        if let outcome = await outcomeOfMissingPermission(
            for: action, context: context, permissions: permissions)
        {
            return .outcome(outcome)
        }
        // Esc while the last permission was being read.
        if Task.isCancelled { return .outcome(.keepOpen) }

        recordPick()

        do {
            return .outcome(try await action.perform(context))
        } catch {
            // An action that stops because Esc cancelled it has not failed.
            let wasCancelled = error is CancellationError || Task.isCancelled
            if wasCancelled { return .outcome(.keepOpen) }
            return .failure(error)
        }
    }

    /// Checks the permissions the action requires, in a fixed order (§5.1).
    ///
    /// - Returns: nil when they are all there and the action can run; otherwise what the
    ///   launcher does in place of running it.
    private static func outcomeOfMissingPermission(
        for action: ActionDescriptor, context: any ActionContext,
        permissions: any PermissionChecking
    ) async -> ActionOutcome? {
        for permission in Permission.sorted(action.requiredPermissions) {
            let state = await permissions.state(permission)
            // Esc while the state was being read. Checked before anything is shown: a prompt
            // must not come up for an action the user has just called off.
            if Task.isCancelled { return .keepOpen }

            switch PermissionGate.step(for: permission, state: state) {
            case .proceed:
                continue
            case .explain:
                return .push(PermissionScreen.request(for: permission))
            case .request:
                // The prompt is a system window and would come up behind the panel.
                context.closeLauncher()
                let answer = await permissions.request(permission)
                if answer != .granted {
                    let name = action.id.rawValue
                    Log.permissions.info(
                        "Did not run \(name, privacy: .public): the permission was not granted")
                    // A user who has just said no at the prompt knows why nothing happens.
                    // Any other answer means that macOS could not be asked, and the launcher
                    // is closed by now, so without a word the command would seem to do nothing.
                    if answer != .denied {
                        let message = String(
                            localized:
                                "OpenRay could not get the permission “\(permission.title)”.",
                            bundle: .module,
                            comment:
                                "Shown when macOS could not be asked for a permission a command needs. The placeholder is the permission's name."
                        )
                        context.showHUD(message)
                    }
                    return .keepOpen
                }
            }
        }
        return nil
    }
}
