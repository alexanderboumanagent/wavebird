// End-to-end hardware check using the app's real input transport, coordinator,
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
        let bluetooth = CommandLine.arguments.contains("--bluetooth")
        if CommandLine.arguments.contains("--four-inputs") {
            await checkFourBluetoothInputs()
            return
        }
        if CommandLine.arguments.contains("--input-only") {
            await checkInputReconnects(bluetooth: bluetooth)
            return
        }
        let transport: any Transport = bluetooth ? BluetoothHIDTransport() : USBTransport()
        let coordinator = BridgeCoordinator(profiles: [AfterglowWaveProfile()], transports: [transport])
        await coordinator.start()
        await coordinator.startScanning()
        for _ in 0..<100 {
            if let record = coordinator.devices.values.first(where: { $0.awaitingProfileSelection }) {
                log("Input source ready: \(record.advertisement.localName ?? record.profile.name)")
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
                log("PASS: physical controller -> WaveBird -> macOS game controller")
                await coordinator.disconnectController(record.id)
                await coordinator.stopScanning()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log("Virtual HID exists, but GameController.framework did not expose an extended gamepad.")
        exit(3)
    }

    static func checkInputReconnects(bluetooth: Bool) async {
        let label = bluetooth ? "Bluetooth" : "USB"
        Task {
            try? await Task.sleep(for: .seconds(15))
            log("FAIL: \(label) read/resubscribe test timed out.")
            exit(4)
        }
        let transport: any Transport = bluetooth ? BluetoothHIDTransport() : USBTransport()
        let profile = AfterglowWaveProfile()
        let matchers: [TransportMatcher] = bluetooth
            ? [.bluetoothHID(profile.bluetoothHIDMatcher!)]
            : [.usb(profile.usbMatcher!)]
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
                    log("FAIL: \(label) identity changed on resubscribe.")
                    exit(6)
                }
                identity = metadata.serial
            case .reportReceived(let id, let reportID, let data):
                if bluetooth, reportID == 0x21 { continue } // subcommand ACK
                let decoded = bluetooth
                    ? profile.parseBluetoothHIDReport(data, reportID: reportID ?? 0, calibration: .init())
                    : profile.parseUSBReport(data, reportID: reportID ?? 0, calibration: .init())
                guard decoded != nil else {
                    log("FAIL: unexpected input report \(data as NSData)")
                    exit(7)
                }
                reports += 1
                if reports % 100 == 0 {
                    cycles += 1
                    log("\(label) read/resubscribe cycle \(cycles) passed (\(reports) reports)")
                    await transport.disconnect(id)
                    await transport.stopDiscovery()
                    if cycles == 3 {
                        log("PASS: 300 \(label) reports decoded across three input subscriptions; identity remained stable.")
                        return
                    }
                    await transport.startDiscovery(matchers: matchers)
                }
            default: break
            }
        }
    }

    static func checkFourBluetoothInputs() async {
        Task {
            try? await Task.sleep(for: .seconds(600))
            log("FAIL: four-controller input test timed out.")
            exit(8)
        }
        let transport = BluetoothHIDTransport()
        let profile = AfterglowWaveProfile()
        await transport.startDiscovery(matchers: [.bluetoothHID(profile.bluetoothHIDMatcher!)])
        var identities: [DeviceID: String] = [:]
        var counts: [DeviceID: Int] = [:]
        var lastStates: [DeviceID: InputSignature] = [:]
        var lastReports: [DeviceID: ContinuousClock.Instant] = [:]
        var passed = false
        for await event in transport.events {
            switch event {
            case .discovered(let id, _):
                do { try await transport.connect(id) }
                catch { log("FAIL: connecting controller: \(error)"); exit(9) }
            case .metadata(let id, let metadata):
                guard let identity = metadata.serial,
                      !identities.contains(where: { $0.key != id && $0.value == identity }) else {
                    log("FAIL: controller identities collided.")
                    exit(10)
                }
                identities[id] = identity
                log("Connected \(identities.count)/4: \(identity)")
            case .reportReceived(let id, let reportID, let bytes):
                if reportID == 0x21 { continue }
                guard let state = profile.parseBluetoothHIDReport(bytes, reportID: reportID ?? 0, calibration: .init()) else {
                    log("FAIL: unsupported Bluetooth input: \(bytes as NSData)")
                    exit(11)
                }
                counts[id, default: 0] += 1
                lastReports[id] = .now
                if lastStates[id] != state.idleSignature {
                    lastStates[id] = state.idleSignature
                    log("\(identities[id] ?? "pending identity"): buttons=\(state.buttons.rawValue) left=\(state.leftStick) right=\(state.rightStick)")
                }
                if !passed, identities.count == 4, identities.keys.allSatisfy({
                    counts[$0, default: 0] >= 100 &&
                    (lastReports[$0].map { $0.duration(to: .now) < .seconds(1) } ?? false)
                }) {
                    passed = true
                    log("PASS: four distinct Bluetooth controllers simultaneously streamed at least 100 decoded reports each.")
                    if CommandLine.arguments.contains("--monitor") { continue }
                    for id in identities.keys { await transport.disconnect(id) }
                    await transport.stopDiscovery()
                    return
                }
            case .disconnected(let id, let reason):
                log("Disconnected \(identities[id] ?? "unknown"): \(reason)")
                identities[id] = nil
                counts[id] = nil
                lastReports[id] = nil
                passed = false
            case .error(_, let message): log("Bluetooth: \(message)")
            default: break
            }
        }
    }
}
