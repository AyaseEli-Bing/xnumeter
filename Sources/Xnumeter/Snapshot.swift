import Foundation

struct CpuSample: Codable {
    var totalPercent: Double = 0
    var userPercent: Double = 0
    var systemPercent: Double = 0
    var nicePercent: Double = 0
    var coreCount: Int = 0
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
}

struct MemSample: Codable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var purgeableBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var percent: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) * 100
    }
}

struct DiskSample: Codable, Identifiable {
    var id: String { mount }
    var mount: String
    var name: String
    var totalBytes: UInt64
    var freeBytes: UInt64
    var percent: Double {
        totalBytes == 0 ? 0 : Double(totalBytes - freeBytes) / Double(totalBytes) * 100
    }
}

struct NetSample: Codable, Identifiable {
    var id: String { name }
    var name: String
    var rxBytes: UInt64
    var txBytes: UInt64
    var rxBytesPerSec: Double
    var txBytesPerSec: Double
}

struct ProcSample: Codable, Identifiable {
    var id: Int { Int(pid) }
    var pid: Int32
    var name: String
    var cpuPercent: Double
    var rssBytes: UInt64
    var footprintBytes: UInt64
    var diskReadBytesPerSec: Double
    var diskWriteBytesPerSec: Double
}

struct TemperatureReading: Codable {
    var sensor: String
    var celsius: Double
}

struct FanReading: Codable, Identifiable {
    var id: String { name }
    var name: String
    var rpm: Double
}

/// Apple Silicon sensor readings, merged from heatpeek.
struct SensorSample: Codable {
    var temperatures: [TemperatureReading] = []
    var gpuUtilizationPercent: Double?
    var gpuPowerWatts: Double?
    var fans: [FanReading] = []
    var unavailable: [String: String] = [:]

    var maxTemperature: TemperatureReading? {
        temperatures.max { $0.celsius < $1.celsius }
    }

    var maxTemperatureCelsius: Double? { maxTemperature?.celsius }

    var averageTemperatureCelsius: Double? {
        guard !temperatures.isEmpty else { return nil }
        return temperatures.map(\.celsius).reduce(0, +) / Double(temperatures.count)
    }

    var maxFanRPM: Double? { fans.map(\.rpm).max() }

    private enum CodingKeys: String, CodingKey {
        case temperatures, gpuUtilizationPercent, gpuPowerWatts, fans, unavailable
    }

    /// Keep every key present, as null when a source is unavailable, so the JSON
    /// shape does not depend on the hardware.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(temperatures, forKey: .temperatures)
        try container.encode(gpuUtilizationPercent, forKey: .gpuUtilizationPercent)
        try container.encode(gpuPowerWatts, forKey: .gpuPowerWatts)
        try container.encode(fans, forKey: .fans)
        try container.encode(unavailable, forKey: .unavailable)
    }
}

struct Snapshot: Codable {
    var timestampMs: Int64
    var hostName: String
    var uptimeSeconds: Double
    var cpu: CpuSample
    var mem: MemSample
    var disks: [DiskSample]
    var net: [NetSample]
    var processes: [ProcSample]
    var sensors: SensorSample = SensorSample()
}

enum SortKey: String, Codable {
    case cpu
    case mem
}
