import SwiftUI

/// Every user-facing string in the dashboard goes through this. The keys are the
/// English texts, with tables under `en.lproj` and `zh-Hans.lproj`; the system
/// language picks the table, so a Chinese macOS gets Chinese labels.
private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

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

/// Short histories for the four headline gauges.
final class MetricHistory {
    private let capacity: Int
    private(set) var cpu: [Double] = []
    private(set) var mem: [Double] = []
    private(set) var temp: [Double] = []
    private(set) var gpu: [Double] = []

    init(capacity: Int) { self.capacity = capacity }

    func append(_ snapshot: Snapshot) {
        cpu.append(snapshot.cpu.totalPercent)
        mem.append(snapshot.mem.percent)
        temp.append(snapshot.sensors.maxTemperatureCelsius ?? 0)
        gpu.append(snapshot.sensors.gpuUtilizationPercent ?? 0)
        trim(&cpu)
        trim(&mem)
        trim(&temp)
        trim(&gpu)
    }

    private func trim(_ values: inout [Double]) {
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

@MainActor
final class MonitorModel: NSObject, ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var history = NetHistory(capacity: 120)
    @Published private(set) var metrics = MetricHistory(capacity: 60)

    private let sampler = Sampler()

    override init() {
        super.init()
        // Cumulative counters need a baseline before any rate is real.
        _ = sampler.sample(sort: .cpu, top: 15)
    }

    func tick() {
        let snapshot = sampler.sample(sort: .cpu, top: 15)
        history.append(snapshot)
        metrics.append(snapshot)
        self.snapshot = snapshot
    }

    var statusTitle: String {
        let network: String
        if let top = snapshot?.net.first {
            network = "↓\(Format.rate(top.rxBytesPerSec)) ↑\(Format.rate(top.txBytesPerSec))"
        } else {
            network = "↓ - ↑ -"
        }
        guard let temp = snapshot?.sensors.maxTemperature else { return network }
        let marker = temp.celsius >= 85 ? "▲" : ""
        return "\(network)  \(marker)\(Int(temp.celsius.rounded()))°"
    }
}

func tone(_ percent: Double) -> Color {
    switch percent {
    case ..<60: return .green
    case ..<85: return .yellow
    default: return .red
    }
}

private func tempTone(_ celsius: Double) -> Color {
    switch celsius {
    case ..<70: return .green
    case ..<85: return .yellow
    default: return .red
    }
}

private enum Theme {
    static var cardFill: Color { Color(nsColor: .controlBackgroundColor) }
    static var cardStroke: Color { Color(nsColor: .separatorColor).opacity(0.45) }
    static var track: Color { Color(nsColor: .separatorColor).opacity(0.55) }
    static var plotFill: Color { Color(nsColor: .textBackgroundColor).opacity(0.35) }
}

// MARK: - Small views

private struct Sparkline: View {
    let values: [Double]
    let maxValue: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, maxValue > 0 else { return }
            var line = Path()
            var area = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(Swift.max(1, values.count - 1))
                let clamped = Swift.min(Swift.max(value / maxValue, 0), 1)
                let y = size.height * (1 - CGFloat(clamped))
                let point = CGPoint(x: x, y: y)
                if index == 0 {
                    line.move(to: point)
                    area.move(to: CGPoint(x: x, y: size.height))
                    area.addLine(to: point)
                } else {
                    line.addLine(to: point)
                    area.addLine(to: point)
                }
            }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.10)))
            context.stroke(line, with: .color(color.opacity(0.80)), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}

private struct LevelBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(Swift.min(Swift.max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct TableRow: View {
    let cells: [(text: String, width: CGFloat, trailing: Bool)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell.text)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .frame(width: cell.width, alignment: cell.trailing ? .trailing : .leading)
            }
        }
    }
}

// MARK: - Cards

private struct MetricTile: View {
    let label: String
    let value: String
    let detail: String
    let fraction: Double
    let color: Color
    let history: [Double]
    let scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(localized(label))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            LevelBar(fraction: fraction, color: color)
            Sparkline(values: history, maxValue: scale, color: color)
                .frame(height: 20)
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
        )
    }
}

private struct Panel<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(localized(title))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer(minLength: 4)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
        )
    }
}

// MARK: - Graphs

