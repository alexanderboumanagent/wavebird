import CoreHID
import Foundation

enum BluetoothHIDTransportError: Error {
    case unknownDevice
    case fourControllersAlreadyConnected
}

actor BluetoothHIDTransport: Transport {
    nonisolated let kind: TransportKind = .bluetoothHID
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private let manager = HIDDeviceManager()
    private var pairer: BluetoothClassicPairer?
    private var discoveryTask: Task<Void, Never>?
    private var reportTasks: [DeviceID: Task<Void, Never>] = [:]
    private var devices: [DeviceID: Device] = [:]
    private var referenceIDs: [HIDDeviceClient.DeviceReference: DeviceID] = [:]
    private var identityIDs: [String: DeviceID] = [:]
    private var playerSlots: [DeviceID: Int] = [:]

    private struct Device: Sendable {
        let client: HIDDeviceClient
        let identity: String
    }

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .bufferingNewest(256))
        events = stream
        self.continuation = continuation
    }

    deinit {
        discoveryTask?.cancel()
        for task in reportTasks.values { task.cancel() }
        let pairer = pairer
        Task { @MainActor in pairer?.stop() }
        continuation.finish()
    }

    func startDiscovery(matchers: [TransportMatcher]) async {
        guard discoveryTask == nil else { return }
        let matchers = matchers.compactMap { matcher -> BluetoothHIDMatcher? in
            if case .bluetoothHID(let hid) = matcher { return hid }
            return nil
        }
        guard !matchers.isEmpty else { return }
        if pairer == nil { pairer = await BluetoothClassicPairer(events: continuation) }
        await pairer?.start(names: Set(matchers.map(\.pairingName)))
        let criteria = matchers.map {
            HIDDeviceManager.DeviceMatchingCriteria(primaryUsage: .genericDesktop(.gamepad),
                vendorID: UInt32($0.vendorID), productID: UInt32($0.productID), transport: .bluetooth)
        }
        let manager = manager
        discoveryTask = Task { [weak self] in
            do {
                for try await event in await manager.monitorNotifications(matchingCriteria: criteria) {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .deviceMatched(let reference): await self?.matched(reference, matchers: matchers)
                    case .deviceRemoved(let reference): await self?.removed(reference)
                    @unknown default: break
                    }
                }
            } catch {
                if !Task.isCancelled { await self?.discoveryFailed(error.localizedDescription) }
            }
        }
    }

    func stopDiscovery() async {
        discoveryTask?.cancel()
        discoveryTask = nil
        await pairer?.stop()
    }

    private func matched(_ reference: HIDDeviceClient.DeviceReference, matchers: [BluetoothHIDMatcher]) async {
        guard let client = HIDDeviceClient(deviceReference: reference) else { return }
        let vendor = UInt16(clamping: await client.vendorID)
        let product = UInt16(clamping: await client.productID)
        guard matchers.contains(where: { $0.matches(vendorID: vendor, productID: product) }),
              let identity = BluetoothHIDMatcher.persistentIdentity(
                vendorID: vendor, productID: product,
                serial: await client.serialNumber, uniqueID: await client.uniqueID
              ), !Task.isCancelled else { return }
        let id = identityIDs[identity] ?? DeviceID(transport: .bluetoothHID, raw: UUID())
        identityIDs[identity] = id
        if let previous = devices[id], previous.client.deviceReference != reference {
            streamEnded(id, reason: .linkLoss)
            referenceIDs[previous.client.deviceReference] = nil
        }
        devices[id] = Device(client: client, identity: identity)
        referenceIDs[reference] = id
        continuation.yield(.availability(reason: nil))
        continuation.yield(.discovered(id, AdvertisementInfo(
            vendorID: vendor, productID: product, localName: await client.product, rssi: nil
        )))
    }

    func connect(_ id: DeviceID) async throws {
        guard let device = devices[id] else { throw BluetoothHIDTransportError.unknownDevice }
        guard reportTasks[id] == nil else { return }
        guard let slot = (1...4).first(where: { !playerSlots.values.contains($0) }) else {
            throw BluetoothHIDTransportError.fourControllersAlreadyConnected
        }
        playerSlots[id] = slot
        continuation.yield(.connecting(id))
        let notifications = await device.client.monitorNotifications(
            reportIDsToMonitor: [HIDReportID.allReports], elementsToMonitor: []
        )
        guard devices[id]?.client == device.client else {
            playerSlots[id] = nil
            throw BluetoothHIDTransportError.unknownDevice
        }
        continuation.yield(.connected(id))
        continuation.yield(.metadata(id, ControllerMetadata(serial: device.identity)))
        let continuation = continuation
        reportTasks[id] = Task { [weak self] in
            do {
                for try await event in notifications {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .inputReport(let reportID, let data, _):
                        continuation.yield(.reportReceived(id, reportID: reportID?.rawValue, data))
                    case .deviceRemoved:
                        await self?.removed(device.client.deviceReference)
                        return
                    default: break
                    }
                }
                if !Task.isCancelled { await self?.streamEnded(id, reason: .linkLoss) }
            } catch {
                if !Task.isCancelled { await self?.streamEnded(id, reason: .error(error.localizedDescription)) }
            }
        }
        // Both commands acknowledged on 0E6F:0194 hardware, 2026-11-01.
        // Keep simple-report decoding available during initialization.
        do {
            for command in AfterglowBluetoothCommands.initialize(player: slot) {
                try await device.client.dispatchSetReportRequest(type: .output,
                    id: HIDReportID(rawValue: 0x01), data: command, timeout: .seconds(1))
            }
        } catch {
            continuation.yield(.error(id, "Bluetooth controller initialization failed: \(error.localizedDescription)"))
        }
        guard reportTasks[id] != nil, devices[id]?.client == device.client else { return }
        continuation.yield(.ready(id))
    }

    func disconnect(_ id: DeviceID) async { streamEnded(id, reason: .userInitiated) }

    func send(_ payload: Data, reportID: UInt8?, to id: DeviceID) async throws {
        guard let device = devices[id] else { throw BluetoothHIDTransportError.unknownDevice }
        try await device.client.dispatchSetReportRequest(type: .output,
            id: reportID.flatMap { HIDReportID(rawValue: $0) }, data: payload, timeout: .seconds(1))
    }

    private func removed(_ reference: HIDDeviceClient.DeviceReference) {
        guard let id = referenceIDs.removeValue(forKey: reference),
              devices[id]?.client.deviceReference == reference else { return }
        devices[id] = nil
        streamEnded(id, reason: .linkLoss)
    }

    private func streamEnded(_ id: DeviceID, reason: DisconnectReason) {
        playerSlots[id] = nil
        guard let task = reportTasks.removeValue(forKey: id) else { return }
        task.cancel()
        continuation.yield(.disconnected(id, reason))
    }

    private func discoveryFailed(_ message: String) {
        discoveryTask = nil
        continuation.yield(.availability(reason: "Bluetooth HID discovery failed: \(message)"))
    }
}
