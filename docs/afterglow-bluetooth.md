# Afterglow Bluetooth Classic input

Target hardware: **Turtle Beach Afterglow Wave Wireless Controller for Switch 2**,
USB/SDP VID `0E6F`, PID `0194`, USB firmware `0102`. Bluetooth discovery calls it
**Lic3 Pro Controller**. Discovery, standard pairing, and changing input were
captured on a real Mac/controller on 2026-11-01.

This is Bluetooth Classic HID, not Nintendo's proprietary Switch 2 BLE service.
`BluetoothClassicPairer` uses public IOBluetooth pairing APIs. Once paired,
`BluetoothHIDTransport` reads the physical gamepad through CoreHID and sends
normalized states through the existing WaveBird output pipeline. No NS2 BLE
initialization or LTK exchange is sent to this controller.

## Input reports

CoreHID supplies the report ID both separately and in byte zero of the data.

| Mode | Total bytes | Layout |
| --- | --- | --- |
| `3F`, initial simple mode | 12 | ID, two button bytes, hat/padding, LX/LY/RX/RY as unsigned LE16 |
| `30`, full mode | 49 | ID, timer, battery, three button bytes, two packed 12-bit stick pairs, vibration status, sensor area |
| `21`, subcommand reply | 49 | Common state, ACK at byte 13, echoed subcommand at byte 14, reply data |

Captured resting simple packet:

```text
3F 00 00 08 E0 83 3F 7C C0 80 4F 7C
```

Captured resting full packet (remaining 36 bytes zero):

```text
30 08 80 00 00 00 3F 28 83 09 78 83 00
```

The interactive simple-report capture confirmed A=`02`, B=`01`, X=`08`, Y=`04`
in the first button byte, all eight hat positions, L/R/ZL/ZR, and changing axes
on both sticks. Full-report mappings follow SDL's Switch Pro driver. System
buttons and C have byte-vector coverage but require separate interactive checks.
Separate rear-paddle events, rumble, and motion are not implemented. Sensor bytes
were zero in the capture; no IMU-enable command is sent.

Simple-report Y is down-positive; full-report packed Y is up-positive. Both
normalize to WaveBird's up-positive `-2047...2047` stick range. A 5% axis deadzone
removes the roughly 3% resting offset observed on the test unit and preserves
numeric end stops. A diagnostic SPI factory-calibration read at `603D` returned
all `FF`; no factory calibration is assumed or fabricated. Physical stick
end-stop calibration has not been verified.

## Initialization and player lights

The controller remains in the scanning-light animation after standard pairing
until it receives its player-light command. The backend sends standard Switch
Pro HID report `01`, padded to 49 bytes, with neutral rumble bytes:

1. Subcommand `30`, mask `01`, `02`, `04`, or `08` for player 1–4.
2. Subcommand `03`, value `30`, to select full reports.

Both commands were acknowledged by the hardware. The user visually confirmed
that player 1 became solid, and a report `30` immediately followed the report-mode
command. This does not require virtual-HID signing.

## Multiple controllers

The transport has a separate CoreHID client and report task per physical device.
Initialization waits for each matching subcommand ACK before sending the next
command. Initialization waits 250 ms before sending subcommands, following
SDL's macOS handshake workaround in `HIDAPI_DriverSwitch_OpenJoystick`.
Paired controllers are reconnected with the public asynchronous
IOBluetooth openConnection API; a round-robin poll finds a pad after Home wakes it.
This reconnect path is not reliable across all four test units; see below.
The HID serial is the controller's Bluetooth address. A vendor/product/address
identity is used for settings and virtual-output serials; identical product names
cannot collapse four controllers onto one identity. Player-light slots are
allocated from the four currently available slots. Pairing proceeds one device
at a time while connected devices keep streaming. During this Mac's initial
setup, fourth-device discovery stalled with three active links. Temporarily
closing one link allowed the fourth to pair; reconnecting the saved pad then
produced four working simultaneous input streams. If initial pairing stalls,
pair controllers before keeping all four awake.

WaveBird's Disconnect action closes the native radio connection while keeping
the Bluetooth pairing. The hardware probe can separately end an input
subscription without closing that link. macOS Bluetooth Settings owns the bond;
no pairing key is exported to the repository.

Already-paired CoreHID input monitoring starts independently of legacy inquiry
initialization. On macOS 27.2, initializing IOBluetooth's inquiry coordinator on
the GUI thread caused a sampled semaphore deadlock. The fork warms that runtime
off the main thread so Bluetooth authorization cannot freeze the window.

