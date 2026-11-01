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

Motion, rumble and separate C/GL/GR controls are not implemented. They are not
present in this eight-byte input format; unknown output commands are not sent.
Saved preferences use the hardware serial if available, otherwise the USB port.
Moving a serial-less controller to another port gives it a separate identity.

## Build and verification

```sh
swift test --jobs 4
Tools/build-local.sh --probe
build/AfterglowBridgeProbe --input-only
build/AfterglowBridgeProbe
Tools/build-local.sh
```

The input-only probe decodes 300 real reports over three disconnect/rescan cycles
and checks that the controller identity is stable. The full probe uses the real
coordinator and Xbox output, and only reports success when
`GameController.framework` exposes an extended gamepad.

Local app: `build/WaveBird Afterglow.app`, bundle ID
`dev.alexanderbouman.wavebird.afterglow`. It is separate from upstream WaveBird.
macOS must authorize the development app to create virtual controllers; a build
or parser test passing does not establish game compatibility. A signed,
notarized public distribution also needs the developer's own Apple signing setup.

Validation so far: the app compiles, the 102-test suite passes, and the real USB
transport has decoded 300 reports across three disconnect/rescan cycles while
preserving its device identity. Virtual-controller output and interactive input
mapping remain to be validated on this Mac.
