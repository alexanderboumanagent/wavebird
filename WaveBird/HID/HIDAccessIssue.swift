import Foundation
import IOKit.hid
import Security

// Why virtual-controller output is blocked. Only ever produced from an
// observed HIDVirtualDevice init failure — the TCC post-event check alone is
// not predictive (verified on hardware 2026-07-05: it reports not-granted on
// a machine where the Accessibility box is ticked and the VHID works), so it
// is consulted only to pick the more specific message after a failure.
enum HIDAccessIssue: Equatable {
    case signingRequired
    case permissionDenied
    case vhidCreationFailed

    // Called at the moment a VHID creation fails.
    static func current() -> HIDAccessIssue {
        guard hasVirtualHIDEntitlement else { return .signingRequired }
        return IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == kIOHIDAccessTypeGranted
            ? .vhidCreationFailed
            : .permissionDenied
    }

    static var hasVirtualHIDEntitlement: Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.developer.hid.virtual.device"] as? Bool == true
    }

    var canFixInSystemSettings: Bool { self != .signingRequired }

    // Menu-bar item label. Must not assert a permission problem for
    // .vhidCreationFailed — that's the case where the TCC check said the
    // permission WAS granted; the full message hedges, the label should too.
    var menuTitle: String {
        switch self {
        case .signingRequired: "Virtual Controller Signing Required"
        case .permissionDenied: "Accessibility Permission Needed…"
        case .vhidCreationFailed: "Virtual Controller Blocked…"
        }
    }

    var message: String {
        switch self {
        case .signingRequired:
            "This build lacks Apple's virtual HID signing authorization. An authorized signed build is required to expose a controller to games."
        // "Reconnect" not "press a button": only LTK-paired controllers wake
        // on a button press; a first-time controller needs SYNC again, and
        // the empty-state copy already teaches that.
        case .permissionDenied:
            "WaveBird needs the Accessibility permission to create virtual game controllers. Enable WaveBird in System Settings, then reconnect the controller."
        case .vhidCreationFailed:
            "Couldn't create the virtual game controller. Check that WaveBird is enabled under Privacy & Security → Accessibility, then reconnect the controller."
        }
    }
}