An unsigned diagnostic build keeps physical input subscriptions open and shows
the Apple signing requirement. It does not automatically offer an output-profile
picker that cannot succeed or disconnect the pads for lacking virtual-HID authorization.

For four-controller wireless use, unplug controller USB cables from the Mac.
USB and Bluetooth expose separate HID devices, and the USB interface has no
serial or Bluetooth address to associate it with a wireless pad. This fork does
not deduplicate the same physical controller across those two interfaces. A
controller plugged into the Mac while connected wirelessly therefore appears
twice; a wall charger avoids that extra USB input device.

## Validation status

- App build and **114 tests in 22 suites** passed.
- One physical unit paired over Bluetooth Classic and exposed its HID descriptor.
- User-generated button/hat/stick changes were captured over Bluetooth.
- The ACK-paced production transport/parser decoded **300 wireless reports
  across three input subscriptions** (283 full-mode, 17 initial simple-mode),
  preserving the same identity. This tests subscription
  lifecycle, not a controller power cycle or removal of the Bluetooth bond.
- **Four actual controllers simultaneously delivered at least 100 decoded full-mode
  reports each**, with four distinct Bluetooth identities and fresh input from
  every device.
- A Bluetooth link was deliberately closed without removing its pairing. After
  the user pressed Home, the new reconnect loop restored the same controller
  identity. The other three streams remained present, and the four-controller
  full-mode check passed again. All four solid player lights were user-confirmed.
- Subsequent reconnect tests on another unit failed with `kIOReturnTimeout`
  (`E00002D6`) while three other links stayed connected. The default synchronous
  API, native Bluetooth Settings Connect, altered inquiry scheduling, and
  disabling Nintendo BLE scanning did not establish a reliable fix. Those
  speculative application changes were reverted. One earlier successful Home
  test does **not** establish reliable four-controller reconnect.
- That unit was subsequently paired again successfully after removing only its
  saved bond and temporarily closing another link without removing that link's
  pairing. The repair used standard IOBluetooth pairing and returned success;
  the underlying reconnect problem remains unresolved.
- After that pairing repair, the temporarily released controller reconnected
  after Home. The production transport, including the macOS initialization
  delay, again passed the four-controller check with at least 100 decoded full
  reports per physical unit. No further radio-disconnect tests were performed.
- The installed `WaveBird Afterglow.app` displayed all four wireless controllers
  connected after the user tapped Home. Bluetooth discovery was verified running
  after refreshing the rebuilt diagnostic app's existing Bluetooth grant.
- Physical power-off, sleep/wake, and per-player output isolation inside a game:
  **pending hardware/game tests**.
- GameController still reported **zero native controllers** after all four were
  paired and initialized in full mode (8-second foreground-independent check). The fork's virtual
  gamepad output remains blocked by missing Apple-approved signing. No successful
  cross-game or four-player game session is claimed.
- A separate [corrected Steam driver](steam-afterglow.md) now keeps four physical
  controllers connected and exposes four virtual gamepads through Steam. The initial
  game-launch disconnect was traced to an unsupported Home-light command; the SDL
  patch suppresses it for this exact model. Steam also needed the user's approved
  Input Monitoring and Device Control grants to create its output devices. All four
  pads independently joined and selected characters in Lovers in a Dangerous Spacetime;
  level movement validation is pending. This route does not require signing this
  fork's virtual-HID output. Earlier Bluetooth encryption-downgrade rejections required
  repairing two saved pairings; future power/sleep reconnect reliability is unverified.

Hardware checks, using the production transport/parser:

```sh
Tools/build-local.sh --probe
build/AfterglowBridgeProbe --bluetooth --input-only
build/AfterglowBridgeProbe --four-inputs
build/AfterglowBridgeProbe --four-inputs --monitor
```

The four-input check requires four actual controllers, verifies distinct identities
and simultaneous decoded reports, and logs meaningful changes per controller. It
does not create a virtual gamepad or substitute for game-output validation.

For game output, complete [Apple signing setup](macos-signing.md), then run the
signed app and `swift Tools/GameControllerProbe.swift`. Verify native
GameController, SDL and Steam games, including a game that supports four local
players. Game-specific controller and player-count limits still apply.

Protocol reference: SDL's
[`HandleSimpleControllerState`, `HandleFullControllerState`, `ConstructSubcommand`, and `WritePacket`](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_switch.c).
