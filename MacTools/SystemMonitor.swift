import AppKit
import Combine
import Darwin
import IOKit
import IOKit.ps
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
    let battery: Double?
}
/// GPU time a single process spent in the measured span. macOS exposes no GPU
/// percentage per process; the accumulated time per Metal command queue in the IO
/// registry is the closest public figure and is what this reports.
struct GPUConsumer: Identifiable, Sendable, Equatable {
    let pid: Int32
    let name: String
    let seconds: Double
    let percent: Double
    var id: Int32 { pid }
}
struct MonitorProcess: Identifiable, Sendable {
    let id: Int32
    let name: String
    let cpu: Double?
    let memory: UInt64
    let energyWatts: Double?
}
struct MonitorBattery: Sendable {
    let chargePercent: Double
    let isOnBattery: Bool
    let isCharging: Bool
    let minutesRemaining: Int?
    let healthPercent: Double?
    let cycleCount: Int?
    let powerWatts: Double?

    static func read() -> MonitorBattery? {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        guard let source = sources.first(where: {
            (IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any])?["Type"] as? String == "InternalBattery"
        }), let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              let current = (description["Current Capacity"] as? NSNumber)?.doubleValue,
              let maximum = (description["Max Capacity"] as? NSNumber)?.doubleValue, maximum > 0 else { return nil }
        let onBattery = description["Power Source State"] as? String == "Battery Power"
        let charging = (description["Is Charging"] as? NSNumber)?.boolValue == true
        let timeKey = charging ? "Time to Full Charge" : "Time to Empty"
        let rawMinutes = (description[timeKey] as? NSNumber)?.intValue
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        var properties: [String: Any] = [:]
        if service != 0 {
            defer { IOObjectRelease(service) }
            var values: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &values, kCFAllocatorDefault, 0) == KERN_SUCCESS {
                properties = values?.takeRetainedValue() as? [String: Any] ?? [:]
            }
        }
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        let full = (data["FullChargeCapacity"] as? NSNumber)?.doubleValue ?? (data["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue
        let design = (data["DesignCapacity"] as? NSNumber)?.doubleValue
        let health = (full != nil && design != nil && design! > 0) ? min(100, full! / design! * 100) : nil
        let amperage = (properties["Amperage"] as? NSNumber)?.doubleValue
        let voltage = (properties["Voltage"] as? NSNumber)?.doubleValue
        let power = (amperage != nil && voltage != nil && (onBattery || charging)) ? abs(amperage! * voltage!) / 1_000_000 : nil
        return MonitorBattery(chargePercent: min(100, max(0, current / maximum * 100)), isOnBattery: onBattery,
                              isCharging: charging, minutesRemaining: rawMinutes.flatMap { $0 > 0 && $0 < 1440 ? $0 : nil },
                              healthPercent: health, cycleCount: (properties["CycleCount"] as? NSNumber)?.intValue,
                              powerWatts: power)
    }
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
    let gpuConsumers: [GPUConsumer]
    let processes: [MonitorProcess]
    let battery: MonitorBattery?
    let volumes: [MonitorVolume]
}

/// Samples public Mach/libproc counters and optional driver-provided IOKit statistics.
/// All work runs on a serial utility queue. Missing measurements stay unavailable.
final class SystemSampler {
    private var previousCPU: [UInt64]?
    private var previousDisk: (read: UInt64, write: UInt64, at: TimeInterval)?
    private var previousNetwork: (received: UInt64, sent: UInt64, at: TimeInterval)?
    private var previousProcesses: [Int32: UInt64] = [:]
    private var previousEnergy: [Int32: (start: UInt64, nanojoules: UInt64)] = [:]
    private var previousTime: TimeInterval?
    private var diskRates: (read: Double?, write: Double?) = (nil, nil)
    private var networkRates: (download: Double?, upload: Double?) = (nil, nil)
    private var cachedGPU: (value: (percent: Double?, memory: UInt64?), at: TimeInterval)?
    private var cachedBattery: (value: MonitorBattery?, at: TimeInterval)?
    private var cachedVolumes: (value: [MonitorVolume], at: TimeInterval)?
    private var previousGPUClients: (values: [Int32: UInt64], at: TimeInterval)?
    private var gpuClients: (percent: Double?, consumers: [GPUConsumer]) = (nil, [])
    /// One Metal device for the adapter name. Creating it per sample asked the GPU
    /// driver for a new device every two seconds to read a string that never changes.
    private lazy var adapterName = MTLCreateSystemDefaultDevice()?.name ?? "GPU"

