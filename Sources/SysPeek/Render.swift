import Foundation

struct ViewOptions {
    var width: Int = 80
    var height: Int = 24
    var sort: SortKey = .cpu
    var scroll: Int = 0
    var color: Bool = true
    var showIo: Bool = true

    /// The disk read/write columns are dropped on narrow terminals rather than wrapped.
    var ioColumns: Bool { showIo && width >= 96 }
}

final class Renderer {
    private let color: Bool

    init(color: Bool) {
        self.color = color
    }

    func lines(_ snapshot: Snapshot, _ options: ViewOptions) -> [String] {
        let width = Swift.max(60, options.width)
        var out: [String] = [headerLine(snapshot, width), dim(String(repeating: "-", count: width))]

        let cpu = snapshot.cpu
        out.append(gauge("CPU", cpu.totalPercent, "user \(trim(cpu.userPercent)) sys \(trim(cpu.systemPercent))  load \(fmt(cpu.load1)) \(fmt(cpu.load5)) \(fmt(cpu.load15))  \(cpu.coreCount) cores", width))

        let mem = snapshot.mem
        out.append(gauge("MEM", mem.percent, "\(bytes(mem.usedBytes))/\(bytes(mem.totalBytes))  wired \(bytes(mem.wiredBytes))  comp \(bytes(mem.compressedBytes))  purge \(bytes(mem.purgeableBytes))", width))

        let swapPercent = mem.swapTotalBytes > 0 ? Double(mem.swapUsedBytes) / Double(mem.swapTotalBytes) * 100 : 0
        out.append(gauge("SWAP", swapPercent, "\(bytes(mem.swapUsedBytes))/\(bytes(mem.swapTotalBytes))", width))

        for disk in snapshot.disks.prefix(4) {
            out.append(gauge("DISK", disk.percent, "\(disk.mount)  \(bytes(disk.totalBytes - disk.freeBytes))/\(bytes(disk.totalBytes))  free \(bytes(disk.freeBytes))", width))
        }

        for net in snapshot.net.prefix(3) {
            out.append(netLine(net, width))
        }

        out.append("")
        out.append(processHeader(options))
        // +1 for the footer, which the caller appends after these lines.
        let window = visibleRows(options, total: snapshot.processes.count, overhead: out.count + 1)
        if window.isEmpty {
            out.append(dim("  first frame primes cumulative counters; rates appear on the next one"))
        }
        for proc in snapshot.processes[window] {
            out.append(processRow(proc, options))
        }
        return out
    }

    // MARK: - Pieces

    private func headerLine(_ snapshot: Snapshot, _ width: Int) -> String {
        let right = clockString(snapshot.timestampMs)
        let left = "syspeek  \(snapshot.hostName)  up \(Format.duration(snapshot.uptimeSeconds))"
        let allowed = Swift.max(8, width - right.count - 1)
        let head = left.count > allowed ? String(left.prefix(allowed - 1)) + "~" : left
        return bold(head + String(repeating: " ", count: Swift.max(1, width - head.count - right.count)) + right)
    }

    private func gauge(_ label: String, _ percent: Double, _ detail: String, _ width: Int) -> String {
        let pct = colored(Format.percent(percent), percent)
        let bar = colored(Format.bar(percent, width: barWidth(width)), percent)
        // "LABEL" + space + "99.9%" + " [" + bar + "]  "
        let budget = width - 16 - barWidth(width)
        let tail = detail.count > budget ? String(detail.prefix(Swift.max(1, budget - 3))) + "..." : detail
        return Format.column(label, 4) + " " + pct + " [" + bar + "]  " + tail
    }

