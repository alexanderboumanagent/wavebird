# Four Afterglow controllers in Steam

Tested on 2026-11-01 with four Turtle Beach Afterglow Wave Wireless Controllers
for Switch 2 (`0E6F:0194`), macOS 27.2, Steam client 1792618285.

**The four-player wireless gameplay test passed.** All four controllers joined
Lovers in a Dangerous Spacetime and independently moved and jumped in its tutorial
level, confirmed by the user after four characters were observed in the running level.
The installed Steam Afterglow Launcher includes the corrected SDL driver and a
compatibility check. No separate Apple Developer membership/profile is needed
for this Steam route.

## Use

1. Keep the controllers paired to macOS, unplug controller USB cables, and wake
   all four with Home before starting the game.
2. In System Settings → Privacy & Security, enable **Steam.app** under both
   **Input Monitoring** and **Device Control and Data Access** (Accessibility on
   older macOS versions). These are broad privacy grants requiring user approval;
   they were explicitly approved on the test Mac. Add Steam, not this launcher.
3. Quit Steam. Keep the WaveBird bridge and hardware probes closed so Steam owns
   the controller protocol. Open **Steam Afterglow Launcher.app**.
4. Enable Steam Input for Switch Pro controllers in Steam's advanced controller
   settings. For a game needing translation, set its controller override to
   **Enable Steam Input**. Both settings are enabled for the tested game.
5. Start the game after all four pads are available. Click back into the game
   before pressing A on each pad to join. Home can change Steam's UI focus;
   it is unnecessary for joining an already-connected controller.

Launching Steam normally does not preserve the launcher's process environment.
The launcher asks you to quit Steam first if it is already running. Player-light
behavior is not a reliable connection test on this hardware; check Steam's devices
and the actual game inputs.

## Why the driver and permissions are needed

Stock Steam listed this hardware ID with `driver = NONE (DISABLED)`. SDL's documented
`SDL_GAMECONTROLLERTYPE=0x0e6f/0x0194=SwitchPro` override enabled recognition, but
recognition alone exposed an unsupported Home-light command at game activation.
A logging-only recorder captured subcommand `38 01 F0 F0 00`, its five retries,
then loss of input and a Bluetooth disconnect. Its caller was Steam's SDL library.
Disabling rumble or requesting simple input reports did not resolve that failure.

Upstream SDL already avoids Home-light commands for older licensed controllers,
with a source comment explaining that they can shut those controllers off. This
unit reports the newer `Lic3` device type `0F`, which that check misses. The source
patch registers `0E6F:0194`, rejects unsupported Home-light commands, and advertises
its Home-light capability accurately. Other controller commands retain upstream
behavior. Rumble, motion, C, and back-button behavior are not validated by this test.

Steam also failed to create its output gamepads: macOS logged
`IOServiceOpen:0xe00002e2` (`kIOReturnNotPermitted`) and a system-policy denial opening
`IOHIDResourceDeviceUserClient`. That error existed with stock SDL, before the
replacement library was introduced. Input Monitoring alone did not clear it.
After the user enabled Steam's Device Control grant and Steam restarted, the same
API logged successful `Start` events, and virtual Xbox-compatible `GamePad-1`
through `GamePad-4` appeared (`045E:028E`).

The game already includes an InControl Steam profile matching `Microsoft GamePad-1`
through `-8`. Its assemblies were inspected but not modified. A generic controller-
name patch was not needed. Its input manager detaches and reattaches devices when
joystick names change, so starting it with all four present avoids hotplug assignment
changes during this test.

## Build and compatibility

The replacement uses the exact upstream SDL revision used by the tested Steam
client (`ab5541ec5`, SDL 3.5.0). CMake and Apple's command-line tools are required:

```sh
Tools/build-steam-sdl.sh
Tools/build-steam-launcher.sh
```

The build verifies a pinned SHA-256 archive before applying
`Tools/patches/sdl-afterglow-home-light.patch`. Cached source is checked for that
patch before building. Private Objective-C classes in the replacement are namespaced
so both SDL images can coexist. SDL's license is included in the launcher resources.

The native launcher sets only the protocol override and SDL's supported
`SDL3_DYNAMIC_API` replacement-library path through `NSWorkspace.OpenConfiguration`.
It does not modify Steam's files or global environment variables. Steam creates and
feeds the virtual gamepads using its existing approved entitlement and the user's
privacy grants.

SDL can silently fall back to its bundled driver if a future client's API table is
incompatible. The launcher therefore checks the original Steam SDL revision before
launching and refuses unsupported or unverifiable revisions. Its preflight reads
only the revision, without initializing joystick input. To inspect the installed
Steam library without launching Steam:

```sh
"build/Steam Afterglow Launcher.app/Contents/MacOS/SteamAfterglowLauncher" --check-steam-sdl
```

## Hardware validation and limits

- macOS confirmed four distinct, simultaneous Bluetooth controller connections.
- Steam opened indices 0–3 and reserved independent input slots.
- At the four-controller game startup, all four logged `uses xinput : true` for
  Lovers in a Dangerous Spacetime (`252110`).
- Four distinct virtual output names, `GamePad-1` through `GamePad-4`, were present.
- The game displayed four selected players. The user confirmed all four controllers
  changed their own characters independently, then independently moved and jumped
  in the tutorial level. The four-player gameplay test passed.
- Two failed saved pairings were replaced individually. Some earlier reconnect
  attempts logged `Encryption mode downgraded ... from 2 to 1. Disconnecting device.`
  Other game-launch drops used a different Bluetooth/HID status. The encryption error
  is not established as the cause of every earlier drop. No Bluetooth security policy
  was changed, and routine reconnect after a future sleep/power cycle remains unverified.
- One game test cannot establish compatibility with every Steam game. A game still
  needs controller and local multiplayer support.

Native macOS GameController originally enumerated zero raw Afterglow controllers.
The separate WaveBird virtual-HID bridge for applications outside this Steam route
still needs [Apple-approved signing](macos-signing.md).

Primary references: [SDL protocol override](https://wiki.libsdl.org/SDL3/SDL_HINT_GAMECONTROLLERTYPE),
[Switch HID driver](https://github.com/libsdl-org/SDL/blob/ab5541ec5/src/joystick/hidapi/SDL_hidapi_switch.c),
[SDL3 dynamic API](https://github.com/libsdl-org/SDL/blob/ab5541ec5/src/dynapi/SDL_dynapi.c),
[Valve's Mac controller instructions](https://help.steampowered.com/en/faqs/view/33E8-5EDF-24E6-4CFB).
