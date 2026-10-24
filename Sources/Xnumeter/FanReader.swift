import Foundation
import IOKit

/// Fan speed from the AppleSMC user client, ported from heatpeek.
///
/// Reading SMC keys needs no root; only writing them (fan control) would.
final class FanReader {
    private static let candidates = ["F0Ac", "F1Ac", "F2Ac", "F3Ac", "F4Ac", "F5Ac"]

    private var connection: io_connect_t = 0
    private let failureReason: String?

    init() {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("AppleSMC") else {
            failureReason = "IOServiceMatching(AppleSMC) failed"
            return
        }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            failureReason = "no AppleSMC service"
            return
        }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            failureReason = "no AppleSMC service"
            return
        }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            failureReason = "IOServiceOpen(AppleSMC) failed"
            return
        }
        failureReason = nil
    }

    func read() -> [FanReading] {
        if failureReason != nil {
            return []
        }
        var fans: [FanReading] = []
        for (index, key) in Self.candidates.enumerated() {
            guard let value = readValue(key) else { continue }
            fans.append(FanReading(name: "Fan \(index + 1)", rpm: value))
        }
        return fans
    }

    func reasonIfUnavailable() -> String? { failureReason }

    private func readValue(_ key: String) -> Double? {
        guard let (type, bytes) = readKey(key) else { return nil }
        let value: Double?
        switch type {
        case "flt ", "sp1f":
            // AppleSMC publishes `flt ` little-endian on both Apple Silicon and Intel.
            guard bytes.count >= 4 else { return nil }
            value = Double(Float(bitPattern: bytes.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian))
        case "fpe2", "fp2e":
            guard bytes.count >= 2 else { return nil }
            value = Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        case "ui8", "ui16", "ui32":
            value = Double(bytes.reduce(0) { ($0 << 8) | Int($1) })
        default:
            value = nil
        }
        guard let value, (0...15_000).contains(value) else { return nil }
        return value
    }

    private struct KeyData {
        var key: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var keyInfo: (IOByteCount32, UInt32, UInt8) = (0, 0, 0)
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static func fourCharCode(_ string: String) -> UInt32 {
        guard string.utf8.count == 4 else { return 0 }
        return string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func typeString(_ raw: UInt32) -> String {
        let bytes = [UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff), UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        return String(bytes: bytes.filter { $0 != 0 }, encoding: .ascii) ?? "?"
    }

    private func call(_ input: inout KeyData, _ output: inout KeyData) -> kern_return_t {
        var size = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
    }

    private func readKey(_ key: String) -> (String, [UInt8])? {
        guard !key.isEmpty else { return nil }
        var input = KeyData()
        var output = KeyData()
        input.key = Self.fourCharCode(key)
        input.data8 = 9 // readKeyInfo
        guard call(&input, &output) == KERN_SUCCESS, output.result == 0 else { return nil }
        let size = Int(output.keyInfo.0)
        guard size > 0, size <= 32 else { return nil }
        let type = Self.typeString(output.keyInfo.1)

        var reader = KeyData()
        var data = KeyData()
        reader.key = input.key
        reader.keyInfo.0 = IOByteCount32(size)
        reader.data8 = 5 // readBytes
        guard call(&reader, &data) == KERN_SUCCESS, data.result == 0 else { return nil }
        let all = withUnsafeBytes(of: data.bytes) { Array($0) }
        return (type, Array(all.prefix(size)))
    }
}