    /// No bar: only the physical NIC reports a link speed, so a utilisation figure for
    /// a tunnel would be invented. Rate slots are 9 wide, the longest `Format.rate` emits.
    private func netLine(_ net: NetSample, _ width: Int) -> String {
        let head = Format.column("NET", 4) + " " + Format.column(net.name, 8) + " "
        var detail = "rx " + Format.column(Format.rate(net.rxBytesPerSec), 9)
            + " tx " + Format.column(Format.rate(net.txBytesPerSec), 9)
            + " total rx " + bytes(net.rxBytes) + " tx " + bytes(net.txBytes)
        let budget = width - head.count
        if detail.count > budget { detail = String(detail.prefix(Swift.max(1, budget - 3))) + "..." }
        return head + detail
    }

    private func barWidth(_ width: Int) -> Int {
        switch width {
        case ..<90: return 14
        case ..<110: return 20
        default: return 26
        }
    }

    func footer(sort: SortKey, rows: Int, width: Int) -> String {
        var parts = ["sort: \(sort.rawValue)", "q quit", "s sort", "up/down scroll", "\(rows) rows"]
        while parts.count > 1, parts.joined(separator: "   ").count > width {
            parts.removeLast()
        }
        return dim(parts.joined(separator: "   "))
    }

    private func processHeader(_ options: ViewOptions) -> String {
        var cols = ["PID", "NAME", "CPU%", "RSS", "FOOT"]
        if options.ioColumns { cols.append("DISK-R"); cols.append("DISK-W") }
        return dim(cells(cols, options))
    }

    private func processRow(_ proc: ProcSample, _ options: ViewOptions) -> String {
        var cols = [
            String(proc.pid),
            proc.name,
            String(format: "%.1f", proc.cpuPercent),
            Format.bytes(Double(proc.rssBytes)),
            Format.bytes(Double(proc.footprintBytes)),
        ]
        if options.ioColumns {
            cols.append(Format.rate(proc.diskReadBytesPerSec))
            cols.append(Format.rate(proc.diskWriteBytesPerSec))
        }
        return cells(cols, options)
    }

    private func cells(_ cols: [String], _ options: ViewOptions) -> String {
        cols.enumerated().map { index, value in
            cell(value, columnWidth(index, options, cols.count), alignRight: index != 1)
        }.joined(separator: " ")
    }

    private func cell(_ text: String, _ width: Int, alignRight: Bool) -> String {
        if alignRight {
            return text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
        }
        return Format.column(text, width)
    }

    /// The name column absorbs whatever the fixed columns leave over, so the table
    /// can never exceed the terminal width.
    private func columnWidth(_ index: Int, _ options: ViewOptions, _ columnCount: Int) -> Int {
        let fixed = 6 + 5 + 7 + 7 + (columnCount - 5) * 8
        let separators = columnCount - 1
        switch index {
        case 0: return 6
        case 1: return Swift.max(6, Swift.min(24, options.width - fixed - separators))
        case 2: return 5
        case 3: return 7
        case 4: return 7
        default: return 8
        }
    }

    private func visibleRows(_ options: ViewOptions, total: Int, overhead: Int) -> Range<Int> {
        let rows = Swift.max(1, options.height - overhead)
        let start = Swift.max(0, Swift.min(options.scroll, total - rows))
        return start..<Swift.min(total, start + rows)
    }

    // MARK: - Style

    private func bold(_ s: String) -> String { paint("1", s) }
    private func dim(_ s: String) -> String { paint("2", s) }

    private func colored(_ s: String, _ percent: Double) -> String {
        switch percent {
        case ..<60: return paint("32", s)
        case ..<85: return paint("33", s)
        default: return paint("31", s)
        }
    }

    private func paint(_ code: String, _ s: String) -> String {
        color ? "\u{1b}[\(code)m\(s)\u{1b}[0m" : s
    }

    // MARK: - Formatting

    private func bytes(_ value: UInt64) -> String { Format.bytes(Double(value)) }
    private func trim(_ v: Double) -> String { String(format: "%.0f", v) }
    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    private func clockString(_ ms: Int64) -> String {
        TimeFormatter.shared.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

private enum TimeFormatter {
    static let shared: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
