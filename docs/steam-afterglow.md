# Four Afterglow controllers in Steam

Verified on 2026-11-01 with four Turtle Beach Afterglow Wave Wireless Controllers
for Switch 2 (`0E6F:0194`), macOS 27.2, Steam client 1792618285.

Steam's bundled SDL library supports the controller's Switch Pro protocol, but
does not select that driver for this hardware ID by default. Steam's own log
initially listed all four devices with `driver = NONE (DISABLED)`.

SDL provides a documented protocol override:

```text
SDL_GAMECONTROLLERTYPE=0x0e6f/0x0194=SwitchPro
```

The hint must be present when Steam starts. The native launcher sets just this
environment entry using `NSWorkspace.OpenConfiguration`. It does not patch Steam,
change global environment variables, create a virtual gamepad, or request input
monitoring. An Apple Developer membership/profile is not needed for this path.

## Use

1. Keep the controllers paired to macOS and wake them with Home. For the wireless
   setup, unplug controller USB cables from the Mac.
2. Quit Steam if it is running. Keep the WaveBird bridge and hardware probes closed
   so Steam owns the controller protocol initialization.
3. Open **Steam Afterglow Launcher.app** instead of launching Steam directly.
4. In Steam's controller settings, check the controllers and use **Test Device
   Inputs** before playing. Enable Steam Input for a game that needs translation.

Steam is already running with the override on the test Mac. Use the launcher again
after quitting Steam; launching Steam normally does not preserve the process's
environment override. The launcher asks you to quit first if Steam is already running.

Build the launcher:

```sh
Tools/build-steam-launcher.sh
```

## Verified and pending

- Steam's own SDL library enumerated zero gamepads without the override.
- With the override, the same library enumerated all four gamepads, opened each,
  and returned stick values through the standard SDL gamepad API.
- After starting the actual Steam client through the launcher, Steam's console
  log listed all four physical devices with
  `driver = SDL_JOYSTICK_HIDAPI_SWITCH (ENABLED)`.
- The actual Steam client opened controller indices **0, 1, 2, and 3** and loaded
  a separate controller identity/configuration for each.
- A four-player game session and interactive button/axis mapping inside Steam's
  device tester remain unverified. Recognition alone does not prove every game
  supports four players or correctly maps every control.
- The controller reconnect limitation described in
  [Bluetooth validation](afterglow-bluetooth.md) remains. This override selects a
  driver for an existing Bluetooth connection; it does not repair a failed radio link.

This solution targets Steam/SDL. Native macOS GameController still enumerated zero
controllers even in simple HID mode, with the bridge/probes stopped. The separate
WaveBird virtual-HID path for other applications still needs
[Apple-approved signing](macos-signing.md).

Primary reference: [SDL_GAMECONTROLLERTYPE](https://wiki.libsdl.org/SDL3/SDL_HINT_GAMECONTROLLERTYPE).
