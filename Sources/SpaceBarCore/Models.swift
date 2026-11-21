import Foundation

public enum MemoryPressure: String, Sendable, Codable {
    case normal, warning, critical, unknown
}

public struct DiskSnapshot: Sendable, Codable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    /// Capacity unavailable to this user, including space shared with APFS siblings/reserves.
    public var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
    public var usedFraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }
    public init(totalBytes: UInt64, freeBytes: UInt64) {
        self.totalBytes = totalBytes
        self.freeBytes = min(totalBytes, freeBytes)
    }
}

public struct SystemSnapshot: Sendable, Codable {
    public let date: Date
    public let cpuPercent: Double?
    /// Active + wired + physical compressor pages. Excludes inactive/reclaimable pages;
    /// this is a transparent estimate, not Activity Monitor's private accounting formula.
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let compressedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pressure: MemoryPressure
    public let gpuPercent: Double?
    public let disk: DiskSnapshot
    public let memoryAvailable: Bool
    public let swapAvailable: Bool
    public var memoryFraction: Double {
        memoryTotalBytes == 0 ? 0 : Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }
    public init(date: Date, cpuPercent: Double?, memoryUsedBytes: UInt64, memoryTotalBytes: UInt64,
                compressedBytes: UInt64, swapUsedBytes: UInt64, pressure: MemoryPressure,
                gpuPercent: Double?, disk: DiskSnapshot,
                memoryAvailable: Bool = true, swapAvailable: Bool = true) {
        self.date = date
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
        self.gpuPercent = gpuPercent
        self.disk = disk
        self.memoryAvailable = memoryAvailable
        self.swapAvailable = swapAvailable
    }
}

public enum ProcessSort: String, Sendable, CaseIterable { case cpu, memory }

public struct ProcessSample: Identifiable, Sendable, Codable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    /// macOS ps percentage; one busy CPU core can contribute 100%.
    public let cpuPercent: Double
    /// Resident memory reported by ps, not the app's unique physical footprint.
    public let memoryBytes: UInt64
    public let executableURL: URL?
    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64, executableURL: URL?) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.executableURL = executableURL
    }
}

public struct FolderUsage: Identifiable, Sendable, Codable {
    public var id: String { url.path }
    public let url: URL
    public var name: String { url.lastPathComponent }
    /// Blocks claimed in the filesystem, counted once per inode.
    public let allocatedBytes: UInt64
    /// Sum of reported file lengths. Sparse files make this larger than the allocation;
    /// block-shared clones make it larger than what deleting would return.
    public let apparentBytes: UInt64
    /// Entries whose link count was above one, so blocks are shared with other paths.
    public let sharedBlockFiles: Int
    public let isDirectory: Bool
    public let deniedCount: Int
    public let isPartial: Bool
    public init(url: URL, allocatedBytes: UInt64, apparentBytes: UInt64, sharedBlockFiles: Int,
                isDirectory: Bool, deniedCount: Int, isPartial: Bool) {
        self.url = url
        self.allocatedBytes = allocatedBytes
        self.apparentBytes = apparentBytes
        self.sharedBlockFiles = sharedBlockFiles
        self.isDirectory = isDirectory
        self.deniedCount = deniedCount
        self.isPartial = isPartial
    }
}

public struct FolderScanResult: Sendable, Codable {
    public let rootURL: URL
    public let rows: [FolderUsage]
    public let scannedFiles: Int
    public let deniedCount: Int
    public let skippedSymlinks: Int
    public let skippedCloudPlaceholders: Int
    public let skippedMounts: Int
    public let wasCancelled: Bool
    public let wasTimeLimited: Bool
    public let date: Date
    public var totalAllocatedBytes: UInt64 { rows.reduce(0) { $0 + $1.allocatedBytes } }
    public var totalApparentBytes: UInt64 { rows.reduce(0) { $0 + $1.apparentBytes } }
    public var totalSharedBlockFiles: Int { rows.reduce(0) { $0 + $1.sharedBlockFiles } }
    public var isPartial: Bool { deniedCount > 0 || wasCancelled || wasTimeLimited || skippedMounts > 0 }

    public init(rootURL: URL, rows: [FolderUsage], scannedFiles: Int, deniedCount: Int,
                skippedSymlinks: Int, skippedCloudPlaceholders: Int, skippedMounts: Int,
                wasCancelled: Bool, wasTimeLimited: Bool, date: Date) {
        self.rootURL = rootURL
        self.rows = rows
        self.scannedFiles = scannedFiles
        self.deniedCount = deniedCount
        self.skippedSymlinks = skippedSymlinks
        self.skippedCloudPlaceholders = skippedCloudPlaceholders
        self.skippedMounts = skippedMounts
        self.wasCancelled = wasCancelled
        self.wasTimeLimited = wasTimeLimited
        self.date = date
    }
}

/// Tick arithmetic is separated so reset/first-sample behavior can be verified.
public struct CPUTicks: Sendable, Equatable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
    public func utilization(since old: CPUTicks) -> Double? {
        guard user >= old.user, system >= old.system, idle >= old.idle, nice >= old.nice else { return nil }
        let busy = (user - old.user) + (system - old.system) + (nice - old.nice)
        let total = busy + (idle - old.idle)
        guard total > 0 else { return nil }
        return min(100, max(0, Double(busy) * 100 / Double(total)))
    }
}