    /// `detailed` is set while a view actually shows per-process rows or fast live
    /// values. Without it the expensive measurements keep their last result: IOKit
    /// registry walks (GPU, drive counters), the battery property dictionary, mounted
    /// volume lookups and the pass over every PID cost far more than the Mach
    /// counters behind CPU and memory.
    func read(detailed: Bool) -> SystemReading {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 }
        previousTime = now
        let (cpu, cores) = cpuLoad()
        let memory = memoryUsage()
        let gpu = cached(&cachedGPU, now: now, maxAge: detailed ? 1 : 8) { self.gpuUsage() }
        let battery = cached(&cachedBattery, now: now, maxAge: detailed ? 1 : 10) { MonitorBattery.read() }
        let mountedVolumes = cached(&cachedVolumes, now: now, maxAge: 30) { self.volumes() }
        sampleTransferRates(now: now, maxAge: detailed ? 1 : 8)
        sampleGPUClients(now: now, maxAge: detailed ? 1 : 8)
        let point = MonitorPoint(date: Date(), cpu: cpu, memory: memory.available ? min(100, Double(memory.app + memory.wired + memory.compressed) / Double(max(1, memory.total)) * 100) : nil,
                                 gpu: gpuClients.percent ?? gpu.percent, diskRead: diskRates.read,
                                 diskWrite: diskRates.write,
                                 download: networkRates.download, upload: networkRates.upload,
                                 diskUsed: mountedVolumes.first(where: { $0.path == "/" }).map { $0.usedFraction * 100 },
                                 battery: battery?.chargePercent)
        let values = detailed ? processes(elapsed: elapsed) : []
        if !detailed, !previousProcesses.isEmpty { previousProcesses.removeAll(); previousEnergy.removeAll() }
        return SystemReading(point: point, cores: cores, totalMemory: memory.total, appMemory: memory.app,
                             wiredMemory: memory.wired, compressedMemory: memory.compressed, swap: memory.swap, memoryPressure: memoryPressure(),
                             gpuName: adapterName, gpuMemory: gpu.memory,
                             gpuConsumers: gpuClients.consumers,
                             processes: values, battery: battery, volumes: mountedVolumes)
    }

    private func cached<Value>(_ store: inout (value: Value, at: TimeInterval)?, now: TimeInterval, maxAge: TimeInterval, read: () -> Value) -> Value {
        if let store, now >= store.at, now - store.at < maxAge { return store.value }
        let value = read()
        store = (value, now)
        return value
    }

    /// Byte counters only yield a rate together with the span they cover, so each
    /// previous reading carries its own timestamp instead of the sample timestamp.
    private func sampleTransferRates(now: TimeInterval, maxAge: TimeInterval) {
        if let previous = previousDisk, now - previous.at < maxAge {
            // The last rate stays valid until the counters are read again.
        } else if let counters = diskCounters() {
            if let previous = previousDisk, now > previous.at {
                let span = now - previous.at
                diskRates = (rate(counters.0, previous.read, span), rate(counters.1, previous.write, span))
            }
            previousDisk = (counters.0, counters.1, now)
        } else {
            diskRates = (nil, nil); previousDisk = nil
        }
        if let previous = previousNetwork, now - previous.at < maxAge {
            // The last rate stays valid until the counters are read again.
        } else if let counters = networkCounters() {
            if let previous = previousNetwork, now > previous.at {
                let span = now - previous.at
                networkRates = (rate(counters.0, previous.received, span), rate(counters.1, previous.sent, span))
            }
            previousNetwork = (counters.0, counters.1, now)
        } else {
            networkRates = (nil, nil); previousNetwork = nil
        }
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
    /// The GPU's client objects are not registered services, so a class lookup does
    /// not find them. They hang below the accelerator in the registry, which is how
    /// `ioreg` shows them too.
    private func gpuClientProperties() -> [[String: Any]] {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(accelerators) }
        var values: [[String: Any]] = []
        while true {
            let accelerator = IOIteratorNext(accelerators)
            if accelerator == 0 { break }
            var children: io_iterator_t = 0
            if IORegistryEntryCreateIterator(accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS {
                while true {
                    let child = IOIteratorNext(children)
                    if child == 0 { break }
                    var properties: Unmanaged<CFMutableDictionary>?
                    if IORegistryEntryCreateCFProperties(child, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                       let dictionary = properties?.takeRetainedValue() as? [String: Any],
                       dictionary["IOUserClientCreator"] is String, dictionary["AppUsage"] != nil {
                        values.append(dictionary)
                    }
                    IOObjectRelease(child)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(accelerator)
        }
        return values
    }

    /// Format of the registry entry: "pid 411, WindowServer". The name is cut off
    /// there, so the process name is preferred when it can still be read.
    private static func clientOwner(_ creator: String) -> (pid: Int32, name: String)? {
        guard creator.hasPrefix("pid "), let comma = creator.firstIndex(of: ",") else { return nil }
        let digits = creator[creator.index(creator.startIndex, offsetBy: 4)..<comma]
        guard let pid = Int32(digits) else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        let registryName = creator[creator.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        let name = length > 0 ? String(cString: buffer) : registryName
        return (pid, name.isEmpty ? "PID \(pid)" : name)
    }

    /// Every Metal client holds one `AppUsage` entry per command queue carrying a
    /// cumulative GPU time. The difference between two readings is the GPU time a
    /// process really used. Compositing a window appears under the window server,
    /// not under the app that owns the window. Checked on Apple silicon; where the
    /// registry offers no such client the list stays empty and the driver's own
    /// utilization value is used again.
    private func sampleGPUClients(now: TimeInterval, maxAge: TimeInterval) {
        if let previous = previousGPUClients, now - previous.at < maxAge { return }
        var totals: [Int32: UInt64] = [:]
        var names: [Int32: String] = [:]
        for client in gpuClientProperties() {
            guard let creator = client["IOUserClientCreator"] as? String,
                  let owner = Self.clientOwner(creator) else { continue }
            let usage = client["AppUsage"] as? [[String: Any]] ?? []
            let time = usage.reduce(UInt64(0)) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
            totals[owner.pid, default: 0] &+= time
            names[owner.pid] = owner.name
        }
        defer { previousGPUClients = (totals, now) }
        guard let previous = previousGPUClients, now > previous.at, !totals.isEmpty else { return }
        let span = now - previous.at
        var consumers: [GPUConsumer] = []
        var busy = 0.0
        for (pid, total) in totals {
            guard let before = previous.values[pid], total > before else { continue }
            let seconds = Double(total - before) / 1_000_000_000
            // A restarted counter or a reused PID would otherwise invent GPU time.
            guard seconds > 0, seconds < span * 64 else { continue }
            busy += seconds
            consumers.append(GPUConsumer(pid: pid, name: names[pid] ?? "PID \(pid)", seconds: seconds,
                                         percent: min(100, seconds / span * 100)))
        }
        gpuClients = (min(100, busy / span * 100), consumers.sorted { $0.seconds > $1.seconds })
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
        var next: [Int32: UInt64] = [:], nextEnergy: [Int32: (start: UInt64, nanojoules: UInt64)] = [:]
        var values: [MonitorProcess] = []
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
            var usage = rusage_info_v6()
            let energyStatus = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            var watts: Double?
            if energyStatus == 0 {
                if let previous = previousEnergy[pid], previous.start == usage.ri_proc_start_abstime {
                    watts = rate(usage.ri_energy_nj, previous.nanojoules, elapsed).map { $0 / 1_000_000_000 }
                }
                nextEnergy[pid] = (usage.ri_proc_start_abstime, usage.ri_energy_nj)
            }
            values.append(MonitorProcess(id: pid, name: name, cpu: cpu, memory: info.pti_resident_size, energyWatts: watts))
        }
        previousProcesses = next
        previousEnergy = nextEnergy
        return values
    }
    private func volumes() -> [MonitorVolume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path == "/" || url.path.hasPrefix("/Volumes/") else { return nil }
            guard let info = try? url.resourceValues(forKeys: keys), info.volumeIsLocal == true,
                  let total = info.volumeTotalCapacity, total > 0, let free = info.volumeAvailableCapacity else { return nil }
            return MonitorVolume(name: info.volumeName ?? url.lastPathComponent, path: url.path, total: Int64(total), free: Int64(free))
        }.sorted { $0.path < $1.path }
    }
}

/// The sampling cadence is set on the main actor and read on the sampling queue.
private final class SamplingMode: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var detailed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
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
    private let mode = SamplingMode()
    private var detailConsumers = 0
    private var started = false
    private var suspended = false
    private var historyLoaded = false
    /// Menu-bar widgets only need a slow trickle. The two-second cadence belongs to
    /// views that are actually on screen.
    private var interval: TimeInterval { detailConsumers > 0 ? 2 : 5 }
    var isDetailed: Bool { detailConsumers > 0 }
    var sampleInterval: TimeInterval { interval }

    /// Balanced by `releaseDetail`. A view calls it while it shows live values or
    /// per-process rows; only then does a sample include the pass over every PID.
    func retainDetail() {
        detailConsumers += 1
        if detailConsumers == 1 { restartTimer() }
    }
    func releaseDetail() {
        guard detailConsumers > 0 else { return }
        detailConsumers -= 1
        if detailConsumers == 0 { restartTimer() }
    }

    func start() {
        guard !suspended else { return }
        started = true
        loadHistory()
        restartTimer()
    }
    func stop() { started = false; timer?.cancel(); timer = nil }

    /// Nothing reads a measurement while the display sleeps or the screen is locked.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        timer?.cancel(); timer = nil
    }
    func resume() {
        guard suspended else { return }
        suspended = false
        restartTimer()
    }

    private func loadHistory() {
        guard !historyLoaded else { return }
        historyLoaded = true
        let url = historyURL
        queue.async { [weak self] in
            let history = (try? Data(contentsOf: url)).flatMap { try? PropertyListDecoder().decode([MonitorPoint].self, from: $0) } ?? []
            Task { @MainActor in self?.history = history.filter { Date().timeIntervalSince($0.date) < 3600 } }
        }
    }

    private func restartTimer() {
        guard started, !suspended else { return }
        mode.detailed = detailConsumers > 0
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // A wide leeway lets the system coalesce the idle wake-ups with other work.
        timer.schedule(deadline: .now(), repeating: interval, leeway: detailConsumers > 0 ? .milliseconds(150) : .seconds(1))
        let sampler = self.sampler
        let mode = self.mode
        timer.setEventHandler { [weak self] in
            let reading = sampler.read(detailed: mode.detailed)
            Task { @MainActor in self?.receive(reading) }
        }
        self.timer = timer; timer.resume()
    }
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

struct UserProcess: Identifiable, Equatable, Sendable, Codable {
    let pid: Int32
    let parentPID: Int32
    let startedAt: UInt64
    let startedAtUsec: UInt64
    let name: String
    let executable: String
    let workingDirectory: String
    let hasTerminal: Bool
    var command = ""
    var ports: [Int] = []
    var cpu: Double?
    var memory: UInt64?
    var id: String { "\(pid):\(startedAt):\(startedAtUsec)" }
    var isCodex: Bool { let value = (name + " " + executable).lowercased(); return value.contains("codex") || value.contains("chatgpt") }
    private var homePaths: [String] {
        let home = NSHomeDirectory() + "/"
        let arguments = command.split(whereSeparator: \.isWhitespace).compactMap { argument -> String? in
            guard let range = argument.range(of: home) else { return nil }
            return String(argument[range.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return [executable, workingDirectory].filter { $0.hasPrefix(home) } + arguments
    }
    var isInHome: Bool { !homePaths.isEmpty }
    var isInWork: Bool {
        let home = NSHomeDirectory() + "/"
        let excluded = [home + "Library/", home + ".codex/plugins/cache/", home + ".cache/"]
        return homePaths.contains { path in !excluded.contains(where: path.hasPrefix) }
    }
    var displayName: String {
        guard let range = command.range(of: "/server/runs/") else { return name }
        let project = command[..<range.lowerBound].split(separator: "/").last.map(String.init)
        let run = command[range.upperBound...].split(separator: "/").first.map(String.init)
        guard let project, let run, !project.isEmpty, !run.isEmpty else { return name }
        return project + " · " + run
    }
}

struct UserProcessBookmark: Identifiable, Codable {
    var process: UserProcess
    var logPath: String?
    let markedAt: Date
    var lastSeenAt: Date
    var id: String { process.id }
}

enum UserProcessScope: String, CaseIterable {
    case work, home, all
    var title: String {
        switch self {
        case .work: "Arbeit"
        case .home: "Home"
        case .all: "Alle"
        }
    }
    var explanation: String {
        switch self {
        case .work: "Arbeit: eigene Prozesse mit einem Home-Pfad, ohne Library und Laufzeit-Caches."
        case .home: "Home: eigene Prozesse, deren Programm, Arbeitsordner oder Befehl einen Pfad unter deinem Home enthält."
        case .all: "Alle: sämtliche Prozesse deines Benutzerkontos, auch außerhalb deines Home."
        }
    }
    func contains(_ process: UserProcess) -> Bool {
        switch self {
        case .work: process.isInWork
        case .home: process.isInHome
        case .all: true
        }
    }
}

enum UserProcessViewMode: String {
    case list, tree
}

enum UserProcessSampler {
    static func identity(_ pid: Int32) -> (uid: uid_t, startedAt: UInt64, usec: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (info.pbi_uid, info.pbi_start_tvsec, info.pbi_start_tvusec)
    }
    static func list() -> [UserProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { return [] }
        let uid = getuid()
        return pids.prefix(min(Int(actual), pids.count)).compactMap { pid in
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == uid, info.pbi_start_tvsec > 0 else { return nil }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let nameSize = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = nameSize > 0 ? String(cString: nameBuffer) : "PID \(pid)"
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let pathSize = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathSize > 0 ? String(cString: pathBuffer) : ""
            var vnode = proc_vnodepathinfo()
            let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            let hasCwd = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeSize) == vnodeSize
            let cwd = hasCwd ? withUnsafePointer(to: &vnode.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            } : ""
            return UserProcess(pid: pid, parentPID: Int32(info.pbi_ppid), startedAt: info.pbi_start_tvsec, startedAtUsec: info.pbi_start_tvusec,
                               name: name, executable: path, workingDirectory: cwd, hasTerminal: info.e_tdev != 0 && info.e_tdev != UInt32.max)
        }
    }
    static func commands(_ output: String) -> [Int32: String] {
        var values: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let separator = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[..<separator]) else { continue }
            let command = trimmed[separator...].trimmingCharacters(in: .whitespaces)
            if !command.isEmpty { values[pid] = command }
        }
        return values
    }
    static func listeningPorts(_ output: String) -> [Int32: [Int]] {
        var result: [Int32: Set<Int>] = [:], pid: Int32?
        for line in output.split(separator: "\n") {
            guard let kind = line.first else { continue }
            let value = line.dropFirst()
            if kind == "p" { pid = Int32(value) }
            else if kind == "n", let pid, let suffix = value.split(separator: ":").last,
                    let port = Int(suffix), (1...65535).contains(port) {
                result[pid, default: []].insert(port)
            }
        }
        return result.mapValues { $0.sorted() }
    }
    static func logFile(_ output: String) -> String? {
        var regular = false
        for line in output.split(separator: "\n") {
            guard let kind = line.first else { continue }
            let value = String(line.dropFirst())
            if kind == "f" { regular = false }
            if kind == "t" { regular = value == "REG" }
            if kind == "n", regular, value.hasPrefix("/"),
               let attributes = try? FileManager.default.attributesOfItem(atPath: value),
               attributes[.type] as? FileAttributeType == .typeRegular,
               FileManager.default.isReadableFile(atPath: value) { return value }
        }
        return nil
    }
    static func tail(_ path: String, limit: UInt64 = 65_536) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > limit ? end - limit : 0)
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch { return nil }
    }
}

