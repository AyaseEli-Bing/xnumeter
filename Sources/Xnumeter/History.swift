import Foundation

/// Rolling history used by the dashboard view to draw sparklines.
struct SampleHistory {
    let capacity: Int
    private(set) var cpu: [Double] = []
    private(set) var mem: [Double] = []
    private(set) var net: [Double] = []

    init(capacity: Int = 120) {
        self.capacity = capacity
    }

    mutating func append(_ snapshot: Snapshot) {
        cpu.append(snapshot.cpu.totalPercent)
        mem.append(snapshot.mem.percent)
        let netRate = snapshot.net.first.map { $0.rxBytesPerSec + $0.txBytesPerSec } ?? 0
        net.append(netRate)

        if cpu.count > capacity { cpu.removeFirst(cpu.count - capacity) }
        if mem.count > capacity { mem.removeFirst(mem.count - capacity) }
        if net.count > capacity { net.removeFirst(net.count - capacity) }
    }
}
