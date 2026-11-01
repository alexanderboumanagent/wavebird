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
    private var wantsScan = false
    private var retry: Task<Void, Never>?
    private let events: AsyncStream<TransportEvent>.Continuation

    init(events: AsyncStream<TransportEvent>.Continuation) {
        self.events = events
        super.init()
        inquiry = IOBluetoothDeviceInquiry(delegate: self)
        inquiry.inquiryLength = 12
        inquiry.updateNewDeviceNames = true
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start(names: Set<String>) {
        self.names = names
        wantsScan = true
        startInquiry()
    }

    func stop() {
        wantsScan = false
        retry?.cancel()
        retry = nil
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