@MainActor final class UserProcessStore: ObservableObject {
    static let shared = UserProcessStore()
    @Published private(set) var processes: [UserProcess] = []
    @Published private(set) var bookmarks: [UserProcessBookmark] = []
    @Published private(set) var collapsedProcessIDs = Set<String>()
    @Published private(set) var error: String?
    @Published var selectedID: String?
    @Published var scope: UserProcessScope {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "userProcessScope"); rebuildLists() }
    }
    @Published var viewMode: UserProcessViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "userProcessViewMode") }
    }
    private var refreshing = false
    private var lastBookmarkSaveAt = Date.distantPast
    private init() {
        scope = UserProcessScope(rawValue: UserDefaults.standard.string(forKey: "userProcessScope") ?? "") ?? .work
        viewMode = UserProcessViewMode(rawValue: UserDefaults.standard.string(forKey: "userProcessViewMode") ?? "") ?? .list
        if let data = UserDefaults.standard.data(forKey: "userProcessBookmarks") {
            bookmarks = (try? JSONDecoder().decode([UserProcessBookmark].self, from: data)) ?? []
        }
        rebuildLists()
    }
    private var cachedScoped: [UserProcess] = []
    private var cachedListed: [UserProcess] = []
    private var cachedFeatured: [UserProcess] = []
    /// Classifying a process parses every argument of its command line, and the
    /// panels read these lists several times per redraw. They are therefore built
    /// once per refresh instead of on every access.
    private func rebuildLists() {
        cachedScoped = processes.filter(scope.contains)
        let marked = bookmarks.map { bookmark in processes.first(where: { $0.id == bookmark.id }) ?? bookmark.process }
        let markedIDs = Set(bookmarks.map(\.id))
        cachedListed = marked + cachedScoped.filter { !markedIDs.contains($0.id) }
        cachedFeatured = cachedScoped.filter { taskScore($0) > 0 }
            .sorted { a, b in
                let ac = a.cpu ?? 0, bc = b.cpu ?? 0
                if ac >= 10 || bc >= 10, ac != bc { return ac > bc }
                let ascore = taskScore(a), bscore = taskScore(b)
                if ascore != bscore { return ascore > bscore }
                if ac != bc { return ac > bc }
                return a.pid < b.pid
            }
    }
    var scopedProcesses: [UserProcess] { cachedScoped }
    var listedProcesses: [UserProcess] { cachedListed }
    func isBookmarked(_ id: String) -> Bool { bookmarks.contains { $0.id == id } }
    func isRunning(_ id: String) -> Bool { processes.contains { $0.id == id } }
    func toggleCollapsed(_ id: String) {
        if !collapsedProcessIDs.insert(id).inserted { collapsedProcessIDs.remove(id) }
    }
    func collapseAll(_ ids: Set<String>) { collapsedProcessIDs.formUnion(ids) }
    func expandAll() { collapsedProcessIDs.removeAll() }
    func bookmarkedLogPath(_ id: String) -> String? { bookmarks.first { $0.id == id }?.logPath }
    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(data, forKey: "userProcessBookmarks") }
        lastBookmarkSaveAt = Date()
        rebuildLists()
    }
    func toggleBookmark(_ process: UserProcess, logPath: String? = nil) {
        if let index = bookmarks.firstIndex(where: { $0.id == process.id }) {
            bookmarks.remove(at: index)
            saveBookmarks()
            rebuildLists()
            return
        }
        let now = Date()
        bookmarks.insert(UserProcessBookmark(process: process, logPath: logPath, markedAt: now, lastSeenAt: now), at: 0)
        saveBookmarks()
        guard logPath == nil else { return }
        Task { [weak self] in
            guard let self, let path = await self.logPath(for: process),
                  let index = self.bookmarks.firstIndex(where: { $0.id == process.id }) else { return }
            self.bookmarks[index].logPath = path
            self.saveBookmarks()
        }
    }
    var featured: [UserProcess] { cachedFeatured }
    private func taskScore(_ process: UserProcess) -> Int {
        let name = process.name.lowercased()
        if process.command.contains("/server/runs/") { return 5 }
        if ["python", "node", "swift", "java", "ruby"].contains(where: name.contains) { return 4 }
        if process.hasTerminal { return 3 }
        if process.isCodex { return 2 }
        return process.ports.isEmpty ? 0 : 1
    }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        async let listed = Task.detached(priority: .utility) { UserProcessSampler.list() }.value
        async let ports = LocalCommand.run(URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], timeout: 5)
        async let commands = LocalCommand.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "pid=,command="], timeout: 5)
        let values = await listed, portResult = await ports, commandResult = await commands
        let byPort = UserProcessSampler.listeningPorts(portResult.output)
        let byCommand = UserProcessSampler.commands(commandResult.output)
        let byCPU = Dictionary((SystemMonitor.shared.reading?.processes ?? []).map { ($0.id, $0.cpu) }, uniquingKeysWith: { first, _ in first })
        let byMemory = Dictionary((SystemMonitor.shared.reading?.processes ?? []).map { ($0.id, $0.memory) }, uniquingKeysWith: { first, _ in first })
        let previouslyRunning = Set(processes.map(\.id))
        processes = values.map { value in
            var item = value; item.ports = byPort[item.pid] ?? []; item.cpu = byCPU[item.pid] ?? nil; item.memory = byMemory[item.pid] ?? nil; item.command = byCommand[item.pid] ?? ""; return item
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let now = Date()
        for index in bookmarks.indices {
            if let current = processes.first(where: { $0.id == bookmarks[index].id }) {
                bookmarks[index].process = current
                bookmarks[index].lastSeenAt = now
            }
        }
        let currentlyRunning = Set(processes.map(\.id))
        if !bookmarks.isEmpty && (now.timeIntervalSince(lastBookmarkSaveAt) >= 30 || bookmarks.contains(where: { previouslyRunning.contains($0.id) && !currentlyRunning.contains($0.id) })) {
            saveBookmarks()
        }
        error = portResult.status == -1 ? "Ports konnten nicht gelesen werden: " + portResult.error : nil
        rebuildLists()
    }
    func stop(_ process: UserProcess, force: Bool = false) -> String? {
        guard process.pid > 1, process.pid != getpid(),
              let current = UserProcessSampler.identity(process.pid),
              current.uid == getuid(), current.startedAt == process.startedAt, current.usec == process.startedAtUsec else {
            return "Der Prozess existiert nicht mehr oder seine PID wurde neu vergeben."
        }
        guard Darwin.kill(process.pid, force ? SIGKILL : SIGTERM) == 0 else {
            return "Prozess \(process.pid) konnte nicht beendet werden: " + String(cString: strerror(errno))
        }
        return nil
    }
    func logPath(for process: UserProcess) async -> String? {
        guard let identity = UserProcessSampler.identity(process.pid),
              identity.uid == getuid(), identity.startedAt == process.startedAt, identity.usec == process.startedAtUsec else { return nil }
        let output = await LocalCommand.run(URL(fileURLWithPath: "/usr/sbin/lsof"),
                                            arguments: ["-nP", "-a", "-p", String(process.pid), "-d", "1,2", "-Fftn"], timeout: 5)
        return UserProcessSampler.logFile(output.output)
    }
}
