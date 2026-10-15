import AppKit
import Combine
import Darwin
import IOKit
import Metal

struct MonitorPoint: Identifiable, Codable, Sendable {
    var id: Date { date }
    let date: Date
    let cpu: Double?
    let memory: Double?
    let gpu: Double?
    let diskRead: Double?
    let diskWrite: Double?
    let download: Double?
    let upload: Double?
    let diskUsed: Double?
}
struct MonitorProcess: Identifiable, Sendable {
    let id: Int32
    let name: String
    let cpu: Double?
    let memory: UInt64
}
struct MonitorVolume: Identifiable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let total: Int64
    let free: Int64
    var usedFraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}
struct SystemReading: Sendable {
    let point: MonitorPoint
    let cores: [Double]
    let totalMemory: UInt64
    let appMemory: UInt64
    let wiredMemory: UInt64
    let compressedMemory: UInt64
    let swap: UInt64
    let memoryPressure: Int32?
    let gpuName: String
    let gpuMemory: UInt64?
    let processes: [MonitorProcess]
    let volumes: [MonitorVolume]
}

/// Samples public Mach/libproc counters and optional driver-provided IOKit statistics.
/// All work runs on a serial utility queue. Missing measurements stay unavailable.
final class SystemSampler {
    private var previousCPU: [UInt64]?
    private var previousDisk: (UInt64, UInt64)?
    private var previousNetwork: (UInt64, UInt64)?
    private var previousProcesses: [Int32: UInt64] = [:]
    private var previousTime: TimeInterval?

