import OpenRayCore
import SwiftUI

/// Asks before an action that cannot be taken back, inside the launcher.
///
/// Not an `NSAlert`: an alert would come up behind the panel, and when it took the keyboard
/// the panel would stop being the key window and hide (docs/DESIGN.md §4.1.6).
struct ConfirmationView: View {
    let confirmation: Confirmation
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Dims what is behind the question and takes the clicks meant for it.
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text(confirmation.title)
                        .font(.system(size: 15, weight: .semibold))
                    if let message = confirmation.message {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    Button(action: onCancel) {
                        HStack(spacing: 6) {
                            Text("Cancel")
                            KeyCap(symbol: "esc")
                        }
                    }
                    Button(role: .destructive, action: onConfirm) {
                        HStack(spacing: 6) {
                            Text(confirmation.confirmTitle)
                            KeyCap(symbol: "↩")
                        }
                    }
                }
                .controlSize(.large)
            }
            .padding(22)
            .frame(width: 360)
            .background(
                .regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.gray.opacity(0.3))
            }
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}
