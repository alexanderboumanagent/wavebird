import Foundation

struct AfterglowWaveProfile: ControllerProfile {
    let name = "Afterglow Wave Wireless Controller for Switch 2"
    let supportsRumble = false
    var bleMatcher: BLEMatcher? { nil }
    var usbMatcher: USBMatcher? {
        USBMatcher(vendorID: 0x0E6F, productID: 0x0194, initWrites: [])
    }
    let hidVendorID: UInt16 = 0x0E6F
    let hidProductID: UInt16 = 0x0194

    // Only needed by the debug vendor-passthrough presentation. Shipping
    // presentations use their own descriptors and the normalized state.
    var vendorPassthroughDescriptor: Data {
        VirtualHIDDevice.ns2VendorDescriptor(reportID: 0x05, byteCount: 8)
    }

    func parseBLEReport(_ data: Data, calibration: ControllerCalibration) -> ControllerState? { nil }

    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: ControllerCalibration) -> ControllerState? {
        AfterglowUSBReport.decode(data, reportID: reportID)
    }
}
