import Foundation

enum Format {
    static func bytes(_ raw: Double) -> String {
        if raw < 1 { return "0" }
        let units = ["K", "M", "G", "T", "P"]
        var v = raw
        var i = -1
        while v >= 1024, i + 1 < units.count {
            v /= 1024
            i += 1
        }
        return i < 0 ? String(format: "%.0fB", v) : String(format: "%.1f%@", v, units[i])
    }

    static func rate(_ bytesPerSec: Double) -> String {
        bytesPerSec < 1 ? "-" : bytes(bytesPerSec) + "/s"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%5.1f%%", value)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        return days > 0 ? "\(days)d\(hours)h" : String(format: "%dh%02dm", hours, minutes)
    }

    static func bar(_ percent: Double, width: Int) -> String {
        guard width > 1 else { return "" }
        let filled = Int((Swift.max(0, Swift.min(100, percent)) / 100 * Double(width)).rounded())
        return String(repeating: "#", count: filled) + String(repeating: ".", count: width - filled)
    }

    /// Pads to `width`, marking truncation with a trailing tilde.
    static func column(_ text: String, _ width: Int) -> String {
        if text.count > width { return String(text.prefix(Swift.max(1, width - 1))) + "~" }
        return text + String(repeating: " ", count: width - text.count)
    }
}
