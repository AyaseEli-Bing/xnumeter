import CoreFoundation
import Foundation

/// SoC temperature via the IOKit HID event system, ported from heatpeek.
///
/// The `IOHIDEventSystemClient*` entry points have no public header, so they are
/// resolved at runtime rather than through a bridging header.
final class TemperatureReader {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (UnsafeRawPointer?, CFDictionary?) -> Int32
    private typealias CopyServices = @convention(c) (UnsafeRawPointer?) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (UnsafeRawPointer?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias CopyProperty = @convention(c) (UnsafeRawPointer?, CFString?) -> Unmanaged<AnyObject>?
    private typealias EventFloat = @convention(c) (UnsafeRawPointer?, Int32) -> Double

    private struct Bindings {
        let create: Create
        let setMatching: SetMatching
        let copyServices: CopyServices
        let copyEvent: CopyEvent
        let copyProperty: CopyProperty
        let eventFloat: EventFloat

        init?() {
            guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
                return nil
            }
            func bind<T>(_ name: String, _ type: T.Type) -> T? {
                guard let symbol = dlsym(handle, name) else { return nil }
                return unsafeBitCast(symbol, to: T.self)
            }
            guard
                let create = bind("IOHIDEventSystemClientCreate", Create.self),
                let setMatching = bind("IOHIDEventSystemClientSetMatching", SetMatching.self),
                let copyServices = bind("IOHIDEventSystemClientCopyServices", CopyServices.self),
                let copyEvent = bind("IOHIDServiceClientCopyEvent", CopyEvent.self),
                let copyProperty = bind("IOHIDServiceClientCopyProperty", CopyProperty.self),
                let eventFloat = bind("IOHIDEventGetFloatValue", EventFloat.self)
            else {
                return nil
            }
            self.create = create
            self.setMatching = setMatching
            self.copyServices = copyServices
            self.copyEvent = copyEvent
            self.copyProperty = copyProperty
            self.eventFloat = eventFloat
        }
    }

    private static let temperatureEvent = 15
    private static let usagePage = Int32(0xff00)
    private static let usage = Int32(0x0005)
    private static let rediscoveryInterval: TimeInterval = 60
    private static let rediscoveryAfterGap: TimeInterval = 5
    private static let plausibleRange = 5.0...110.0

    private let bindings: Bindings?
    let failureReason: String?
    private var client: AnyObject?
    private var clientPointer: UnsafeMutableRawPointer?
    private var services: CFArray?
    private var discoveredAt: Date?
    private var gapSeen = false

    init() {
        if let bindings = Bindings() {
            self.bindings = bindings
            self.failureReason = nil
        } else {
            self.bindings = nil
            self.failureReason = "IOKit HID symbols unavailable"
        }
    }

    func read() -> [TemperatureReading] {
        guard let bindings else { return [] }
        let now = Date()
        if needsRediscovery(now: now) {
            discover(bindings: bindings, now: now)
        }
        guard let services else { return [] }

        var readings: [TemperatureReading] = []
        var missing = 0
        let count = CFArrayGetCount(services)
        for index in 0..<count {
            guard let service = CFArrayGetValueAtIndex(services, index) else { continue }
            let name = Self.productName(bindings: bindings, service: service, fallback: "sensor\(index)")
            guard let event = bindings.copyEvent(service, Int64(Self.temperatureEvent), 0, 0)?.takeRetainedValue()
            else {
                missing += 1
                continue
            }
            let value = bindings.eventFloat(Unmanaged.passUnretained(event).toOpaque(), Int32(Self.temperatureEvent << 16))
            if Self.plausibleRange.contains(value) {
                readings.append(TemperatureReading(sensor: name, celsius: value))
            }
        }
        if missing > 0 {
            gapSeen = true
        }
        return readings
    }

    private func needsRediscovery(now: Date) -> Bool {
        guard let discoveredAt else { return true }
        let interval = gapSeen ? Self.rediscoveryAfterGap : Self.rediscoveryInterval
        return now.timeIntervalSince(discoveredAt) >= interval
    }

    private func discover(bindings: Bindings, now: Date) {
        if client == nil {
            guard let ref = bindings.create(kCFAllocatorDefault)?.takeRetainedValue() else {
                return
            }
            client = ref
            clientPointer = Unmanaged.passUnretained(ref).toOpaque()
            _ = bindings.setMatching(
                clientPointer,
                ["PrimaryUsagePage": Self.usagePage, "PrimaryUsage": Self.usage] as CFDictionary
            )
        }
        guard let clientPointer else { return }
        services = bindings.copyServices(clientPointer)?.takeRetainedValue()
        discoveredAt = now
        gapSeen = false
    }

    private static func productName(bindings: Bindings, service: UnsafeRawPointer, fallback: String) -> String {
        guard let property = bindings.copyProperty(service, "Product" as CFString)?.takeRetainedValue() else {
            return fallback
        }
        return (property as? String) ?? fallback
    }

    func reasonIfUnavailable() -> String? {
        guard bindings == nil else { return nil }
        return failureReason
    }
}