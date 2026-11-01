import Foundation
import Testing
@testable import WaveBird

struct AfterglowBluetoothTests {
    // Captured wire packets, 0E6F:0194, 2026-11-01. These include report ID.
    private let simple = Data([0x3F, 0, 0, 8, 0xE0, 0x83, 0x3F, 0x7C, 0xC0, 0x80, 0x4F, 0x7C])
    private var full: Data {
        Data([0x30, 0x08, 0x80, 0, 0, 0, 0x3F, 0x28, 0x83, 0x09, 0x78, 0x83, 0]) + Data(repeating: 0, count: 36)
    }

    @Test func capturedRestingSticksDoNotDriftInEitherReportMode() throws {
        for report in [simple, full] {
            let state = try #require(AfterglowBluetoothReport.decode(report, reportID: report.first!))
            #expect(state.leftStick == .zero && state.rightStick == .zero)
            #expect(state.buttons.isEmpty && state.imu == nil)
            #expect(state.triggerL == 0 && state.triggerR == 0)
        }
    }

    @Test func malformedPacketsAndCommandRepliesAreRejected() {
        for report in [simple, full] {
            #expect(AfterglowBluetoothReport.decode(report.dropLast(), reportID: report.first!) == nil)
            #expect(AfterglowBluetoothReport.decode(report + Data([0]), reportID: report.first!) == nil)
            #expect(AfterglowBluetoothReport.decode(report, reportID: 0x21) == nil)
            var wrongPrefix = report
            wrongPrefix[0] = 0
            #expect(AfterglowBluetoothReport.decode(wrongPrefix, reportID: report.first!) == nil)
        }
        #expect(AfterglowBluetoothReport.decode(Data(), reportID: 0) == nil)
        #expect(AfterglowBluetoothReport.decode(Data(repeating: 0x21, count: 49), reportID: 0x21) == nil)
    }

    @Test func slicedDataIsDecodedUsingItsActualStartIndex() throws {
        for report in [simple, full] {
            let framed = Data([0xFF]) + report + Data([0xFF])
            let state = try #require(AfterglowBluetoothReport.decode(framed[1..<(report.count + 1)], reportID: report.first!))
            #expect(state.leftStick == .zero && state.buttons.isEmpty)
        }
    }

    @Test func simpleFaceButtonLabelsMatchInteractiveCapture() throws {
        let vectors: [(UInt8, ButtonSet)] = [(0x02, .a), (0x01, .b), (0x08, .x), (0x04, .y)]
        for (bits, expected) in vectors {
            var report = simple
            report[1] = bits
            let state = try #require(AfterglowBluetoothReport.decode(report, reportID: 0x3F))
            #expect(state.buttons == expected)
        }
    }

    @Test func simpleDigitalShouldersAndSystemButtons() throws {
        var report = simple
        report[1] = 0xF0
        report[2] = 0x3F
        let state = try #require(AfterglowBluetoothReport.decode(report, reportID: 0x3F))
        #expect(state.buttons == [.l, .r, .zl, .zr, .minus, .plus, .stickL, .stickR, .home, .capture])
        #expect(state.triggerL == 255 && state.triggerR == 255)
        #expect(state.shoulders.leftBumper && state.shoulders.rightBumper)
        #expect(state.shoulders.leftTriggerDigital && state.shoulders.rightTriggerDigital)
        report[1] = 0
        report[2] = 0x80 // Alternate simple-report ZR bit accepted by SDL.
        let alternate = try #require(AfterglowBluetoothReport.decode(report, reportID: 0x3F))
        #expect(alternate.buttons == .zr && alternate.triggerR == 255)
    }

    @Test func simpleHatDirectionsAndNullPadding() throws {
        let vectors: [(UInt8, ButtonSet)] = [
            (0, .dpadUp), (1, [.dpadUp, .dpadRight]), (2, .dpadRight),
            (3, [.dpadDown, .dpadRight]), (4, .dpadDown),
            (5, [.dpadDown, .dpadLeft]), (6, .dpadLeft),
            (7, [.dpadUp, .dpadLeft]), (8, []), (15, []),
        ]
        for (hat, expected) in vectors {
            var report = simple
            report[3] = hat | 0xF0
            #expect(AfterglowBluetoothReport.decode(report, reportID: 0x3F)?.buttons == expected)
        }
    }

    @Test func simpleAxisRailsHaveUpPositiveYAndNoOverflow() throws {
        var report = simple
        report.replaceSubrange(4..<12, with: [0, 0, 0, 0, 255, 255, 255, 255])
        let state = try #require(AfterglowBluetoothReport.decode(report, reportID: 0x3F))
        #expect(state.leftStick == SIMD2<Int16>(-2047, 2047))
        #expect(state.rightStick == SIMD2<Int16>(2047, -2047))
    }

