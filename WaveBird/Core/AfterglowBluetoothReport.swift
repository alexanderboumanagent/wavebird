import Foundation

enum AfterglowBluetoothReport {
    // Captured from 0E6F:0194 / "Lic3 Pro Controller" on 2026-11-01.
    // CoreHID includes the report-ID byte. Full 0x30 reports are 49 bytes;
    // simple 0x3F reports are 12 bytes, with unsigned LE16 sticks.
    // Layouts: SDL HandleFullControllerState / HandleSimpleControllerState:
    // https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_switch.c
    static func decode(_ data: Data, reportID: UInt8) -> ControllerState? {
        guard data.first == reportID else { return nil }
        switch reportID {
        case 0x30:
            guard data.count == 49 else { return nil }
            let i = data.startIndex
            let bits = UInt32(data[i + 3]) | UInt32(data[i + 4]) << 8 | UInt32(data[i + 5]) << 16
            let buttons = NS2ButtonBits.decode(bits, table: NS2ButtonBits.pro)
            let left = NS2Sticks.unpack(data, at: i + 6)
            let right = NS2Sticks.unpack(data, at: i + 9)
            // Unlike the simple report's HID axes, NS1 packed-stick Y is up-positive.
            return state(buttons: buttons,
                left: SIMD2(scaledAxis(left.0, center: 2048, maximum: 4095), scaledAxis(left.1, center: 2048, maximum: 4095)),
                right: SIMD2(scaledAxis(right.0, center: 2048, maximum: 4095), scaledAxis(right.1, center: 2048, maximum: 4095)))
        case 0x3F:
            guard data.count == 12 else { return nil }
            let i = data.startIndex
            let bits = UInt16(data[i + 1]) | UInt16(data[i + 2]) << 8
            let order: [ButtonSet] = [
                .b, .a, .y, .x, .l, .r, .zl, .zr,
                .minus, .plus, .stickL, .stickR, .home, .capture,
            ]
            var buttons: ButtonSet = []
            for (bit, button) in order.enumerated() where bits & (1 << bit) != 0 { buttons.insert(button) }
            // SDL also accepts bit 15 as ZR in simple reports.
            if bits & 0x8000 != 0 { buttons.insert(.zr) }
            let hats: [ButtonSet] = [
                .dpadUp, [.dpadUp, .dpadRight], .dpadRight, [.dpadRight, .dpadDown],
                .dpadDown, [.dpadDown, .dpadLeft], .dpadLeft, [.dpadLeft, .dpadUp],
            ]
            let hat = Int(data[i + 3] & 0x0F)
            if hat < hats.count { buttons.formUnion(hats[hat]) }
            return state(buttons: buttons,
                left: SIMD2(axis(data.uint16LE(at: 4)), -axis(data.uint16LE(at: 6))),
                right: SIMD2(axis(data.uint16LE(at: 8)), -axis(data.uint16LE(at: 10))))
        default: return nil
        }
    }

    static func axis(_ raw: UInt16) -> Int16 {
        scaledAxis(raw, center: 32768, maximum: 65535)
    }

    private static func scaledAxis(_ raw: UInt16, center: Int, maximum: Int) -> Int16 {
        let delta = Int(raw) - center
        // Captured resting sticks vary by ~3% around center. A 5% deadzone
        // removes this measured drift without learning a false center when
        // someone holds a stick during connection. Preserve both end stops.
        let deadzone = center / 20
        let magnitude = abs(delta)
        guard magnitude > deadzone else { return 0 }
        let extent = (delta < 0 ? center : maximum - center) - deadzone
        let scaled = (magnitude - deadzone) * 2047 / extent
        return Int16(delta < 0 ? -scaled : scaled)
    }

    private static func state(buttons: ButtonSet, left: SIMD2<Int16>, right: SIMD2<Int16>) -> ControllerState {
        let zl = buttons.contains(.zl)
        let zr = buttons.contains(.zr)
        return ControllerState(
            leftStick: left, rightStick: right,
            triggerL: zl ? 255 : 0, triggerR: zr ? 255 : 0,
            buttons: buttons, imu: nil, timestamp: .now,
            shoulders: StandardShoulders(
                leftBumper: buttons.contains(.l), rightBumper: buttons.contains(.r),
                leftTriggerDigital: zl, rightTriggerDigital: zr,
                leftTriggerAnalog: zl ? 255 : 0, rightTriggerAnalog: zr ? 255 : 0
            )
        )
    }
}
