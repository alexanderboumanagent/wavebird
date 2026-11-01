@preconcurrency import CoreBluetooth
@preconcurrency import IOBluetooth
import Foundation

// Standard Bluetooth Classic pairing, separate from Nintendo's custom BLE LTK
// exchange. Pair sequentially; already connected HID clients keep streaming.
@MainActor
final class BluetoothClassicPairer: NSObject, @preconcurrency CBCentralManagerDelegate,
                                    @preconcurrency IOBluetoothDeviceInquiryDelegate,
                                    @preconcurrency IOBluetoothDevicePairDelegate {
    private var central: CBCentralManager!
    private var inquiry: IOBluetoothDeviceInquiry!
    private var pairing: IOBluetoothDevicePair?
    private var names: Set<String> = []
    private var matchers: [BluetoothHIDMatcher] = []
    private var wantsScan = false
    private var retry: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnecting: String?
    private var reconnectAttempts: [String: Date] = [:]
    private let events: AsyncStream<TransportEvent>.Continuation

    init(events: AsyncStream<TransportEvent>.Continuation) {
        self.events = events
        super.init()
        inquiry = IOBluetoothDeviceInquiry(delegate: self)
        inquiry.inquiryLength = 12
        inquiry.updateNewDeviceNames = true
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start(matchers: [BluetoothHIDMatcher]) {
        self.matchers = matchers
        names = Set(matchers.map(\.pairingName))
        wantsScan = true
        startInquiry()
        if reconnectTask == nil {
            reconnectTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.reconnectKnownController()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    func stop() {
        wantsScan = false
        retry?.cancel()
        retry = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        _ = inquiry.stop()
        if let pairing, !pairing.device().isPaired() { pairing.stop() }
        pairing = nil
    }

    private func startInquiry() {
        guard wantsScan, pairing == nil, !names.isEmpty, central.state == .poweredOn else { return }
        inquiry.clearFoundDevices()
        _ = inquiry.start()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        startInquiry()
    }

    private func reconnectKnownController() {
        guard wantsScan, central.state == .poweredOn, pairing == nil, reconnecting == nil else { return }
        let candidates = (IOBluetoothDevice.pairedDevices() ?? []).compactMap { $0 as? IOBluetoothDevice }
            .filter { device in
                guard !device.isConnected(), names.contains(device.name ?? ""),
                      let record = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1200)),
                      let vendor = record.getAttributeDataElement(0x0201)?.getNumberValue()?.uint16Value,
                      let product = record.getAttributeDataElement(0x0202)?.getNumberValue()?.uint16Value else { return false }
                return matchers.contains { $0.matches(vendorID: vendor, productID: product) }
            }
            .sorted { (reconnectAttempts[$0.addressString ?? ""] ?? .distantPast) < (reconnectAttempts[$1.addressString ?? ""] ?? .distantPast) }
        guard let device = candidates.first, let address = device.addressString else { return }
        reconnectAttempts[address] = Date()
        reconnecting = address
        // Public asynchronous form of the openConnection call verified with
        // blueutil on 2026-11-01. Do not block the UI while paging a sleeping pad.
        let status = device.openConnection(self, withPageTimeout: 0x1000, authenticationRequired: false)
        if status != kIOReturnSuccess { reconnecting = nil }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        if reconnecting == device.addressString { reconnecting = nil }
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice) {
        consider(device)
    }

    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice,
                                       devicesRemaining: UInt32) {
        consider(device)
    }

    private func consider(_ device: IOBluetoothDevice) {
        guard wantsScan, pairing == nil, names.contains(device.name ?? ""), !device.isPaired() else { return }
        let pair = IOBluetoothDevicePair(device: device)
        pairing = pair
        pair?.delegate = self
        _ = inquiry.stop()
        // Remote operations must leave the inquiry callback first.
        retry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.wantsScan,
                  let pair = self.pairing else { return }
            let result = pair.start()
            if result != kIOReturnSuccess {
                self.events.yield(.error(nil, "Bluetooth pairing could not start (\(result)). Hold SYNC to retry."))
                self.pairing = nil
                self.scheduleInquiry()
            }
        }
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry, error: IOReturn, aborted: Bool) {
        if !aborted, pairing == nil { scheduleInquiry() }
    }

    private func scheduleInquiry() {
        guard wantsScan else { return }
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.startInquiry()
        }
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        events.yield(.error(nil, "This controller requested a PIN. Pair it in macOS Bluetooth Settings."))
        pairing?.stop()
        pairing = nil
        scheduleInquiry()
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        events.yield(.error(nil, "This controller requires confirmation. Pair it in macOS Bluetooth Settings."))
        pairing?.stop()
        pairing = nil
        scheduleInquiry()
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        guard let finished = sender as? IOBluetoothDevicePair, finished === pairing else { return }
        if error != kIOReturnSuccess {
            events.yield(.error(nil, "Bluetooth pairing failed (\(error)). Hold SYNC for 3 seconds to retry."))
        }
        pairing = nil
        scheduleInquiry()
    }
}
