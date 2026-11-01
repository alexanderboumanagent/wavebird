import SwiftUI

// Wraps the original "no controller connected" empty-state copy as a sheet
// that can be opened from the header any time. Auto-dismissed by ContentView
// when a new device transitions to .ready while this sheet is open.
struct SetupSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Set up Game Controller")
                    .font(.headline)
                Text("Hold SYNC on a Nintendo Switch 2 controller to connect. For a Turtle Beach Afterglow Wave, unplug USB and hold SYNC beside USB-C for 3 seconds. Up to four Afterglow controllers can connect wirelessly. You can also connect a supported controller over USB.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 12)
            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 384)
    }
}
