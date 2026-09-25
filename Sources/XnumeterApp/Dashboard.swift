import SwiftUI

/// Tracks one interface's history. The busiest interface by cumulative traffic is used,
/// which matches the first NET row of the CLI and is stable across a session.
final class NetHistory {
    var rx: [Double] = []
    var tx: [Double] = []
    var capacity: Int
    var name = "-"

    init(capacity: Int) { self.capacity = capacity }

    func append(_ sample: Snapshot) {
        guard let top = sample.net.first else {
            name = "-"
            rx.append(0)
            tx.append(0)
            trim()
            return
        }
        name = top.name
        rx.append(top.rxBytesPerSec)
        tx.append(top.txBytesPerSec)
        trim()
    }

    private func trim() {
        if rx.count > capacity { rx.removeFirst(rx.count - capacity) }
        if tx.count > capacity { tx.removeFirst(tx.count - capacity) }
    }

    var peak: Double {
        Swift.max(1024, (rx + tx).max() ?? 1024)
    }
}

@MainActor
final class MonitorModel: NSObject, ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var history = NetHistory(capacity: 120)

    private let sampler = Sampler()

    override init() {
        super.init()
        // Cumulative counters need a baseline before any rate is real.
        _ = sampler.sample(sort: .cpu, top: 15)
    }

    func tick() {
        let snapshot = sampler.sample(sort: .cpu, top: 15)
        history.append(snapshot)
        self.snapshot = snapshot
    }

    var statusTitle: String {
        guard let top = snapshot?.net.first else { return "↓ - ↑ -" }
        return "↓\(Format.rate(top.rxBytesPerSec)) ↑\(Format.rate(top.txBytesPerSec))"
    }
}

func tone(_ percent: Double) -> Color {
    switch percent {
    case ..<60: return .green
    case ..<85: return .yellow
    default: return .red
    }
}

private struct GaugeRow: View {
    let label: String
    let percent: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 42, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(nsColor: .separatorColor))
                        Capsule()
                            .fill(tone(percent))
                            .frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
                    }
                }
                .frame(height: 6)
                Text(Format.percent(percent))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tone(percent))
                    .frame(width: 52, alignment: .trailing)
            }
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct NetGraph: View {
    let rx: [Double]
    let tx: [Double]
    let peak: Double

    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            context.stroke(Path(box), with: .color(Color(nsColor: .quaternaryLabelColor)), lineWidth: 1)
            guard rx.count > 1 else { return }
            context.stroke(series(rx, box), with: .color(.green), lineWidth: 1.5)
            context.stroke(series(tx, box), with: .color(.orange), lineWidth: 1.5)
        }
        .frame(height: 84)
    }

    private func series(_ values: [Double], _ box: CGRect) -> Path {
        var path = Path()
        let count = values.count
        for (i, value) in values.enumerated() {
            let x = box.minX + box.width * CGFloat(i) / CGFloat(Swift.max(1, count - 1))
            let y = box.maxY - box.height * CGFloat(Swift.max(0, Swift.min(1, value / peak)))
            let point = NSPoint(x: x, y: y)
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

private struct MetricRow: View {
    let cells: [(text: String, width: CGFloat, trailing: Bool)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell.text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: cell.width, alignment: cell.trailing ? .trailing : .leading)
            }
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                content(snapshot)
            } else {
                Text("sampling…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 560, height: 40)
                    .padding(16)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func content(_ snapshot: Snapshot) -> some View {
        let swapPercent = snapshot.mem.swapTotalBytes > 0
            ? Double(snapshot.mem.swapUsedBytes) / Double(snapshot.mem.swapTotalBytes) * 100
            : 0
        let disk = snapshot.disks.max { $0.percent < $1.percent }
        let tracked = model.history.name == "-" ? "no interface" : model.history.name

        return VStack(alignment: .leading, spacing: 0) {
            Text("\(snapshot.hostName)  up \(Format.duration(snapshot.uptimeSeconds))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                GaugeRow(
                    label: "CPU",
                    percent: snapshot.cpu.totalPercent,
                    detail: "user \(String(format: "%.0f", snapshot.cpu.userPercent))%  sys \(String(format: "%.0f", snapshot.cpu.systemPercent))%  load \(String(format: "%.2f", snapshot.cpu.load1))  \(snapshot.cpu.coreCount) cores"
                )
                GaugeRow(
                    label: "MEM",
                    percent: snapshot.mem.percent,
                    detail: "\(Format.bytes(Double(snapshot.mem.usedBytes))) / \(Format.bytes(Double(snapshot.mem.totalBytes)))  wired \(Format.bytes(Double(snapshot.mem.wiredBytes)))  comp \(Format.bytes(Double(snapshot.mem.compressedBytes)))"
                )
                GaugeRow(
                    label: "SWAP",
                    percent: swapPercent,
                    detail: "\(Format.bytes(Double(snapshot.mem.swapUsedBytes))) / \(Format.bytes(Double(snapshot.mem.swapTotalBytes)))"
                )
                if let disk {
                    GaugeRow(
                        label: "DISK",
                        percent: disk.percent,
                        detail: "\(disk.mount)  \(Format.bytes(Double(disk.totalBytes - disk.freeBytes))) / \(Format.bytes(Double(disk.totalBytes)))"
                    )
                }
            }
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("NET").font(.system(size: 11, weight: .bold))
                    Text("\(tracked)   green = rx, orange = tx   peak \(Format.rate(model.history.peak))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                NetGraph(rx: model.history.rx, tx: model.history.tx, peak: model.history.peak)
            }
            .padding(.top, 16)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                MetricRow(cells: [("INTERFACE", 70, false), ("RX", 60, true), ("TX", 60, true), ("RX TOTAL", 70, true), ("TX TOTAL", 70, true)])
                    .foregroundStyle(.secondary)
                ForEach(snapshot.net.prefix(4)) { net in
                    MetricRow(cells: [
                        (net.name, 70, false),
                        (Format.rate(net.rxBytesPerSec), 60, true),
                        (Format.rate(net.txBytesPerSec), 60, true),
                        (Format.bytes(Double(net.rxBytes)), 70, true),
                        (Format.bytes(Double(net.txBytes)), 70, true),
                    ])
                }
                if snapshot.net.isEmpty {
                    Text("no interface has carried traffic")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 12)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                Text("PROC").font(.system(size: 11, weight: .bold))
                MetricRow(cells: [("PID", 48, true), ("NAME", 200, false), ("CPU%", 52, true), ("RSS", 64, true)])
                    .foregroundStyle(.secondary)
                ForEach(snapshot.processes.prefix(6)) { proc in
                    MetricRow(cells: [
                        (String(proc.pid), 48, true),
                        (Format.column(proc.name, 24), 200, false),
                        (String(format: "%.1f", proc.cpuPercent), 52, true),
                        (Format.bytes(Double(proc.rssBytes)), 64, true),
                    ])
                }
            }
            .padding(.top, 16)
        }
        .padding(16)
        .frame(width: 560, alignment: .leading)
    }
}
