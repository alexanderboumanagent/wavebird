import CoreHID
import Foundation

enum USBTransportError: Error {
    case unknownDevice
}

// CoreHID owns discovery, report buffers and device lifetime. Using its
// Sendable actors keeps raw IOKit pointers out of the transport pipeline.
actor USBTransport: Transport {
    nonisolated let kind: TransportKind = .usb
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private let manager = HIDDeviceManager()
    private var discoveryTask: Task<Void, Never>?
    private var reportTasks: [DeviceID: Task<Void, Never>] = [:]
    private var devices: [DeviceID: Device] = [:]
    private var referenceIDs: [HIDDeviceClient.DeviceReference: DeviceID] = [:]
    private var identityIDs: [String: DeviceID] = [:]

    private struct Device: Sendable {
        let client: HIDDeviceClient
        let matcher: USBMatcher
        let identity: String
    }

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TransportEvent.self, bufferingPolicy: .bufferingNewest(64)
        )
        events = stream
        self.continuation = continuation
    }

    deinit {
        discoveryTask?.cancel()
        for task in reportTasks.values { task.cancel() }
        continuation.finish()
    }

    func startDiscovery(matchers: [TransportMatcher]) async {
        guard discoveryTask == nil else { return }
        let usbMatchers = matchers.compactMap { matcher -> USBMatcher? in
            if case .usb(let usb) = matcher { return usb }
            return nil
        }
        guard !usbMatchers.isEmpty else { return }
        let criteria = usbMatchers.map {
            HIDDeviceManager.DeviceMatchingCriteria(
                primaryUsage: .genericDesktop(.gamepad),
                vendorID: UInt32($0.vendorID), productID: UInt32($0.productID), transport: .usb
            )
        }
        let manager = manager
        discoveryTask = Task { [weak self] in
            do {
                for try await notification in await manager.monitorNotifications(matchingCriteria: criteria) {
                    guard !Task.isCancelled else { return }
                    switch notification {
                    case .deviceMatched(let reference):
                        await self?.matched(reference, matchers: usbMatchers)
                    case .deviceRemoved(let reference):
                        await self?.removed(reference)
                    @unknown default: break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await self?.discoveryFailed(error.localizedDescription)
                }
            }
        }
    }

    func stopDiscovery() async {
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    private func matched(_ reference: HIDDeviceClient.DeviceReference, matchers: [USBMatcher]) async {
        guard let client = HIDDeviceClient(deviceReference: reference) else { return }
        let vendorID = UInt16(clamping: await client.vendorID)
        let productID = UInt16(clamping: await client.productID)
        guard let matcher = matchers.first(where: { $0.matches(vendorID: vendorID, productID: productID) }) else { return }
        let identity = USBMatcher.persistentIdentity(
            vendorID: matcher.vendorID, productID: matcher.productID,
            serial: await client.serialNumber, locationID: await client.locationID,
            fallbackID: reference.deviceID
        )
        guard !Task.isCancelled else { return }
        let id = identityIDs[identity] ?? DeviceID(transport: .usb, raw: UUID())
        identityIDs[identity] = id
        if reportTasks[id] != nil { return }
        devices[id] = Device(client: client, matcher: matcher, identity: identity)
        referenceIDs[reference] = id
        continuation.yield(.availability(reason: nil))
        continuation.yield(.discovered(id, AdvertisementInfo(
            vendorID: matcher.vendorID, productID: matcher.productID,
            localName: await client.product, rssi: nil
        )))
    }

    func connect(_ id: DeviceID) async throws {
        guard let device = devices[id] else { throw USBTransportError.unknownDevice }
        guard reportTasks[id] == nil else { return }
        continuation.yield(.connecting(id))
        for step in device.matcher.initWrites {
            try await device.client.dispatchSetReportRequest(
                type: .output, id: step.reportID == 0 ? nil : HIDReportID(rawValue: step.reportID),
                data: step.payload, timeout: .seconds(1)
            )
        }
        let notifications = await device.client.monitorNotifications(
            reportIDsToMonitor: [HIDReportID.allReports], elementsToMonitor: []
        )
        guard devices[id]?.client == device.client else { throw USBTransportError.unknownDevice }
        continuation.yield(.connected(id))
        continuation.yield(.metadata(id, ControllerMetadata(serial: device.identity)))
        continuation.yield(.ready(id))
        let continuation = continuation
        reportTasks[id] = Task { [weak self] in
            do {
                for try await notification in notifications {
                    guard !Task.isCancelled else { return }
                    switch notification {
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
    }

    func disconnect(_ id: DeviceID) async {
        streamEnded(id, reason: .userInitiated)
    }

    func send(_ payload: Data, reportID: UInt8?, to id: DeviceID) async throws {
        guard let device = devices[id] else { throw USBTransportError.unknownDevice }
        try await device.client.dispatchSetReportRequest(
            type: .output, id: reportID.flatMap { $0 == 0 ? nil : HIDReportID(rawValue: $0) },
            data: payload, timeout: .seconds(1)
        )
    }

    private func removed(_ reference: HIDDeviceClient.DeviceReference) {
        guard let id = referenceIDs.removeValue(forKey: reference),
              devices[id]?.client.deviceReference == reference else { return }
        devices[id] = nil
        streamEnded(id, reason: .linkLoss)
    }

    private func streamEnded(_ id: DeviceID, reason: DisconnectReason) {
        guard let task = reportTasks.removeValue(forKey: id) else { return }
        task.cancel()
        continuation.yield(.disconnected(id, reason))
    }

    private func discoveryFailed(_ reason: String) {
        discoveryTask = nil
        continuation.yield(.availability(reason: "USB controller discovery failed: \(reason)"))
    }
}