private struct NetworkGraph: View {
    let rx: [Double]
    let tx: [Double]
    let peak: Double

    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size)
            for row in 1...3 {
                let y = box.height * CGFloat(row) / 4
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: box.width, y: y))
                context.stroke(
                    line,
                    with: .color(Color(nsColor: .quaternaryLabelColor).opacity(0.5)),
                    lineWidth: 0.5
                )
            }
            guard rx.count > 1 else { return }
            context.fill(areaPath(rx, box), with: .color(.green.opacity(0.10)))
            context.fill(areaPath(tx, box), with: .color(.orange.opacity(0.08)))
            context.stroke(linePath(rx, box), with: .color(.green), lineWidth: 1.5)
            context.stroke(linePath(tx, box), with: .color(.orange), lineWidth: 1.5)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.plotFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private func point(_ index: Int, _ value: Double, _ count: Int, _ box: CGRect) -> CGPoint {
        let x = box.minX + box.width * CGFloat(index) / CGFloat(Swift.max(1, count - 1))
        let y = box.maxY - box.height * CGFloat(Swift.min(Swift.max(value / peak, 0), 1))
        return CGPoint(x: x, y: y)
    }

    private func linePath(_ values: [Double], _ box: CGRect) -> Path {
        var path = Path()
        for (index, value) in values.enumerated() {
            let point = point(index, value, values.count, box)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }

    private func areaPath(_ values: [Double], _ box: CGRect) -> Path {
        var path = Path()
        for (index, value) in values.enumerated() {
            let point = point(index, value, values.count, box)
            index == 0 ? path.move(to: CGPoint(x: point.x, y: box.maxY)) : path.addLine(to: point)
            path.addLine(to: point)
        }
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Panels

private struct NetworkPanel: View {
    let snapshot: Snapshot
    let history: NetHistory

    var body: some View {
        Panel(
            "NET",
            subtitle: String(format: localized("peak %@"), "\(Format.rate(history.peak))/s")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(history.name)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text(localized("green = rx, orange = tx"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                }
                NetworkGraph(rx: history.rx, tx: history.tx, peak: history.peak)
                    .frame(height: 84)
                if snapshot.net.isEmpty {
                    Text(localized("no interface has carried traffic"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        TableRow(cells: [
                            (localized("INTERFACE"), 68, false),
                            (localized("RX"), 62, true),
                            (localized("TX"), 62, true),
                            (localized("TOTAL"), 74, true),
                        ])
                        .foregroundStyle(.secondary)
                        ForEach(snapshot.net.prefix(4)) { net in
                            TableRow(cells: [
                                (net.name, 68, false),
                                (Format.rate(net.rxBytesPerSec), 62, true),
                                (Format.rate(net.txBytesPerSec), 62, true),
                                (Format.bytes(Double(net.rxBytes + net.txBytes)), 74, true),
                            ])
                        }
                    }
                }
            }
        }
    }
}

private struct SensorsPanel: View {
    let sensors: SensorSample

    var body: some View {
        Panel("SENSORS", subtitle: fanSummary) {
            VStack(alignment: .leading, spacing: 8) {
                if let maxTemp = sensors.maxTemperature {
                    HStack(alignment: .firstTextBaseline) {
                        Text(maxTemp.sensor)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(String(format: "%.1f°C", maxTemp.celsius))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(tempTone(maxTemp.celsius))
                    }
                    let hottest = sensors.temperatures
                        .sorted { $0.celsius > $1.celsius }
                        .dropFirst()
                        .prefix(5)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                        ForEach(Array(hottest.enumerated()), id: \.offset) { _, reading in
                            GridRow {
                                Text(reading.sensor)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(String(format: "%.1f°C", reading.celsius))
                                    .gridColumnAlignment(.trailing)
                                    .foregroundStyle(tempTone(reading.celsius))
                            }
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    Text(sensorSummary)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("unavailable: \(sensors.unavailable["temperature"] ?? "no sensors")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !sensors.fans.isEmpty {
                    Divider().opacity(0.5)
                    HStack {
                        Text(localized("FAN"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(sensors.fans
                            .map { "\($0.name) \(String(format: "%.0f", $0.rpm)) RPM" }
                            .joined(separator: "   "))
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                } else if let reason = sensors.unavailable["fan"] {
                    Text("\(localized("FAN")): \(reason)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !sensors.unavailable.isEmpty {
                    Text(sensors.unavailable
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key): \($0.value)" }
                        .joined(separator: "   "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var fanSummary: String? {
        guard let maxRPM = sensors.maxFanRPM else { return nil }
        return "\(Int(maxRPM.rounded())) RPM"
    }

    private var sensorSummary: String {
        let average = sensors.averageTemperatureCelsius
            .map { String(format: "%.1f°C", $0) } ?? "--"
        return "\(sensors.temperatures.count) sensors  ·  avg \(average)"
    }
}

private struct StoragePanel: View {
    let snapshot: Snapshot

    private var swapPercent: Double {
        snapshot.mem.swapTotalBytes > 0
            ? Double(snapshot.mem.swapUsedBytes) / Double(snapshot.mem.swapTotalBytes) * 100
            : 0
    }

    var body: some View {
        Panel("STORAGE") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(localized("SWAP"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text("\(Format.bytes(Double(snapshot.mem.swapUsedBytes))) / \(Format.bytes(Double(snapshot.mem.swapTotalBytes)))")
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                    }
                    LevelBar(fraction: swapPercent / 100, color: tone(swapPercent))
                }

                Text(localized("DISK"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                ForEach(snapshot.disks.prefix(3)) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(disk.mount)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(Format.bytes(Double(disk.totalBytes - disk.freeBytes))) / \(Format.bytes(Double(disk.totalBytes)))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        LevelBar(fraction: disk.percent / 100, color: tone(disk.percent))
                    }
                }
            }
        }
    }
}

private struct ProcessesPanel: View {
    let processes: [ProcSample]

    var body: some View {
        Panel("PROC") {
            VStack(alignment: .leading, spacing: 3) {
                TableRow(cells: [
                    (localized("PID"), 36, true),
                    (localized("NAME"), 150, false),
                    (localized("CPU%"), 46, true),
                    (localized("RSS"), 56, true),
                ])
                .foregroundStyle(.secondary)
                ForEach(processes.prefix(7)) { proc in
                    TableRow(cells: [
                        (String(proc.pid), 36, true),
                        (proc.name, 150, false),
                        (String(format: "%.1f", proc.cpuPercent), 46, true),
                        (Format.bytes(Double(proc.rssBytes)), 56, true),
                    ])
                }
            }
        }
    }
}

// MARK: - Header + dashboard

private struct DashboardHeader: View {
    let snapshot: Snapshot

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "gauge")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.hostName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(String(format: localized("up %@"), Format.duration(snapshot.uptimeSeconds)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Date(timeIntervalSince1970: Double(snapshot.timestampMs) / 1000)
                .formatted(date: .omitted, time: .standard))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

struct DashboardContent: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                content(snapshot)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(localized("sampling…"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
    }

    private func content(_ snapshot: Snapshot) -> some View {
        let sensors = snapshot.sensors
        let maxTemp = sensors.maxTemperature
        let gpu = sensors.gpuUtilizationPercent
        let avg = sensors.averageTemperatureCelsius.map { String(format: "%.1f°", $0) } ?? "--"

        return VStack(alignment: .leading, spacing: 16) {
            DashboardHeader(snapshot: snapshot)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                MetricTile(
                    label: "CPU",
                    value: String(format: "%.1f%%", snapshot.cpu.totalPercent),
                    detail: "load \(String(format: "%.2f", snapshot.cpu.load1)) · \(snapshot.cpu.coreCount) cores",
                    fraction: snapshot.cpu.totalPercent / 100,
                    color: tone(snapshot.cpu.totalPercent),
                    history: model.metrics.cpu,
                    scale: 100
                )
                MetricTile(
                    label: "MEM",
                    value: String(format: "%.1f%%", snapshot.mem.percent),
                    detail: "\(Format.bytes(Double(snapshot.mem.usedBytes))) / \(Format.bytes(Double(snapshot.mem.totalBytes)))",
                    fraction: snapshot.mem.percent / 100,
                    color: tone(snapshot.mem.percent),
                    history: model.metrics.mem,
                    scale: 100
                )
                MetricTile(
                    label: "TEMP",
                    value: maxTemp.map { String(format: "%.1f°C", $0.celsius) } ?? "--",
                    detail: maxTemp.map { "\($0.sensor) · avg \(avg)" } ?? "unavailable",
                    fraction: (maxTemp?.celsius ?? 0) / 110,
                    color: maxTemp.map { tempTone($0.celsius) } ?? .gray,
                    history: model.metrics.temp,
                    scale: 110
                )
                MetricTile(
                    label: "GPU",
                    value: gpu.map { String(format: "%.0f%%", $0) } ?? "--",
                    detail: sensors.gpuPowerWatts.map { String(format: "power %.2fW", $0) } ?? "power --",
                    fraction: (gpu ?? 0) / 100,
                    color: tone(gpu ?? 0),
                    history: model.metrics.gpu,
                    scale: 100
                )
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16)], spacing: 16) {
                NetworkPanel(snapshot: snapshot, history: model.history)
                SensorsPanel(sensors: sensors)
                StoragePanel(snapshot: snapshot)
                ProcessesPanel(processes: snapshot.processes)
            }
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            DashboardContent(model: model)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.05), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
        )
        .frame(minWidth: 660, minHeight: 560)
    }
}