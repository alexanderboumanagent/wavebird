import AppKit

// SDL's documented VID/PID protocol override lets Steam's existing Switch Pro
// driver handle 0E6F:0194. No virtual device, input injection, or signing grant.
// https://wiki.libsdl.org/SDL3/SDL_HINT_GAMECONTROLLERTYPE
@MainActor
final class SteamAfterglowLauncher: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam").isEmpty else {
            fail("Quit Steam first, then open this launcher again. The controller override must be present when Steam starts.")
            return
        }
        guard let steam = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") else {
            fail("Install Steam, then open this launcher again.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = ["SDL_GAMECONTROLLERTYPE": "0x0e6f/0x0194=SwitchPro"]
        NSWorkspace.shared.openApplication(at: steam, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error { self.fail(error.localizedDescription) }
                else { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Steam Afterglow Launcher"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}

@main
struct LauncherMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = SteamAfterglowLauncher()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
