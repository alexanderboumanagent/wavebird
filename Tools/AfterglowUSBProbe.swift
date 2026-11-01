// Read-only hardware diagnostic. No virtual controller or device writes.
// swiftc -parse-as-library Tools/AfterglowUSBProbe.swift -o /tmp/afterglow-probe
import CoreHID
import Foundation

@main
struct AfterglowUSBProbe {
    static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    static func main() async {
        Task {
            try? await Task.sleep(for: .seconds(15))
            log("Probe timed out waiting for reports.")
            exit(2)
        }
        let manager = HIDDeviceManager()
        do {
            for try await notification in await manager.monitorNotifications(matchingCriteria: [
                .init(vendorID: 0x0E6F, productID: 0x0194, transport: .usb),
            ]) {
                guard case .deviceMatched(let reference) = notification,
                      let client = HIDDeviceClient(deviceReference: reference) else { continue }
                log("Found: \(await client.product ?? "Afterglow")")
                log("Descriptor: \(hex(await client.descriptor))")
                var count = 0
                for try await event in await client.monitorNotifications(
                    reportIDsToMonitor: [HIDReportID.allReports], elementsToMonitor: []
                ) {
                    guard case .inputReport(let id, let data, _) = event else { continue }
                    count += 1
                    if count <= 5 { log("Report \(id?.rawValue ?? 0): \(hex(data))") }
                    if count == 100 {
                        log("Received 100 input reports through CoreHID.")
                        return
                    }
                }
            }
        } catch {
            log("CoreHID error: \(error)")
            exit(1)
        }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
