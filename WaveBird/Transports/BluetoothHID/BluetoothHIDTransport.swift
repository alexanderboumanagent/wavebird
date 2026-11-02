import CoreHID
import Foundation

enum BluetoothHIDTransportError: Error, LocalizedError, CustomStringConvertible {
    case unknownDevice
    case fourControllersAlreadyConnected
    case exclusiveAccessFailed(String)

    var description: String {
        switch self {
        case .unknownDevice: "Bluetooth HID device is unavailable."
        case .fourControllersAlreadyConnected: "Four Bluetooth controllers are already connected."
        case .exclusiveAccessFailed(let reason):
            "Could not take exclusive ownership of the Bluetooth controller. Close other controller apps and reconnect. \(reason)"
        }
    }

    var errorDescription: String? { description }
}

actor BluetoothHIDTransport: Transport {
    nonisolated let kind: TransportKind = .bluetoothHID
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private let seizeDevices: Bool
    private let manager = HIDDeviceManager()
    private var pairer: BluetoothClassicPairer?
    private var pairingStartupTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var reportTasks: [DeviceID: Task<Void, Never>] = [:]
    private var devices: [DeviceID: Device] = [:]
    private var referenceIDs: [HIDDeviceClient.DeviceReference: DeviceID] = [:]
    private var identityIDs: [String: DeviceID] = [:]
    private var playerSlots: [DeviceID: Int] = [:]
    private var pendingInitializations: [DeviceID: PendingInitialization] = [:]

    private struct PendingInitialization {
        let token: UUID
        let command: Data
        let result: CheckedContinuation<Bool, Never>
    }

    private struct Device: Sendable {
        let client: HIDDeviceClient
        let identity: String
        let address: String?
        var hasExclusiveAccess = false
    }

    init(seizeDevices: Bool = false) {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .bufferingNewest(256))
        events = stream
        self.continuation = continuation
        self.seizeDevices = seizeDevices
    }

    deinit {
        discoveryTask?.cancel()
        pairingStartupTask?.cancel()
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
        // Already-paired HID devices must not wait for legacy discovery's
        // first-use authorization/initialization before they can send input.
        if let pairer {
            await pairer.start(matchers: matchers)
        } else {
            let continuation = continuation
            pairingStartupTask = Task { [weak self] in
                await BluetoothClassicPairer.prepareRuntime()
                guard !Task.isCancelled else { return }
                let pairer = await BluetoothClassicPairer(events: continuation)
                await self?.startPairer(pairer, matchers: matchers)
            }
        }
    }

    private func startPairer(_ pairer: BluetoothClassicPairer, matchers: [BluetoothHIDMatcher]) async {
        guard discoveryTask != nil, !Task.isCancelled else { await pairer.stop(); return }
        self.pairer = pairer
        await pairer.start(matchers: matchers)
    }

    func stopDiscovery() async {
        discoveryTask?.cancel()
        discoveryTask = nil
        pairingStartupTask?.cancel()
        pairingStartupTask = nil
        await pairer?.stop()
    }

    private func matched(_ reference: HIDDeviceClient.DeviceReference, matchers: [BluetoothHIDMatcher]) async {
        guard let client = HIDDeviceClient(deviceReference: reference) else { return }
        let vendor = UInt16(clamping: await client.vendorID)
        let product = UInt16(clamping: await client.productID)
        let serial = await client.serialNumber
        let uniqueID = await client.uniqueID
        guard matchers.contains(where: { $0.matches(vendorID: vendor, productID: product) }),
              let identity = BluetoothHIDMatcher.persistentIdentity(
                vendorID: vendor, productID: product,
                serial: serial, uniqueID: uniqueID
              ), !Task.isCancelled else { return }
        let id = identityIDs[identity] ?? DeviceID(transport: .bluetoothHID, raw: UUID())
        identityIDs[identity] = id
        if let previous = devices[id], previous.client.deviceReference != reference {
            streamEnded(id, reason: .linkLoss)
            referenceIDs[previous.client.deviceReference] = nil
        }
        devices[id] = Device(client: client, identity: identity, address: serial ?? uniqueID)
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
        if seizeDevices, !device.hasExclusiveAccess {
            // Apple requires seizing before any outstanding monitor or report
            // requests. Ownership lasts until this HIDDeviceClient deinitializes.
            // https://developer.apple.com/documentation/corehid/hiddeviceclient/seizedevice()
            do {
                try await device.client.seizeDevice()
            } catch {
                playerSlots[id] = nil
                throw BluetoothHIDTransportError.exclusiveAccessFailed(error.localizedDescription)
            }
            guard devices[id]?.client == device.client else {
                playerSlots[id] = nil
                throw BluetoothHIDTransportError.unknownDevice
            }
            devices[id]?.hasExclusiveAccess = true
        }
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
                        if reportID?.rawValue == 0x21 { await self?.receivedAcknowledgement(data, for: id) }
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
        // SDL's HIDAPI_DriverSwitch_OpenJoystick waits for macOS to finish
        // its own handshake before sending Switch subcommands.
        try? await Task.sleep(for: .milliseconds(250))
        for command in AfterglowBluetoothCommands.initialize(player: slot) {
            guard reportTasks[id] != nil else { return }
            if !(await initialize(command, device: device, id: id)) {
                continuation.yield(.error(id, "Bluetooth controller did not acknowledge initialization; simple input remains available."))
            }
        }
        guard reportTasks[id] != nil, devices[id]?.client == device.client else { return }
        continuation.yield(.ready(id))
    }

    func disconnect(_ id: DeviceID) async {
        let address = devices[id]?.address
        stopInputSubscription(id)
        if let address { await BluetoothClassicPairer.disconnect(address: address) }
    }

    // Used by the hardware probe to test report-subscription lifetime without
    // pretending that a controller was powered off or its radio link was lost.
    func stopInputSubscription(_ id: DeviceID) { streamEnded(id, reason: .userInitiated) }

    private func initialize(_ command: Data, device: Device, id: DeviceID) async -> Bool {
        let token = UUID()
        return await withCheckedContinuation { result in
            pendingInitializations[id] = PendingInitialization(token: token, command: command, result: result)
            Task { [weak self] in
                do {
                    try await device.client.dispatchSetReportRequest(type: .output,
                        id: HIDReportID(rawValue: 1), data: command, timeout: .seconds(1))
                } catch {
                    await self?.completeInitialization(id, token: token, acknowledged: false)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.completeInitialization(id, token: token, acknowledged: false)
            }
        }
    }

    private func receivedAcknowledgement(_ data: Data, for id: DeviceID) {
        guard let pending = pendingInitializations[id],
              let acknowledged = AfterglowBluetoothCommands.acknowledgement(data, for: pending.command) else { return }
        completeInitialization(id, token: pending.token, acknowledged: acknowledged)
    }

    private func completeInitialization(_ id: DeviceID, token: UUID, acknowledged: Bool) {
        guard let pending = pendingInitializations[id], pending.token == token else { return }
        pendingInitializations[id] = nil
        pending.result.resume(returning: acknowledged)
    }

    func send(_ payload: Data, reportID: UInt8?, to id: DeviceID) async throws {
        guard let device = devices[id] else { throw BluetoothHIDTransportError.unknownDevice }
        guard !seizeDevices || device.hasExclusiveAccess else {
            throw BluetoothHIDTransportError.exclusiveAccessFailed("The device has not been acquired exclusively.")
        }
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
        if let pending = pendingInitializations.removeValue(forKey: id) { pending.result.resume(returning: false) }
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
