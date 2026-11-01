# Signing the Afterglow fork for virtual gamepad output

Bluetooth/USB input capture can run without a virtual-HID entitlement. Publishing
standard virtual gamepads through CoreHID requires Apple's approval even on the
developer's own Mac. Paying for Developer Program membership alone does not grant
that approval. The upstream app's profile and certificate cannot sign this fork.

## Account setup

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/enroll/).
   The account owner completes identity verification, agreements, and payment.
2. Register an explicit macOS App ID for `dev.alexanderbouman.wavebird.afterglow`.
   Keep this identifier consistent with `Tools/build-local.sh`.
3. Request `com.apple.developer.hid.virtual.device`. Apple's general process is
   Certificates, Identifiers & Profiles → Identifiers → the App ID → Capability
   Requests. If Virtual HID is not offered there, ask Apple Developer Support
   where to submit this exact entitlement request; do not select unrelated
   DriverKit, keyboard, or system-extension entitlements as substitutes.
4. Ask for approval covering Mac development first and Developer ID distribution
   if builds will run on other Macs. Apple decides eligibility and timing.

## Request text to adapt after enrolling

> I am developing a macOS game-controller compatibility utility based on the
> MIT-licensed WaveBird project. The fork adds input support for licensed Turtle
> Beach Afterglow controllers for Nintendo Switch 2. The goal is to support up to
> four physical wireless controllers, each exposed as a separate standard virtual
> gamepad to existing games, without modifying the games.
>
> App ID: dev.alexanderbouman.wavebird.afterglow
>
> Repository: https://github.com/alexanderboumanagent/wavebird/tree/feat/afterglow-usb
>
> The app uses CoreBluetooth for Nintendo BLE controllers, IOBluetooth for standard Bluetooth Classic
> pairing, and CoreHID HIDDeviceClient for supported physical HID devices. It creates virtual gamepad
> devices through CoreHID HIDVirtualDevice. The requested entitlement is
> com.apple.developer.hid.virtual.device. It does not require a kernel extension
> or disabling macOS security protections. Bluetooth pairing, initialization and changing input from the Turtle Beach
> model have been verified on hardware, as has USB input capture. Four-controller
> and game-output validation are tracked in the repository.
>
> Please advise how to obtain this entitlement for Mac development and, if
> supported, Developer ID distribution. The app will explain and request the
> applicable macOS user permissions. Physical-controller input is processed locally.

Check that the implementation and validation statements still match the branch
before submitting. This draft has not been sent to Apple.

## After Apple approves

1. Enable the approved capability on the App ID.
2. Create an Apple Development certificate on this Mac, keeping the private key in
   its Keychain, and register this Mac as a development device.
3. Generate a **Mac App Development** provisioning profile for this App ID,
   certificate and Mac. Download it outside the repository.
4. Verify that it includes `com.apple.developer.hid.virtual.device = true`.
5. Build with the matching Keychain signing identity and downloaded profile:

   ```sh
   Tools/build-local.sh \
     --identity 'Apple Development: YOUR NAME (CERTIFICATE ID)' \
     --profile '/absolute/path/Afterglow_Development.provisionprofile'
   ```

The build script verifies the capability and bundle-ID grant, embeds the profile,
and signs the app. It deliberately does not attach a restricted entitlement to an
ad-hoc signature. A development profile only authorizes its registered Macs; use
an appropriately approved Developer ID signing/profile workflow for distribution.
No certificate, private key, or provisioning profile belongs in Git.

## Completion checks

A signed build is necessary but does not prove the Bluetooth implementation works.
Verify all of these on real hardware:

- One controller: pair, receive changing inputs, verify every control and both
  sticks, and verify an ordinary macOS game sees the virtual gamepad.
- Four controllers: four distinct identities and virtual devices; simultaneous
  input must stay with its originating player. Restart and reconnect them in a
  different order, disconnect one while the other three remain active, and test
  sleep/wake and controller power-off.
- Test native GameController, SDL and Steam consumers with appropriate output
  profiles. A bridge cannot add controller or four-player support to a game that
  does not provide it.

## Apple references

- [Virtual HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device)
- [Request a managed capability](https://developer.apple.com/help/account/capabilities/capability-requests)
- [Create a development profile](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile)
- [Provisioning profiles and restricted entitlements](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
