import Foundation

enum AfterglowBluetoothCommands {
    // NS1 Switch Pro subcommands, NOT Nintendo Switch 2 BLE commands.
    // Both ACKed by the Afterglow 0E6F:0194 on 2026-11-01; the player-1
    // light was also visually confirmed. SDL ConstructSubcommand/WritePacket:
    // https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_switch.c
    static func initialize(player: Int) -> [Data] {
        guard (1...4).contains(player) else { return [] }
        return [
            subcommand(0x30, value: UInt8(1 << (player - 1)), sequence: 0),
            subcommand(0x03, value: 0x30, sequence: 1),
        ]
    }

    private static func subcommand(_ command: UInt8, value: UInt8, sequence: UInt8) -> Data {
        var bytes = Data([
            0x01, sequence & 0x0F,
            0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, // neutral rumble
            command, value,
        ])
        bytes.append(Data(repeating: 0, count: 49 - bytes.count))
        return bytes
    }
}
