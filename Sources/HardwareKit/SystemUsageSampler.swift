import Darwin
import Foundation
import IOKit

/// Tick counters of one CPU core since boot.
struct CoreTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// One reading of CPU, memory and GPU load, in percent. nil = not known (yet).
public struct SystemUsage: Equatable, Sendable {
    public var cpu: Double?
    public var ram: Double?
    public var gpu: Double?
    public static let empty = SystemUsage(cpu: nil, ram: nil, gpu: nil)
}

/// Reads CPU / RAM / GPU load straight from Mach and IOKit (no shell, no subprocess).
/// CPU needs two readings to produce a value.
/// `@unchecked Sendable`: the only mutable state is the CPU baseline, and the one instance in the app
/// is touched from a single serial queue.
final class SystemUsageSampler: @unchecked Sendable {
    /// `mach_host_self()` hands out a new send right on every call; fetch it once.
    private static let host = mach_host_self()
    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        return host_page_size(host, &size) == KERN_SUCCESS && size > 0 ? UInt64(size) : UInt64(vm_kernel_page_size)
    }()

    private var previous: [CoreTicks]?

    /// Forget the CPU baseline (after sleep the delta would span the whole nap).
    func reset() { previous = nil }

    func sample(includeGPU: Bool) -> SystemUsage {
        var usage = SystemUsage(cpu: nil, ram: Self.ramPercent(), gpu: includeGPU ? Self.gpuPercent() : nil)
        if let ticks = Self.coreTicks() {
            if let previous { usage.cpu = Self.cpuPercent(from: previous, to: ticks) }
            previous = ticks
        }
        return usage
    }

    /// Busy share between two readings. Counters are 32-bit and wrap on long uptimes, hence `&-`.
    static func cpuPercent(from old: [CoreTicks], to new: [CoreTicks]) -> Double? {
        guard old.count == new.count, !new.isEmpty else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for (a, b) in zip(old, new) {
            let active = UInt64(b.user &- a.user) + UInt64(b.system &- a.system) + UInt64(b.nice &- a.nice)
            busy += active
            total += active + UInt64(b.idle &- a.idle)
        }
        return total > 0 ? min(100, Double(busy) / Double(total) * 100) : nil
    }

    /// "Memory Used" as Activity Monitor shows it: app (internal − purgeable) + wired + compressed.
    static func ramPercent(internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                           compressedPages: UInt64, pageSize: UInt64, physicalBytes: UInt64) -> Double? {
        guard physicalBytes > 0, pageSize > 0 else { return nil }
        let app = internalPages >= purgeablePages ? internalPages - purgeablePages : 0
        let used = Double(app + wiredPages + compressedPages) * Double(pageSize)
        return min(100, max(0, used / Double(physicalBytes) * 100))
    }

    private static func coreTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        guard cpuCount > 0 else { return nil }
        return info.withMemoryRebound(to: processor_cpu_load_info_data_t.self, capacity: Int(cpuCount)) { loads in
            (0..<Int(cpuCount)).map { i in
                let t = loads[i].cpu_ticks
                return CoreTicks(user: t.0, system: t.1, idle: t.2, nice: t.3)
            }
        }
    }

    private static func ramPercent() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return ramPercent(internalPages: UInt64(stats.internal_page_count), purgeablePages: UInt64(stats.purgeable_count),
                          wiredPages: UInt64(stats.wire_count), compressedPages: UInt64(stats.compressor_page_count),
                          pageSize: pageSize, physicalBytes: ProcessInfo.processInfo.physicalMemory)
    }

    /// Highest utilisation among the powered GPUs; nil when no accelerator reports one.
    private static func gpuPercent() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // Only this one property: copying the whole registry entry every tick is wasteful.
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            else { continue }
            for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"] {
                if let value = (stats[key] as? NSNumber)?.doubleValue {
                    best = max(best ?? 0, min(100, max(0, value)))
                    break
                }
            }
        }
        return best
    }
}
