import Foundation
import Testing
@testable import WaveBird

struct AfterglowUSBTests {
    // Captured via CoreHID from 0E6F:0194, firmware 0x0102, 2026-11-01.
    private let neutral = Data([0x00, 0x00, 0x0F, 0x80, 0x80, 0x80, 0x80, 0x00])

    @Test func capturedNeutralReport() throws {
        let state = try #require(AfterglowUSBReport.decode(neutral, reportID: 0))
        #expect(state.buttons.isEmpty)
        #expect(state.leftStick == .zero)
        #expect(state.rightStick == .zero)
        #expect(state.triggerL == 0 && state.triggerR == 0)
        #expect(state.imu == nil)
    }

    @Test func malformedReportsAreRejected() {
        #expect(AfterglowUSBReport.decode(neutral.dropLast(), reportID: 0) == nil)
        #expect(AfterglowUSBReport.decode(neutral + Data([0]), reportID: 0) == nil)
        #expect(AfterglowUSBReport.decode(neutral, reportID: 5) == nil)
    }

    @Test func slicedDataDoesNotAssumeZeroBasedIndices() throws {
        let framed = Data([0xFF]) + neutral + Data([0xFF])
        let state = try #require(AfterglowUSBReport.decode(framed[1..<9], reportID: 0))
        #expect(state.leftStick == .zero && state.buttons.isEmpty)
    }

    @Test func axisRailsAndYDirection() throws {
        var report = neutral
        report[3] = 0
        report[4] = 255
        report[5] = 255
        report[6] = 0
        let state = try #require(AfterglowUSBReport.decode(report, reportID: 0))
        #expect(state.leftStick == SIMD2<Int16>(-2047, -2047))
        #expect(state.rightStick == SIMD2<Int16>(2047, 2047))
    }

    @Test func allAxisValuesStayMonotonicAndWithinTwelveBitRange() throws {
        var previous: Int16 = -2047
        for raw in UInt8.min...UInt8.max {
            var report = neutral
            report[3] = raw
            let state = try #require(AfterglowUSBReport.decode(report, reportID: 0))
            #expect((-2047...2047).contains(state.leftStick.x))
            #expect(state.leftStick.x >= previous)
            previous = state.leftStick.x
        }
    }

    @Test func hatDirections() throws {
        let vectors: [(UInt8, ButtonSet)] = [
            (0, .dpadUp), (1, [.dpadUp, .dpadRight]), (2, .dpadRight),
            (3, [.dpadRight, .dpadDown]), (4, .dpadDown),
            (5, [.dpadDown, .dpadLeft]), (6, .dpadLeft),
            (7, [.dpadLeft, .dpadUp]), (8, []), (15, []),
        ]
        for (hat, expected) in vectors {
            var report = neutral
            report[2] = hat
            let state = try #require(AfterglowUSBReport.decode(report, reportID: 0))
            #expect(state.buttons == expected)
        }
    }

    @Test func digitalTriggersAndIndependentButtonBits() throws {
        var report = neutral
        report[0] = 0xD4 // A, L, ZL, ZR in the PDP mapping.
        report[1] = 0x26 // Plus, left stick click, Capture.
        let state = try #require(AfterglowUSBReport.decode(report, reportID: 0))
        #expect(state.buttons == [.a, .l, .zl, .zr, .plus, .stickL, .capture])
        #expect(state.triggerL == 255 && state.triggerR == 255)
        #expect(state.shoulders.leftBumper && !state.shoulders.rightBumper)
        #expect(state.shoulders.leftTriggerDigital && state.shoulders.rightTriggerDigital)
        #expect(state.shoulders.leftTriggerAnalog == 255 && state.shoulders.rightTriggerAnalog == 255)
    }

    @Test func descriptorPaddingDoesNotBecomeButtons() throws {
        var report = neutral
        report[1] = 0xC0
        report[2] = 0xFF
        report[7] = 0xFF
        let state = try #require(AfterglowUSBReport.decode(report, reportID: 0))
        #expect(state.buttons.isEmpty)
    }

    @Test func usbMatchingIncludesVendor() {
        let matcher = AfterglowWaveProfile().usbMatcher!
        #expect(matcher.matches(vendorID: 0x0E6F, productID: 0x0194))
        #expect(!matcher.matches(vendorID: 0x057E, productID: 0x0194))
        #expect(!matcher.matches(vendorID: 0x0E6F, productID: 0x0188))
    }

    @Test func serialLessIdentitiesAreStablePerPortAndDistinctAcrossPorts() {
        let first = USBMatcher.persistentIdentity(vendorID: 0x0E6F, productID: 0x0194, serial: nil, locationID: 10, fallbackID: 1)
        let reconnect = USBMatcher.persistentIdentity(vendorID: 0x0E6F, productID: 0x0194, serial: nil, locationID: 10, fallbackID: 2)
        let second = USBMatcher.persistentIdentity(vendorID: 0x0E6F, productID: 0x0194, serial: nil, locationID: 11, fallbackID: 1)
        #expect(first == reconnect)
        #expect(first != second)
    }

    @Test func hardwareSerialTakesPrecedenceOverPort() {
        let first = USBMatcher.persistentIdentity(vendorID: 0x0E6F, productID: 0x0194, serial: "one", locationID: 10, fallbackID: 1)
        let moved = USBMatcher.persistentIdentity(vendorID: 0x0E6F, productID: 0x0194, serial: "one", locationID: 11, fallbackID: 2)
        #expect(first == moved)
    }
}
