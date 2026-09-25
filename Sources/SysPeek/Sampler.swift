import Foundation
import Darwin

/// Counters that XNU reports as cumulative are diffed across two `sample()`
/// calls, so the first call only seeds state and reports zero for every rate.
final class Sampler {
    private struct CpuTicks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private struct ProcState {
        var startAbstime: UInt64
        var cpuNs: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
    }

    private struct NetCounters {
        var rx: UInt64
        var tx: UInt64
    }

    private var prevTicks: CpuTicks?
    private var prevWallNs: UInt64?
    private var prevProcs: [Int32: ProcState] = [:]
    private var prevNet: [String: NetCounters] = [:]

    // proc_pid_rusage reports cpu time in mach absolute time units, not nanoseconds
    // (24 MHz ticks on Apple Silicon), so scale by the timebase before diffing.
    private let nsPerTick: Double = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        guard mach_timebase_info(&info) == 0, info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    private let coreCount = ProcessInfo.processInfo.activeProcessorCount

    func sample(sort: SortKey, top: Int) -> Snapshot {
        let wallNs = monotonicNs()
        let prevWallNsValue = prevWallNs
        let spanNs = prevWallNsValue.map { wallNs > $0 ? wallNs - $0 : 0 } ?? 0
        let spanSec = Double(spanNs) / 1_000_000_000

        var cpu = CpuSample(coreCount: coreCount)
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) >= 1 {
            cpu.load1 = loads[0]
            cpu.load5 = loads[1]
            cpu.load15 = loads[2]
        }
        if let ticks = cpuTicks() {
            if let prev = prevTicks, spanSec > 0 {
                let user = UInt64(ticks.user &- prev.user)
                let system = UInt64(ticks.system &- prev.system)
                let nice = UInt64(ticks.nice &- prev.nice)
                let idle = UInt64(ticks.idle &- prev.idle)
                let busy = user + system + nice
                let all = busy + idle
                if all > 0 {
                    // host_cpu_load_info already aggregates all cores, so 100% means fully busy.
                    cpu.totalPercent = Double(busy) / Double(all) * 100
                    cpu.userPercent = Double(user) / Double(all) * 100
                    cpu.systemPercent = Double(system) / Double(all) * 100
                    cpu.nicePercent = Double(nice) / Double(all) * 100
                }
            }
            prevTicks = ticks
        }
        prevWallNs = wallNs

