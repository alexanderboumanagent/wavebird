// Diagnostic for the Bluetooth path, independent of virtual-HID signing.
// swiftc Tools/AfterglowBluetoothProbe.swift -o /tmp/afterglow-bluetooth-probe
// /tmp/afterglow-bluetooth-probe [--pair] [--seconds 120]
// Pairing is opt-in and only targets the observed "Lic3 Pro Controller" name.
import Foundation
import CoreBluetooth
import CoreHID
import GameController
import IOBluetooth

func probeLog(_ value: String) {
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
}

final class BluetoothProbe: NSObject, CBCentralManagerDelegate,
                            IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate {
    private var central: CBCentralManager!
    private var inquiry: IOBluetoothDeviceInquiry!
    private var pairing: IOBluetoothDevicePair?
    private let shouldPair: Bool
    private var seenBLE: Set<UUID> = []
    private var foundClassic: Set<String> = []
    private var stopped = false

    init(shouldPair: Bool) {
        self.shouldPair = shouldPair
        super.init()
        inquiry = IOBluetoothDeviceInquiry(delegate: self)
        inquiry.inquiryLength = 12
        inquiry.updateNewDeviceNames = true
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        probeLog("Bluetooth state=\(central.state.rawValue), authorization=\(CBManager.authorization.rawValue)")
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil)
        startInquiry()
    }

    private func startInquiry() {
        guard !stopped, pairing == nil else { return }
        inquiry.clearFoundDevices()
        probeLog("Classic inquiry start=\(inquiry.start()); press SYNC for 3 seconds")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard Self.isControllerName(name), seenBLE.insert(peripheral.identifier).inserted else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        probeLog("BLE candidate name=\(name) id=\(peripheral.identifier) RSSI=\(RSSI) services=\(services) manufacturer=\(manufacturer.hexString)")
    }

    static func isControllerName(_ name: String) -> Bool {
        ["lic3 pro controller", "afterglow", "turtle beach", "rematch"].contains {
            name.lowercased().contains($0)
        }
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice) {
        found(device)
    }

    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice,
                                       devicesRemaining: UInt32) {
        found(device)
    }

    private func found(_ device: IOBluetoothDevice) {
        guard Self.isControllerName(device.name ?? "") else { return }
        let address = device.addressString ?? "unknown"
        if foundClassic.insert(address).inserted {
            probeLog("Classic candidate name=\(device.name ?? "?") address=\(address) class=\(device.classOfDevice) paired=\(device.isPaired())")
            dumpDeviceID(device)
        }
        guard shouldPair, pairing == nil, device.name == "Lic3 Pro Controller", !device.isPaired() else { return }
        pairing = IOBluetoothDevicePair(device: device)
        pairing?.delegate = self
        _ = inquiry.stop()
        // Leave the inquiry callback before starting another remote operation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            guard !stopped, let pairing else { return }
            probeLog("Pairing start=\(pairing.start())")
        }
    }

    private func dumpDeviceID(_ device: IOBluetoothDevice) {
        guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1200)) else {
            probeLog("SDP Device ID record not cached yet")
            return
        }
        let vendor = record.getAttributeDataElement(0x0201)?.getNumberValue()?.uint16Value
        let product = record.getAttributeDataElement(0x0202)?.getNumberValue()?.uint16Value
        if let vendor, let product { probeLog(String(format: "SDP VID=%04X PID=%04X", vendor, product)) }
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry, error: IOReturn, aborted: Bool) {
        probeLog("Classic inquiry complete status=\(error), aborted=\(aborted)")
        guard !aborted, !stopped, pairing == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in startInquiry() }
    }

    func devicePairingStarted(_ sender: Any!) { probeLog("Pairing started") }
    func devicePairingConnected(_ sender: Any!) { probeLog("Bluetooth link connected") }
    func devicePairingPINCodeRequest(_ sender: Any!) {
        probeLog("Legacy PIN requested; no guessed PIN sent")
    }
    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        probeLog("Numeric confirmation requested: \(numericValue); waiting for user confirmation")
    }
    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        probeLog("Pairing finished status=\(error), paired=\(pairing?.device().isPaired() ?? false), connected=\(pairing?.device().isConnected() ?? false)")
        if let device = pairing?.device() { dumpDeviceID(device) }
        pairing = nil
        if error != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in startInquiry() }
        }
    }

    func stop() {
        stopped = true
        central.stopScan()
        _ = inquiry.stop()
        // Do not call pairing.stop() after success: it can disconnect the device.
        if let pairing, !pairing.device().isPaired() { pairing.stop() }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

let arguments = CommandLine.arguments
let duration: Double
if let i = arguments.firstIndex(of: "--seconds"), i + 1 < arguments.count,
   let parsed = Double(arguments[i + 1]), parsed > 0, parsed <= 600 { duration = parsed }
else { duration = 120 }

let probe = BluetoothProbe(shouldPair: arguments.contains("--pair"))
let hidTask = Task {
    let manager = HIDDeviceManager()
    do {
        for try await event in await manager.monitorNotifications(matchingCriteria: [
            .init(primaryUsage: .genericDesktop(.gamepad), transport: .bluetooth),
            .init(primaryUsage: .genericDesktop(.gamepad), transport: .bluetoothLowEnergy),
        ]) {
            guard case .deviceMatched(let reference) = event,
                  let client = HIDDeviceClient(deviceReference: reference) else { continue }
            let product = await client.product ?? ""
            let vendor = await client.vendorID
            guard vendor == 0x0E6F || BluetoothProbe.isControllerName(product) else { continue }
            probeLog("HID device: \(await client.product ?? "?") VID=\(await client.vendorID) PID=\(await client.productID) transport=\(String(describing: await client.transport))")
            probeLog("Descriptor: \(await client.descriptor.hexString)")
            Task {
                do {
                    var count = 0
                    var last: Data?
                    for try await report in await client.monitorNotifications(reportIDsToMonitor: [HIDReportID.allReports], elementsToMonitor: []) {
                        guard case .inputReport(let id, let data, _) = report else { continue }
                        count += 1
                        if count <= 5 || (count <= 256 && data != last) {
                            probeLog("Input id=\(id?.rawValue ?? 0) size=\(data.count) bytes=\(data.hexString)")
                            last = data
                        }
                        if count == 100 || count.isMultiple(of: 1000) {
                            probeLog("Received \(count) Bluetooth input reports")
                        }
                    }
                } catch { probeLog("HID reports failed: \(error)") }
            }
        }
    } catch { probeLog("HID discovery failed: \(error)") }
}
probeLog("GameController initially sees \(GCController.controllers().count) controller(s)")
let observer = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
    guard let controller = note.object as? GCController else { return }
    probeLog("GameController connected: \(controller.vendorName ?? "?") extendedGamepad=\(controller.extendedGamepad != nil)")
}
RunLoop.main.run(until: Date().addingTimeInterval(duration))
probe.stop()
hidTask.cancel()
NotificationCenter.default.removeObserver(observer)
probeLog("Bluetooth probe finished")
