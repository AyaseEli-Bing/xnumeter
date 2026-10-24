import Foundation

/// Reuses a value for up to `cadence` seconds.
struct SampleCache<Value> {
    let cadence: TimeInterval
    private var stored: Value?
    private var storedAt: Date?

    init(cadence: TimeInterval) {
        self.cadence = cadence
    }

    func cached(at now: Date) -> Value? {
        guard let stored, let storedAt, now.timeIntervalSince(storedAt) < cadence else { return nil }
        return stored
    }

    mutating func store(_ value: Value, at now: Date) {
        stored = value
        storedAt = now
    }
}

/// Combines the heatpeek sensor readers into one sample.
///
/// A full HID temperature sweep costs ~50 ms, so temperature is cached for 5 s.
/// GPU/fan/power refresh at most every 0.4 s, which still gives the `--once`
/// second sample time to compute GPU power while keeping fast TUI intervals cheap.
final class SensorSampler {
    private static let temperatureCadence: TimeInterval = 5
    private static let refreshCadence: TimeInterval = 0.4
    private static let warnCelsius: Double = 85

    private let temperatureReader = TemperatureReader()
    private let energyReader = EnergyReader()
    private let fanReader = FanReader()
    private var temperatureCache = SampleCache<[TemperatureReading]>(cadence: temperatureCadence)
    private var cachedSample: SensorSample?
    private var cachedAt: Date?

    func sample(now: Date = Date()) -> SensorSample {
        if let cachedSample, let cachedAt, now.timeIntervalSince(cachedAt) < Self.refreshCadence {
            return cachedSample
        }

        var unavailable: [String: String] = [:]

        let readings: [TemperatureReading]
        if let cached = temperatureCache.cached(at: now) {
            readings = cached
        } else {
            readings = temperatureReader.read()
            temperatureCache.store(readings, at: now)
        }
        if readings.isEmpty {
            unavailable["temperature"] = temperatureReader.reasonIfUnavailable() ?? "no HID temperature services"
        }

        let gpu = GPUReader.read()
        if gpu == nil {
            unavailable["gpu"] = "IOAccelerator PerformanceStatistics unavailable"
        }

        var watts: Double?
        switch energyReader.read(now: now) {
        case let .watts(value):
            watts = value
        case let .unavailable(reason):
            unavailable["power"] = reason
        case .pending:
            break
        }

        let fans = fanReader.read()
        if fans.isEmpty {
            unavailable["fan"] = fanReader.reasonIfUnavailable() ?? "no SMC fan keys"
        }

        let sample = SensorSample(
            temperatures: readings,
            gpuUtilizationPercent: gpu?.percent,
            gpuPowerWatts: watts,
            fans: fans,
            unavailable: unavailable
        )
        cachedSample = sample
        cachedAt = now
        return sample
    }

    var isHot: Bool {
        (cachedSample?.maxTemperatureCelsius ?? 0) >= Self.warnCelsius
    }
}