        return Snapshot(
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            hostName: ProcessInfo.processInfo.hostName,
            uptimeSeconds: uptimeSeconds(),
            cpu: cpu,
            mem: memorySample(),
            disks: diskSamples(),
            net: networkSample(spanSec: spanSec),
            processes: processSample(sort: sort, top: top, spanSec: spanSec)
        )
    }

    // MARK: - CPU

    private func cpuTicks() -> CpuTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { raw in
            raw.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ints in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, ints, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CpuTicks(user: t.0, system: t.1, idle: t.2, nice: t.3)
    }

    // MARK: - Memory

    private func memorySample() -> MemSample {
        var m = MemSample()
        m.totalBytes = sysctlUInt64("hw.memsize") ?? 0

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        // sysconf rather than vm_kernel_page_size: the latter is a mutable global, which
        // is not concurrency-safe under Swift 6 language mode. Both report 16 KiB here.
        let pageSize = UInt64(sysconf(_SC_PAGESIZE))
        let result = withUnsafeMutablePointer(to: &stats) { raw in
            raw.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ints in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ints, &count)
            }
        }
        if result == KERN_SUCCESS {
            // Activity Monitor's "Memory Used" = app + wired + compressed resident pages.
            m.usedBytes = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * pageSize
            m.freeBytes = UInt64(stats.free_count) * pageSize
            m.wiredBytes = UInt64(stats.wire_count) * pageSize
            m.compressedBytes = UInt64(stats.compressor_page_count) * pageSize
            m.purgeableBytes = UInt64(stats.purgeable_count) * pageSize
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            m.swapTotalBytes = swap.xsu_total
            m.swapUsedBytes = swap.xsu_used
        }
        m.usedBytes = min(m.usedBytes, m.totalBytes)
        return m
    }

    // MARK: - Disk

    private func diskSamples() -> [DiskSample] {
        let probe = getfsstat(nil, 0, Int32(MNT_NOWAIT))
        guard probe > 0 else { return [] }
        let slots = Int(probe)
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: slots)
        defer { buffer.deallocate() }
        let written = getfsstat(buffer, Int32(slots * MemoryLayout<statfs>.stride), Int32(MNT_NOWAIT))
        guard written > 0 else { return [] }

        var out: [DiskSample] = []
        for entry in UnsafeBufferPointer(start: buffer, count: Int(written)) {
            let blocks = UInt64(entry.f_blocks)
            let bsize = UInt64(entry.f_bsize)
            guard blocks > 0, bsize > 0 else { continue }
            let total = blocks * bsize
            guard total >= 1_000_000_000 else { continue }
            let mount = fixedString(entry.f_mntonname)
            guard mount == "/" || (mount.hasPrefix("/") && !mount.hasSuffix("/")) else { continue }
            out.append(DiskSample(
                mount: mount,
                name: fixedString(entry.f_mntfromname),
                totalBytes: total,
                freeBytes: UInt64(entry.f_bavail) * bsize
            ))
        }
        // APFS exposes one container as several system mounts (Preboot, Update, VM,
        // recovery snapshots) that all report identical capacity, so show only the
        // mounts a user can actually fill up: the root volume, the data volume, and
        // externally mounted disks.
        let interesting = out
            .filter {
                $0.mount == "/" || $0.mount == "/System/Volumes/Data" || $0.mount.hasPrefix("/Volumes/")
            }
            .sorted {
                if $0.mount.count != $1.mount.count { return $0.mount.count < $1.mount.count }
                return $0.mount < $1.mount
            }
        var seenDevices = Set<String>()
        return interesting.filter { seenDevices.insert($0.name).inserted }
    }

    private func fixedString<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
    }

    /// `String(cString:)` on a fixed-size buffer is deprecated under Swift 6; truncating
    /// at the NUL and decoding is the same thing without the overload.
    private func cString(_ buffer: [CChar]) -> String {
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[0..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Network

    /// Reads interface byte counters from the routing socket. NET_RT_IFLIST2 is used
    /// rather than getifaddrs because it also yields the interface flags in one pass,
    /// but note the counters are not reliably 64-bit — see `wrappedDelta`.
    private func networkSample(spanSec: Double) -> [NetSample] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room for interfaces that appear between the size probe and the read; without
        // it a hot-plug in that gap fails the call and the row disappears for a frame.
        let capacity = size + 4096
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<if_msghdr2>.alignment)
        defer { buffer.deallocate() }
        size = capacity
        guard sysctl(&mib, 6, buffer, &size, nil, 0) == 0 else { return [] }

        var current: [String: NetCounters] = [:]
        var next = buffer
        let end = buffer.advanced(by: size)
        while next < end {
            // Trust but bound: the record lengths come back from the kernel, and a short
            // trailing record would otherwise read past the bytes actually written.
            guard next.distance(to: end) >= MemoryLayout<if_msghdr2>.stride else { break }
            // loadUnaligned rather than assumingMemoryBound: nothing guarantees each
            // record starts on an alignment the 64-bit counter fields demand.
            let message = next.loadUnaligned(as: if_msghdr2.self)
            let length = Int(message.ifm_msglen)
            guard length > 0 else { break }
            defer { next = next.advanced(by: length) }
            guard message.ifm_type == UInt8(RTM_IFINFO2) else { continue }
            let flags = Int32(message.ifm_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let data = message.ifm_data
            // macOS keeps dozens of dormant virtual interfaces (anpi, en1..en6, bridge,
            // gif, stf) permanently UP+RUNNING; ones that never carried a byte are noise.
            guard data.ifi_ibytes != 0 || data.ifi_obytes != 0 else { continue }
            var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else { continue }
            current[cString(nameBuffer)] = NetCounters(rx: data.ifi_ibytes, tx: data.ifi_obytes)
        }
        let previous = prevNet
        prevNet = current

        return current.map { name, counters in
            var rxRate = 0.0
            var txRate = 0.0
            if let before = previous[name], spanSec > 0 {
                rxRate = Double(wrappedDelta(counters.rx, before.rx)) / spanSec
                txRate = Double(wrappedDelta(counters.tx, before.tx)) / spanSec
            }
            return NetSample(
                name: name,
                rxBytes: counters.rx,
                txBytes: counters.tx,
                rxBytesPerSec: rxRate,
                txBytesPerSec: txRate
            )
        }.sorted {
            if $0.rxBytes + $0.txBytes != $1.rxBytes + $1.txBytes {
                return $0.rxBytes + $0.txBytes > $1.rxBytes + $1.txBytes
            }
            return $0.name < $1.name
        }
    }

    /// Measured on macOS 27: `ifi_ibytes` in the NET_RT_IFLIST2 record carries a 32-bit
    /// wrapped count (it equals netstat's value modulo 2^32, and the true 64-bit figure
    /// appears nowhere in the record), while `ifi_obytes` is genuinely 64-bit. A decrease
    /// is therefore treated as one 32-bit wrap, but only when both readings fit in 32
    /// bits; otherwise the interface was recreated and 0 is the honest answer.
    private func wrappedDelta(_ now: UInt64, _ before: UInt64) -> UInt64 {
        if now >= before { return now - before }
        guard now < 1 << 32, before < 1 << 32 else { return 0 }
        return (1 << 32) - before + now
    }

    // MARK: - Processes

    private func processSample(sort: SortKey, top: Int, spanSec: Double) -> [ProcSample] {
        var bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.stride)
        bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bytes)
        guard bytes > 0 else { return [] }
        let limit = min(pids.count, Int(bytes) / MemoryLayout<Int32>.stride)

        var results: [ProcSample] = []
        var next: [Int32: ProcState] = [:]

        for index in 0..<limit {
            let pid = pids[index]
            guard pid > 0, let r = rusage(pid) else { continue }
            next[pid] = ProcState(
                startAbstime: r.startAbstime,
                cpuNs: r.cpuNs,
                diskRead: r.diskRead,
                diskWrite: r.diskWrite
            )

            // A reused pid keeps a stale baseline; start_abstime identifies the actual process instance.
            guard let prev = prevProcs[pid], prev.startAbstime == r.startAbstime else { continue }
            let cpu = delta(r.cpuNs, prev.cpuNs)
            var pct = 0.0
            var readRate = 0.0
            var writeRate = 0.0
            if spanSec > 0 {
                pct = Double(cpu) / (spanSec * 1_000_000_000) * 100
                readRate = Double(delta(r.diskRead, prev.diskRead)) / spanSec
                writeRate = Double(delta(r.diskWrite, prev.diskWrite)) / spanSec
            }
            results.append(ProcSample(
                pid: pid,
                name: procName(pid),
                cpuPercent: pct,
                rssBytes: r.rss,
                footprintBytes: r.footprint,
                diskReadBytesPerSec: readRate,
                diskWriteBytesPerSec: writeRate
            ))
        }
        prevProcs = next

        let sorted = results.sorted { a, b in
            switch sort {
            case .cpu:
                if a.cpuPercent != b.cpuPercent { return a.cpuPercent > b.cpuPercent }
            case .mem:
                if a.rssBytes != b.rssBytes { return a.rssBytes > b.rssBytes }
            }
            return a.pid < b.pid
        }
        return Array(sorted.prefix(top))
    }

    private func delta(_ now: UInt64, _ before: UInt64) -> UInt64 {
        now >= before ? now - before : 0
    }

    private struct ProcRusage {
        var cpuNs: UInt64
        var rss: UInt64
        var footprint: UInt64
        var startAbstime: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
    }

    private func rusage(_ pid: Int32) -> ProcRusage? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { raw in
            raw.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        guard result == 0 else { return nil }
        let cpuTicks = Double(info.ri_user_time &+ info.ri_system_time)
        return ProcRusage(
            cpuNs: UInt64((cpuTicks * nsPerTick).rounded()),
            rss: info.ri_resident_size,
            footprint: info.ri_phys_footprint,
            startAbstime: info.ri_proc_start_abstime,
            diskRead: info.ri_diskio_bytesread,
            diskWrite: info.ri_diskio_byteswritten
        )
    }

    private func procName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 16)
        guard proc_name(pid, &buf, socklen_t(buf.count)) > 0 else { return "?" }
        return cString(buf)
    }

    // MARK: - Helpers

    private func uptimeSeconds() -> Double {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&name, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        let started = Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
        let now = Date().timeIntervalSince1970
        return started > 0 && now > started ? now - started : 0
    }

    private func monotonicNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
}

func sysctlUInt64(_ name: String) -> UInt64? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    switch size {
    case MemoryLayout<Int64>.stride:
        var value: Int64 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return UInt64(bitPattern: value)
    case MemoryLayout<Int32>.stride:
        var value: Int32 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return UInt64(Int64(value))
    default:
        return nil
    }
}
