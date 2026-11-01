# WaveBird

This fork adds **USB support for the Turtle Beach Afterglow Wave Wireless
Controller for Switch 2 (`0E6F:0194`)**. The upstream DMG does not contain this
backend. Build this fork with `Tools/build-local.sh`; the separate development
app is written to `build/WaveBird Afterglow.app`.

The input transport uses Apple's **CoreHID** library, then feeds the existing
WaveBird output profiles. No controller firmware changes or Nintendo USB
initialization commands are used. See [Afterglow USB support](docs/afterglow-usb.md)
for the supported controls and hardware-validation status.

A macOS app that bridges Nintendo Switch 2 controllers to a virtual HID gamepad,
so games and other apps can use them as standard controllers. Tested with Apple
Game Controller framework apps, SDL-based apps (Steam, Dolphin), and the web
Gamepad API.

Switch 2 controllers don't pair via the standard Bluetooth Security Manager
Protocol and don't expose HID over GATT — they speak Nintendo's proprietary
profile over a vendor BLE service. macOS therefore can't pair or use them
natively. WaveBird connects via CoreBluetooth, parses the proprietary report
format into a canonical state, and re-publishes each controller as a virtual
HID gamepad through CoreHID.

## Status

Early. Currently supports:

- **Nintendo Switch 2 GameCube Controller (NSO)** over Bluetooth LE —
  analog sticks, all face/shoulder buttons, D-pad, Rumble and Motion
- **Nintendo Switch 2 Pro Controller** over Bluetooth LE — analog sticks,
  all buttons including Home and Capture, Rumble and Motion
- **Nintendo Switch 2 Joy-Con (L / R)** over Bluetooth LE — used as a merged
  L + R pair that presents as a single gamepad, or each side on its own.
  Sticks, all buttons, Rumble and Motion. Attach the second side and WaveBird
  forms the pair automatically; split them back into solo controllers anytime.
- **Bluetooth pairing** — WaveBird remembers controllers across launches, so
  after the first pair you reconnect by pressing any button instead of holding
  SYNC. Remembered controllers stay visible (offline) in the list.
- **Afterglow Wave Wireless Controller for Switch 2 (`0E6F:0194`) over USB** —
  face/shoulder buttons, D-pad, stick clicks, Home/Capture and both sticks.
  Its USB report does not expose motion, rumble, or separate C/GL/GR inputs.

Not yet supported: Nintendo controllers over USB, Charging Grip, and Afterglow
wireless connections. Other licensed controller models need their own verified
VID/PID and input profile.

## Upstream releases (without this fork's USB support)

