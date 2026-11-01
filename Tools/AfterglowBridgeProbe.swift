// End-to-end hardware check using the app's real USB transport, coordinator,
// and Xbox output. Built by Tools/build-local.sh --probe.
import Foundation
import GameController

@main
struct AfterglowBridgeProbe {
    static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--input-only") {
            await checkUSBReconnects()
            return
        }
        let coordinator = BridgeCoordinator(profiles: [AfterglowWaveProfile()], transports: [USBTransport()])
        await coordinator.start()
        await coordinator.startScanning()
        for _ in 0..<100 {
            if let record = coordinator.devices.values.first(where: { $0.awaitingProfileSelection }) {
                log("USB source ready: \(record.advertisement.localName ?? record.profile.name)")
                await coordinator.activateWithProfile(
                    MappingProfile.defaultProfileID(forModeID: "xboxSeries"), for: record.id
                )
            }
            if let issue = coordinator.hidAccessIssue {
                log("Virtual gamepad blocked: \(issue.message)")
                exit(1)
            }
            if coordinator.devices.values.contains(where: { $0.virtualHID != nil }) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let record = coordinator.devices.values.first(where: { $0.virtualHID != nil }) else {
            log("No virtual controller was created.")
            exit(2)
        }
        log("Virtual Xbox controller activated.")
        GCController.shouldMonitorBackgroundEvents = true
        for _ in 0..<50 {
            if let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
                log("GameController.framework sees: \(controller.vendorName ?? "unknown"), \(controller.productCategory), extended gamepad")
                log("PASS: physical USB -> WaveBird -> macOS game controller")
                await coordinator.disconnectController(record.id)
                await coordinator.stopScanning()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log("Virtual HID exists, but GameController.framework did not expose an extended gamepad.")
        exit(3)
    }

    static func checkUSBReconnects() async {
        Task {
            try? await Task.sleep(for: .seconds(15))
            log("FAIL: USB read/reconnect test timed out.")
            exit(4)
        }
        let transport = USBTransport()
        let profile = AfterglowWaveProfile()
        let matchers = [TransportMatcher.usb(profile.usbMatcher!)]
        await transport.startDiscovery(matchers: matchers)
        var reports = 0
        var cycles = 0
        var identity: String?
        for await event in transport.events {
            switch event {
            case .discovered(let id, _):
                do { try await transport.connect(id) }
                catch { log("FAIL: \(error)"); exit(5) }
            case .metadata(_, let metadata):
                if let previous = identity, previous != metadata.serial {
                    log("FAIL: USB identity changed on reconnect.")
                    exit(6)
                }
                identity = metadata.serial
            case .reportReceived(let id, let reportID, let data):
                guard profile.parseUSBReport(data, reportID: reportID ?? 0, calibration: .init()) != nil else {
                    log("FAIL: unexpected input report \(data as NSData)")
                    exit(7)
                }
                reports += 1
                if reports % 100 == 0 {
                    cycles += 1
                    log("USB read/reconnect cycle \(cycles) passed (\(reports) reports)")
                    await transport.disconnect(id)
                    await transport.stopDiscovery()
                    if cycles == 3 {
                        log("PASS: 300 USB reports decoded across three connections; identity remained stable.")
                        return
                    }
                    await transport.startDiscovery(matchers: matchers)
                }
            default: break
            }
        }
    }
}
