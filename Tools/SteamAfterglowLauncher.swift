import AppKit
import Darwin

enum SteamSDLPreflightError: LocalizedError {
    case missingLibrary
    case unreadableLibrary(String)
    case missingRevision
    case unsupportedRevision(String)

    var errorDescription: String? {
        switch self {
        case .missingLibrary:
            return "Could not find Steam's SDL library. Update or reinstall Steam before using this launcher."
        case .unreadableLibrary(let detail):
            return "Could not verify Steam's SDL library: \(detail)"
        case .missingRevision:
            return "Steam's SDL library did not provide a revision. Update the Afterglow driver before using this Steam version."
        case .unsupportedRevision(let revision):
            return "This Steam version uses SDL revision \(revision). The Afterglow driver supports gab5541ec5. Update the Afterglow driver for this Steam version before using this launcher."
        }
    }
}

enum SteamSDLPreflight {
    static func verify(steam: URL) throws -> String {
        var candidates = [steam.appendingPathComponent("Contents/MacOS/libSDL3.dylib")]
        if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(applicationSupport.appendingPathComponent("Steam/Steam.AppBundle/Steam/Contents/MacOS/libSDL3.dylib"))
        }
        guard let originalLibrary = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SteamSDLPreflightError.missingLibrary
        }

        // Inspect the original API, never an inherited SDL replacement. Reading
        // the revision initializes only SDL's dispatch table, not joystick input.
        let previousOverride = getenv("SDL3_DYNAMIC_API").map { String(cString: $0) }
        unsetenv("SDL3_DYNAMIC_API")
        defer {
            if let previousOverride { setenv("SDL3_DYNAMIC_API", previousOverride, 1) }
            else { unsetenv("SDL3_DYNAMIC_API") }
        }
        guard let handle = dlopen(originalLibrary.path, RTLD_NOW | RTLD_LOCAL) else {
            throw SteamSDLPreflightError.unreadableLibrary(dlerror().map { String(cString: $0) } ?? "Unknown library-loading error")
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SDL_GetRevision") else {
            throw SteamSDLPreflightError.missingRevision
        }
        typealias GetRevision = @convention(c) () -> UnsafePointer<CChar>?
        let getRevision = unsafeBitCast(symbol, to: GetRevision.self)
        guard let value = getRevision() else { throw SteamSDLPreflightError.missingRevision }
        let revision = String(cString: value)
        guard revision.contains("gab5541ec5") else {
            throw SteamSDLPreflightError.unsupportedRevision(revision)
        }
        return revision
    }
}

// SDL's documented protocol and replacement-library hooks select the corrected
// Switch driver for 0E6F:0194. Steam supplies the virtual-gamepad output.
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
        guard let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("libSDL3.0.dylib"),
              FileManager.default.fileExists(atPath: library.path) else {
            fail("The Afterglow SDL driver is missing. Build it with Tools/build-steam-sdl.sh, then rebuild this launcher.")
            return
        }
        do {
            _ = try SteamSDLPreflight.verify(steam: steam)
        } catch {
            fail(error.localizedDescription)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = [
            "SDL_GAMECONTROLLERTYPE": "0x0e6f/0x0194=SwitchPro",
            // SDL's supported replacement-library entry point keeps the
            // compatibility fix outside Steam's signed application bundle.
            "SDL3_DYNAMIC_API": library.path,
        ]
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
        if CommandLine.arguments.contains("--check-steam-sdl") {
            guard let steam = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") else {
                fputs("Steam is not installed.\n", stderr)
                exit(1)
            }
            do {
                print(try SteamSDLPreflight.verify(steam: steam))
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = SteamAfterglowLauncher()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