1. Download the latest `WaveBird-<version>.dmg` from the
   [Releases page](https://github.com/murphyjt/wavebird/releases/latest).
2. Open the DMG and drag **WaveBird.app** to **Applications**.

The app is signed and notarized by Apple, so it launches without a Gatekeeper
warning. You can also check for updates from within the app
(*WaveBird → Check for Updates…*).

### Verifying the download

Each release DMG carries a SLSA build-provenance attestation. To verify it was
built by this repo's release workflow before installing:

```sh
gh attestation verify --repo murphyjt/wavebird WaveBird-<version>.dmg
```

## Output profiles

Each connected controller can present as a different virtual gamepad. Open the
controller card and use the "Use profile" picker on the General tab to switch:

| Profile | Rumble | Motion | Notes |
|---|---|---|---|
| **Switch Pro Controller** | ✅ | ✅ | Recommended |
| **DualShock 4** | ✅ | ❌ | |
| **DualSense** | ✅ | ❌ | |
| **Xbox Wireless Controller** | ✅ | — | Recommended |

The selection persists per-controller (by serial) across reconnects, and can
be changed while the controller is offline.

The General tab also has a Sticks section for inverting the left and/or right
stick Y-axis. Per-controller rumble tuning (intensity, preset, per-band
frequency and amplitude) lives on the Haptics tab. All controller settings
persist per controller (by serial), so each physical controller carries its
own configuration across re-pairings.

These profiles appear in *System Settings → Game Controllers*, where they can
be remapped and customized.

## Requirements

- macOS 26.0 or newer
- Xcode 26 or newer (Swift 6.2)

## Build

With Swift Command Line Tools (no full Xcode required):

```sh
Tools/build-local.sh
swift test --jobs 4
```

This creates a separate, ad-hoc-signed development app with its own bundle ID.
It does not reuse the upstream signing identity or replace the installed app.
The first test build fetches Apple's Swift Testing package when it is not
bundled with the toolchain. The Xcode project remains the distribution build:

```sh
xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug build
```

Or open `WaveBird.xcodeproj` in Xcode and run.

## Permissions

WaveBird needs two privacy permissions the first time it runs. macOS may prompt
for them automatically, or you can grant them manually:

**System Settings → Privacy & Security → Accessibility** — required to publish
a virtual HID gamepad.

**System Settings → Privacy & Security → Bluetooth** — required to scan for and
connect to controllers.

If a permission prompt appears, click **Allow**. If WaveBird is listed but
unchecked, check it and relaunch.

> **Note:** If you granted permissions for a previous version and the virtual
> gamepad stopped appearing after updating, open **Privacy & Security →
> Accessibility**, remove WaveBird, and re-add it — macOS sometimes doesn't
> re-validate an existing entry after a binary update.

## Use

For the Afterglow model above, launch this fork, connect a USB data cable,
and choose an output profile when prompted. SYNC and Bluetooth pairing are
not needed for USB. Xbox Wireless Controller or Switch Pro Controller are the
recommended output profiles. Controllers without hardware serial numbers keep
their saved settings when reconnected to the same physical USB port.

For Nintendo's Bluetooth controllers:

1. Launch the app — it begins scanning automatically.
2. Hold the SYNC button on your controller until the LEDs flash. (If you've
   paired it before, just press any button.)
3. WaveBird discovers and connects; the controller appears in the device list
   once it's ready.
4. On the first connect of a new controller, WaveBird asks whether to pair it.
   Accepting writes a long-term key to both sides so future reconnects don't
   need SYNC. **Pairing overwrites the controller's Nintendo Switch 2 console
   pairing** — to use it on the console again you'll need to hold SYNC there.
5. Click the controller card to open its settings — pick a virtual gamepad
   profile, invert stick axes (General), or tune rumble (Haptics). Use the
   "Forget This Device…" button to drop WaveBird's record of a pairing; the
   controller keeps its stored key until you pair it with something else.

The virtual gamepad is visible to apps that use the Game Controller framework
or the WebHID / Gamepad APIs (Chrome / Safari gamepad testers like
[lizardbyte gamepad-tester](https://app.lizardbyte.dev/gamepad-tester/)).

## Credits

- [SDL_GameControllerDB](https://github.com/mdqinc/SDL_GameControllerDB) — PDP
  Afterglow Deluxe button mapping used as the initial Afterglow USB layout.
- [BlueRetro](https://github.com/darthcloud/BlueRetro) by darthcloud — protocol
  reference for Switch 2 controllers (Apache 2.0).
- [switch2_controller_research](https://github.com/ndeadly/switch2_controller_research)
  by ndeadly — detailed write-ups of the Switch 2 BLE / HID protocol.
- [SDL](https://github.com/libsdl-org/SDL) — `SDL_hidapi_switch2.c` for the
  factory trigger-calibration flash layout and the NS2 LRA `EncodeHDRumble`
  bit packing; `SDL_hidapi_switch.c` for the Switch 1 Pro Controller
  subcommand handshake the Switch Pro presentation emulates, and the NS1 HD
  Rumble amplitude table we invert to decode the presentation's incoming
  rumble (zlib).
- [dekuNukem/Nintendo_Switch_Reverse_Engineering](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering)
  — write-up of the Switch 1 Bluetooth HID protocol (subcommand IDs, report
  0x30 button/stick layout) used by the Switch Pro presentation, and the
  `rumble_data_table.md` amplitude curve we use to decode NS1 HD Rumble
  bytes back into 16-bit amplitudes before re-encoding for NS2 LRA.

## License

MIT — see [LICENSE](LICENSE).
