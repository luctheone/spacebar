import Foundation
import Darwin
import IOKit

public final class SystemSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previousCPU: CPUTicks?
    public init() {}

    public func sample() -> SystemSnapshot {
        let ticks = cpuTicks()
        lock.lock()
        let cpu = ticks.flatMap { now in previousCPU.flatMap { now.utilization(since: $0) } }
        previousCPU = ticks
        lock.unlock()

        let memory = memoryStatistics()
        let swap = swapBytes()
        return SystemSnapshot(date: Date(), cpuPercent: cpu,
                              memoryUsedBytes: memory.used, memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
                              compressedBytes: memory.compressed, swapUsedBytes: swap ?? 0,
                              pressure: memoryPressure(), gpuPercent: gpuUtilization(), disk: diskSnapshot(),
                              memoryAvailable: memory.available, swapAvailable: swap != nil)
    }

    private func cpuTicks() -> CPUTicks? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(user: UInt64(ticks.0), system: UInt64(ticks.1), idle: UInt64(ticks.2), nice: UInt64(ticks.3))
    }

    private func memoryStatistics() -> (used: UInt64, compressed: UInt64, available: Bool) {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (0, 0, false) }
        let page = UInt64(vm_kernel_page_size)
        let compressed = UInt64(info.compressor_page_count) * page
        let used = (UInt64(info.active_count) + UInt64(info.wire_count)) * page + compressed
        return (min(ProcessInfo.processInfo.physicalMemory, used), compressed, true)
    }

    private func swapBytes() -> UInt64? {
        var value = xsw_usage()
        var length = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &value, &length, nil, 0) == 0 else { return nil }
        return value.xsu_used
    }

    private func memoryPressure() -> MemoryPressure {
        var value: Int32 = 0
        var length = MemoryLayout<Int32>.stride
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &length, nil, 0) == 0 else { return .unknown }
        switch value {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    private func diskSnapshot() -> DiskSnapshot {
        var value = statvfs()
        guard statvfs(NSHomeDirectory(), &value) == 0 else { return DiskSnapshot(totalBytes: 0, freeBytes: 0) }
        let blockSize = UInt64(value.f_frsize == 0 ? value.f_bsize : value.f_frsize)
        return DiskSnapshot(totalBytes: UInt64(value.f_blocks) * blockSize,
                            freeBytes: UInt64(value.f_bavail) * blockSize)
    }

    private func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var percentages: [Double] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let values = property as? [String: Any],
                  let number = values["Device Utilization %"] as? NSNumber else { continue }
            percentages.append(min(100, max(0, number.doubleValue)))
        }
        return percentages.max()
    }
}