    func read() -> SystemReading {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 }
        previousTime = now
        let (cpu, cores) = cpuLoad()
        let memory = memoryUsage()
        let gpu = gpuUsage()
        let disk = diskCounters()
        let net = networkCounters()
        let mountedVolumes = volumes()
        let point = MonitorPoint(date: Date(), cpu: cpu, memory: memory.available ? min(100, Double(memory.app + memory.wired + memory.compressed) / Double(max(1, memory.total)) * 100) : nil,
                                 gpu: gpu.percent, diskRead: rate(disk?.0, previousDisk?.0, elapsed),
                                 diskWrite: rate(disk?.1, previousDisk?.1, elapsed),
                                 download: rate(net?.0, previousNetwork?.0, elapsed), upload: rate(net?.1, previousNetwork?.1, elapsed),
                                 diskUsed: mountedVolumes.first(where: { $0.path == "/" }).map { $0.usedFraction * 100 })
        previousDisk = disk; previousNetwork = net
        return SystemReading(point: point, cores: cores, totalMemory: memory.total, appMemory: memory.app,
                             wiredMemory: memory.wired, compressedMemory: memory.compressed, swap: memory.swap, memoryPressure: memoryPressure(),
                             gpuName: MTLCreateSystemDefaultDevice()?.name ?? "GPU", gpuMemory: gpu.memory,
                             processes: processes(elapsed: elapsed), volumes: mountedVolumes)
    }

    private func rate(_ current: UInt64?, _ previous: UInt64?, _ elapsed: Double?) -> Double? {
        guard let current, let previous, current >= previous, let elapsed, elapsed > 0 else { return nil }
        return Double(current - previous) / elapsed
    }

    private func cpuLoad() -> (Double?, [Double]) {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &count) == KERN_SUCCESS,
              let info else { return (nil, []) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        let current = (0..<Int(count)).map { UInt64(UInt32(bitPattern: info[$0])) }
        defer { previousCPU = current }
        guard let previous = previousCPU, previous.count == current.count else { return (nil, []) }
        var cores: [Double] = []; var allBusy: UInt64 = 0; var allTicks: UInt64 = 0
        for core in 0..<Int(processorCount) {
            let offset = core * Int(CPU_STATE_MAX)
            var delta: [UInt64] = []
            for index in 0..<Int(CPU_STATE_MAX) {
                let a = current[offset + index], b = previous[offset + index]
                delta.append(a >= b ? a - b : (UInt64(UInt32.max) - b) + a + 1)
            }
            let total = delta.reduce(0, +)
            let busy = total - delta[Int(CPU_STATE_IDLE)]
            cores.append(total > 0 ? Double(busy) / Double(total) * 100 : 0)
            allBusy += busy; allTicks += total
        }
        return (allTicks > 0 ? Double(allBusy) / Double(allTicks) * 100 : nil, cores)
    }

    private func memoryUsage() -> (total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, swap: UInt64, available: Bool) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS, page > 0 else { return (total, 0, 0, 0, 0, false) }
        let app = UInt64(stats.internal_page_count >= stats.purgeable_count ? stats.internal_page_count - stats.purgeable_count : 0) * UInt64(page)
        var swap = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return (total, app, UInt64(stats.wire_count) * UInt64(page), UInt64(stats.compressor_page_count) * UInt64(page), swap.xsu_used, true)
    }

    private func memoryPressure() -> Int32? {
        var level: Int32 = 0; var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
              [1, 2, 4].contains(level) else { return nil }
        return level
    }

    private func properties(className: String, key: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var values: [[String: Any]] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] { values.append(value) }
            IOObjectRelease(service)
        }
        return values
    }
    private func gpuUsage() -> (percent: Double?, memory: UInt64?) {
        let stats = properties(className: "IOAccelerator", key: "PerformanceStatistics")
        let loads = stats.compactMap { ($0["Device Utilization %"] as? NSNumber)?.doubleValue ?? ($0["GPU Activity(%)"] as? NSNumber)?.doubleValue }
        let memory = stats.compactMap { ($0["In use system memory"] as? NSNumber)?.uint64Value }.max()
        return (loads.filter { $0 >= 0 && $0 <= 100 }.max(), memory)
    }
    private func diskCounters() -> (UInt64, UInt64)? {
        let values = properties(className: "IOBlockStorageDriver", key: "Statistics")
        guard !values.isEmpty else { return nil }
        var read: UInt64 = 0, write: UInt64 = 0
        for stats in values {
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
    private func networkCounters() -> (UInt64, UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        var received: UInt64 = 0, sent: UInt64 = 0; var found = false
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let item = entry.pointee
            let name = String(cString: item.ifa_name)
            guard name.hasPrefix("en"), item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  item.ifa_flags & UInt32(IFF_UP) != 0, let data = item.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(counters.ifi_ibytes); sent += UInt64(counters.ifi_obytes); found = true
        }
        return found ? (received, sent) : nil
    }
    private func processes(elapsed: Double?) -> [MonitorProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { return [] }
        var next: [Int32: UInt64] = [:]; var values: [MonitorProcess] = []
        for pid in pids.prefix(min(Int(actual), pids.count)) where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let time = info.pti_total_user &+ info.pti_total_system
            let cpu = rate(time, previousProcesses[pid], elapsed).map { $0 / 1_000_000_000 * 100 }
            next[pid] = time
            var buffer = [CChar](repeating: 0, count: 256)
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            let name = length > 0 ? String(cString: buffer) : "PID \(pid)"
            values.append(MonitorProcess(id: pid, name: name, cpu: cpu, memory: info.pti_resident_size))
        }
        previousProcesses = next
        return values
    }
    private func volumes() -> [MonitorVolume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let info = try? url.resourceValues(forKeys: keys), info.volumeIsLocal == true,
                  let total = info.volumeTotalCapacity, total > 0, let free = info.volumeAvailableCapacity else { return nil }
            return MonitorVolume(name: info.volumeName ?? url.lastPathComponent, path: url.path, total: Int64(total), free: Int64(free))
        }.sorted { $0.path < $1.path }
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    @Published private(set) var reading: SystemReading?
    @Published private(set) var history: [MonitorPoint] = []
    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "MacTools.SystemMonitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let historyURL = VideoLibraryStore.appSupportDirectory.appendingPathComponent("monitor-history.plist")
    private var samples = 0

    func start() {
        guard timer == nil else { return }
        let url = historyURL
        queue.async { [weak self] in
            let history = (try? Data(contentsOf: url)).flatMap { try? PropertyListDecoder().decode([MonitorPoint].self, from: $0) } ?? []
            Task { @MainActor in self?.history = history.filter { Date().timeIntervalSince($0.date) < 3600 } }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(150))
        let sampler = self.sampler
        timer.setEventHandler { [weak self] in
            let reading = sampler.read()
            Task { @MainActor in self?.receive(reading) }
        }
        self.timer = timer; timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    private func receive(_ value: SystemReading) {
        reading = value
        history.append(value.point)
        history = Array(history.suffix(900))
        samples += 1
        if samples % 15 == 0 {
            let points = history; let url = historyURL
            queue.async {
                do {
                    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try encoder.encode(points).write(to: url, options: .atomic)
                } catch { /* Live monitoring remains available if history cannot be saved. */ }
            }
        }
    }
}
