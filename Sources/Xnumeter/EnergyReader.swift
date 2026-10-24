import CoreFoundation
import Foundation

/// GPU power draw derived from the IOReport `Energy Model` energy counter, ported from heatpeek.
///
/// On Apple Silicon only the GPU Energy channel advances while polling; CPU/ANE/DRAM
/// counters stay static, so this exposes GPU power only.
final class EnergyReader {
    enum Reading {
        case pending
        case watts(Double)
        case unavailable(reason: String)
    }

    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeRawPointer?, CFMutableDictionary?, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?
    ) -> Unmanaged<AnyObject>?
    private typealias CreateSamples = @convention(c) (UnsafeRawPointer?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    private typealias ChannelInteger = @convention(c) (CFDictionary?, Int32) -> Int64

    private struct Bindings {
        let copyChannels: CopyChannels
        let createSubscription: CreateSubscription
        let createSamples: CreateSamples
        let channelName: ChannelString
        let unitLabel: ChannelString
        let integerValue: ChannelInteger

        init?() {
            guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
            func bind<T>(_ name: String, _ type: T.Type) -> T? {
                guard let symbol = dlsym(handle, name) else { return nil }
                return unsafeBitCast(symbol, to: T.self)
            }
            guard
                let copyChannels = bind("IOReportCopyChannelsInGroup", CopyChannels.self),
                let createSubscription = bind("IOReportCreateSubscription", CreateSubscription.self),
                let createSamples = bind("IOReportCreateSamples", CreateSamples.self),
                let channelName = bind("IOReportChannelGetChannelName", ChannelString.self),
                let unitLabel = bind("IOReportChannelGetUnitLabel", ChannelString.self),
                let integerValue = bind("IOReportSimpleGetIntegerValue", ChannelInteger.self)
            else {
                return nil
            }
            self.copyChannels = copyChannels
            self.createSubscription = createSubscription
            self.createSamples = createSamples
            self.channelName = channelName
            self.unitLabel = unitLabel
            self.integerValue = integerValue
        }
    }

    private static let channelSuffix = "GPU Energy"
    private static let minimumElapsed: TimeInterval = 0.25

    private let bindings: Bindings?
    private var subscription: AnyObject?
    private var subscriptionPointer: UnsafeMutableRawPointer?
    private var channels: CFMutableDictionary?
    private var previous: (value: Int64, at: Date)?
    private(set) var status: Status

    enum Status: Equatable {
        case ready
        case unavailable(reason: String)
    }

    init() {
        bindings = Bindings()
        status = .unavailable(reason: "not initialized")

        guard let bindings else {
            status = .unavailable(reason: "libIOReport not loadable")
            return
        }
        guard let discovered = bindings.copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(discovered), discovered)
        else {
            status = .unavailable(reason: "no Energy Model channels")
            return
        }

        var initial: Unmanaged<CFMutableDictionary>?
        guard let handle = bindings.createSubscription(nil, mutable, &initial, 0, nil)?.takeRetainedValue() else {
            status = .unavailable(reason: "IOReportCreateSubscription failed")
            return
        }
        initial?.release()

        channels = mutable
        subscription = handle
        subscriptionPointer = Unmanaged.passUnretained(handle).toOpaque()
        status = .ready
    }

    var isReady: Bool { status == .ready }

    func read(now: Date = .now) -> Reading {
        guard let bindings, let channels, let subscriptionPointer else {
            if case let .unavailable(reason) = status { return .unavailable(reason: reason) }
            return .unavailable(reason: "not subscribed")
        }
        guard let sample = bindings.createSamples(subscriptionPointer, channels, nil)?.takeRetainedValue(),
              let dictionary = sample as? [String: Any],
              let array = dictionary["IOReportChannels"] as? NSArray
        else {
            return .unavailable(reason: "IOReportCreateSamples returned no channels")
        }

        let entries = array as CFArray
        var current: (value: Int64, unit: String)?
        for index in 0..<CFArrayGetCount(entries) {
            guard let pointer = CFArrayGetValueAtIndex(entries, index) else { continue }
            let channel = Unmanaged<CFDictionary>.fromOpaque(pointer).takeUnretainedValue()
            guard let name = bindings.channelName(channel)?.takeUnretainedValue() as String?,
                  name.hasSuffix(Self.channelSuffix)
            else { continue }
            current = (bindings.integerValue(channel, 0), (bindings.unitLabel(channel)?.takeUnretainedValue() as String?) ?? "nJ")
            break
        }
        guard let current else { return .unavailable(reason: "no \(Self.channelSuffix) channel") }

        defer { previous = (current.value, now) }
        guard let previous else { return .pending }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed >= Self.minimumElapsed else { return .pending }

        let joules = Double(current.value - previous.0) * Self.scale(of: current.unit)
        guard joules >= 0 else { return .pending }
        return .watts(joules / elapsed)
    }

    private static func scale(of unit: String) -> Double {
        switch unit {
        case "nJ": return 1e-9
        case "uJ": return 1e-6
        case "mJ": return 1e-3
        case "J": return 1
        default: return 1e-9
        }
    }
}