    @Test func everySixteenBitAxisValueIsMonotonicAndBounded() {
        var previous: Int16 = -2047
        for raw in UInt16.min...UInt16.max {
            let value = AfterglowBluetoothReport.axis(raw)
            #expect((-2047...2047).contains(value))
            #expect(value >= previous)
            previous = value
        }
        #expect(AfterglowBluetoothReport.axis(32768) == 0)
        #expect(AfterglowBluetoothReport.axis(0) == -2047)
        #expect(AfterglowBluetoothReport.axis(65535) == 2047)
    }

    @Test func fullReportUsesDifferentButtonAndStickOffsets() throws {
        var report = full
        report[3] = 0xC8 // A, R, ZR
        report[4] = 0x7E // Plus, both clicks, Home, Capture, C
        report[5] = 0xC8 // Left, L, ZL
        report.replaceSubrange(6..<12, with: [0, 0xF0, 0xFF, 0xFF, 0x0F, 0])
        let state = try #require(AfterglowBluetoothReport.decode(report, reportID: 0x30))
        #expect(state.buttons == [.a, .r, .zr, .plus, .stickL, .stickR, .home, .capture, .c, .dpadLeft, .l, .zl])
        #expect(state.leftStick == SIMD2<Int16>(-2047, 2047))
        #expect(state.rightStick == SIMD2<Int16>(2047, -2047))
        #expect(state.triggerL == 255 && state.triggerR == 255)
    }

    @Test func initializationHasFourDistinctPlayerLightsAndCorrectModeCommand() {
        for player in 1...4 {
            let commands = AfterglowBluetoothCommands.initialize(player: player)
            #expect(commands.count == 2)
            #expect(commands.allSatisfy { $0.count == 49 && $0.first == 1 })
            #expect(commands[0][10] == 0x30 && commands[0][11] == UInt8(1 << (player - 1)))
            #expect(commands[1][10] == 0x03 && commands[1][11] == 0x30)
            #expect(commands[0][1] == 0 && commands[1][1] == 1)
            #expect(commands[0].dropFirst(12).allSatisfy { $0 == 0 })
        }
        #expect(AfterglowBluetoothCommands.initialize(player: 0).isEmpty)
        #expect(AfterglowBluetoothCommands.initialize(player: 5).isEmpty)
    }

    @Test func fourIdenticalModelsKeepSeparatePersistentAndOutputIdentities() throws {
        let addresses = ["AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:02", "AA:BB:CC:DD:EE:03", "AA:BB:CC:DD:EE:04"]
        let identities = try addresses.map {
            try #require(BluetoothHIDMatcher.persistentIdentity(vendorID: 0x0E6F, productID: 0x0194, serial: $0, uniqueID: nil))
        }
        #expect(Set(identities).count == 4)
        #expect(Set(identities.map { VirtualHIDDevice.hidSerialNumber(deviceSerial: $0, modeID: "xboxSeries") }).count == 4)
        #expect(BluetoothHIDMatcher.persistentIdentity(vendorID: 0x0E6F, productID: 0x0194, serial: nil, uniqueID: nil) == nil)
        let matcher = try #require(AfterglowWaveProfile().bluetoothHIDMatcher)
        #expect(matcher.matches(vendorID: 0x0E6F, productID: 0x0194))
        #expect(!matcher.matches(vendorID: 0x057E, productID: 0x0194))
        #expect(!matcher.matches(vendorID: 0x0E6F, productID: 0x0193))
    }

    @Test func acknowledgementsMatchTheEchoedSubcommandAndStatus() {
        let commands = AfterglowBluetoothCommands.initialize(player: 1)
        var reply = Data([0x21, 2, 0x80, 0, 0, 0, 0x3E, 0xF8, 0x82, 0x0A, 0x38, 0x83, 0, 0x80, 0x30])
        reply.append(Data(repeating: 0, count: 34))
        #expect(AfterglowBluetoothCommands.acknowledgement(reply, for: commands[0]) == true)
        #expect(AfterglowBluetoothCommands.acknowledgement(reply, for: commands[1]) == nil)
        reply[13] = 0
        #expect(AfterglowBluetoothCommands.acknowledgement(reply, for: commands[0]) == false)
        #expect(AfterglowBluetoothCommands.acknowledgement(reply.prefix(14), for: commands[0]) == nil)
        let framed = Data([0xFF]) + reply
        #expect(AfterglowBluetoothCommands.acknowledgement(framed.dropFirst(), for: commands[0]) == false)
    }
}
