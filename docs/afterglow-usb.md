# Afterglow Wave USB input

Supported device: **Turtle Beach Afterglow Wave Wireless Controller for Switch 2**,
USB vendor `0x0E6F`, product `0x0194` (observed firmware version `0x0102`).
This is a USB backend for that model, not Bluetooth support for every licensed
Nintendo controller.

## Implementation

`USBTransport` uses `CoreHID.HIDDeviceManager` for discovery and
`HIDDeviceClient.monitorNotifications` for reports and device removal. Those
native actors manage USB communication and memory. No C callback buffers,
external drivers, firmware writes, or reverse-engineered initialization sequence
are needed for this device.

`AfterglowUSBReport` converts the input to WaveBird's `ControllerState`.
The existing output catalog then publishes a Switch Pro, Xbox, or PlayStation
virtual gamepad. Other controller models can add an explicit `USBMatcher` and
profile without replacing the transport.

## Captured USB format

The HID descriptor and the following neutral report were read on macOS 27.2
using `Tools/AfterglowUSBProbe.swift` on 2026-11-01:

```text
00 00 0F 80 80 80 80 00
```

| Bytes | HID descriptor fields |
| --- | --- |
| 0–1 | Fourteen buttons, followed by two padding bits |
| 2, low nibble | Eight-way D-pad hat; 8–15 are neutral |
| 2, high nibble | Padding |
| 3–4 | Left stick X/Y, unsigned 8-bit, center 128 |
| 5–6 | Right stick Z/Rz, unsigned 8-bit, center 128 |
| 7 | Reserved |

There is no report-ID prefix. The face-button labels initially follow
SDL_GameControllerDB's PDP Afterglow Deluxe mapping: Y, B, A, X in bits 0–3.
They still need an interactive button-by-button check on this new model.
The parser preserves WaveBird's symmetric 12-bit stick range and up-positive Y.

Motion and separate C/GL/GR controls are not present in this eight-byte input
format. USB rumble is not implemented because its output protocol is unverified;
unknown output commands are not sent.
Saved preferences use the hardware serial if available, otherwise the USB port.
Moving a serial-less controller to another port gives it a separate identity.

## Build and verification

```sh
swift test --jobs 4
Tools/build-local.sh --probe
build/AfterglowBridgeProbe --input-only
Tools/build-local.sh
```

The input-only probe decodes 300 real reports over three disconnect/rescan cycles
and checks that the controller identity is stable. The full probe (without
`--input-only`) reaches the real coordinator and Xbox output, but is blocked by
the same signing requirement as an unsigned app. Use
`swift Tools/GameControllerProbe.swift` with an authorized app build running to
check that `GameController.framework` exposes an extended gamepad.

Local app: `build/WaveBird Afterglow.app`, bundle ID
`dev.alexanderbouman.wavebird.afterglow`. It is separate from upstream WaveBird.
The default local build is an input diagnostic, not a working gamepad emulator.
macOS requires an Apple-approved `com.apple.developer.hid.virtual.device`
entitlement, a matching provisioning profile, and a real signing identity.
Accessibility permission alone does not grant this capability. Do not add the
restricted entitlement to an ad-hoc signature: macOS rejects the app at launch.
The build can use your own approved profile with `--identity` and `--profile`;
both are required together, and the profile's entitlement and app ID are checked.

The upstream developer's certificate/profile cannot be reused to sign a fork.
A maintainer-signed upstream release or the fork developer's own approved
signing setup is needed. A build or parser test passing does not establish game
compatibility.

Validation so far: the app compiles, the 102-test suite passes, and the real USB
transport has decoded 300 reports across three disconnect/rescan cycles while
preserving its device identity. The app detected the hardware and reached output
selection. Virtual-controller creation was refused without the entitlement;
adding it to an ad-hoc signature was rejected by macOS with
`AppleMobileFileIntegrityError -424` (restricted entitlements). No signing identity
is installed on the test Mac. Game compatibility and interactive face-button
mapping remain unverified until an authorized signed build is available.
