import Foundation

enum AfterglowUSBReport {
    // Descriptor and neutral report captured from 0E6F:0194 on 2026-11-01:
    // 14 button bits, 2 padding bits, a 4-bit hat + padding, X/Y/Z/Rz,
    // and one reserved byte. Report IDs are not used.
    // Face-button ordering mirrors SDL_GameControllerDB's PDP Afterglow
    // Deluxe mapping (0E6F:0188); confirm the labels on new hardware.
    // https://github.com/mdqinc/SDL_GameControllerDB/blob/master/gamecontrollerdb.txt
    static func decode(_ data: Data, reportID: UInt8) -> ControllerState? {
        guard reportID == 0, data.count == 8 else { return nil }
        let bytes = Array(data)
        let bits = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        let buttonOrder: [ButtonSet] = [
            .y, .b, .a, .x, .l, .r, .zl, .zr,
            .minus, .plus, .stickL, .stickR, .home, .capture,
        ]
        var buttons: ButtonSet = []
        for (bit, button) in buttonOrder.enumerated() where bits & (1 << bit) != 0 {
            buttons.insert(button)
        }
        let hats: [ButtonSet] = [
            .dpadUp, [.dpadUp, .dpadRight], .dpadRight, [.dpadRight, .dpadDown],
            .dpadDown, [.dpadDown, .dpadLeft], .dpadLeft, [.dpadLeft, .dpadUp],
        ]
        let hat = Int(bytes[2] & 0x0F)
        if hat < hats.count { buttons.formUnion(hats[hat]) }
        let zl = buttons.contains(.zl)
        let zr = buttons.contains(.zr)
        return ControllerState(
            leftStick: SIMD2(axis(bytes[3]), -axis(bytes[4])),
            rightStick: SIMD2(axis(bytes[5]), -axis(bytes[6])),
            triggerL: zl ? 255 : 0,
            triggerR: zr ? 255 : 0,
            buttons: buttons,
            imu: nil,
            timestamp: .now,
            shoulders: StandardShoulders(
                leftBumper: buttons.contains(.l), rightBumper: buttons.contains(.r),
                leftTriggerDigital: zl, rightTriggerDigital: zr,
                leftTriggerAnalog: zl ? 255 : 0, rightTriggerAnalog: zr ? 255 : 0
            )
        )
    }

    private static func axis(_ raw: UInt8) -> Int16 {
        let centered = Int(raw) - 128
        return Int16(centered * 2047 / (centered < 0 ? 128 : 127))
    }
}
