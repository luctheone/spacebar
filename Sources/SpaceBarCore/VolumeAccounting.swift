import Foundation
import Darwin

/// APFS answers "how much room is left" from three places that never agree: the filesystem's
/// own free-block count, the container's free bytes shared with sibling volumes, and the
/// capacity hints macOS hands to apps that may trigger eviction. The disagreements are the
/// measurement. All fields are read without privilege; nothing here runs as an administrator.
public struct VolumeAccounting: Codable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let measuredAt: Date
    public let mountPoint: String
    public let volumeName: String?
    public let volumeIdentifier: String?
    public let containerIdentifier: String?
    public let containerTotalBytes: UInt64?
    public let containerFreeBytes: UInt64?
    /// statvfs: bytes this volume can write right now, before eviction.
    public let filesystemTotalBytes: UInt64
    public let filesystemFreeBytes: UInt64
    /// Finder's "available": free plus space macOS considers evictable for an important write.
    public let importantUsageAvailableBytes: UInt64?
    /// What an app may claim without pressuring the system: usually below free space.
    public let opportunisticUsageAvailableBytes: UInt64?
    /// Per-volume block usage across the whole container, including volumes outside home.
    public let volumes: [APFSVolumeUsage]
    public let snapshots: SnapshotInventory?
    /// Human-readable record of measurements that failed and why. Never replaced by zeroes.
    public let failures: [String]

    public init(schemaVersion: Int = VolumeAccounting.schemaVersion, measuredAt: Date,
                mountPoint: String, volumeName: String?, volumeIdentifier: String?,
                containerIdentifier: String?, containerTotalBytes: UInt64?, containerFreeBytes: UInt64?,
                filesystemTotalBytes: UInt64, filesystemFreeBytes: UInt64,
                importantUsageAvailableBytes: UInt64?, opportunisticUsageAvailableBytes: UInt64?,
                volumes: [APFSVolumeUsage], snapshots: SnapshotInventory?, failures: [String]) {
        self.schemaVersion = schemaVersion
        self.measuredAt = measuredAt
        self.mountPoint = mountPoint
        self.volumeName = volumeName
        self.volumeIdentifier = volumeIdentifier
        self.containerIdentifier = containerIdentifier
        self.containerTotalBytes = containerTotalBytes
        self.containerFreeBytes = containerFreeBytes
        self.filesystemTotalBytes = filesystemTotalBytes
        self.filesystemFreeBytes = filesystemFreeBytes
        self.importantUsageAvailableBytes = importantUsageAvailableBytes
        self.opportunisticUsageAvailableBytes = opportunisticUsageAvailableBytes
        self.volumes = volumes
        self.snapshots = snapshots
        self.failures = failures
    }

    /// Space macOS will evict before it calls the volume full.
    public var purgeableBytes: UInt64? { clampedDifference(importantUsageAvailableBytes, filesystemFreeBytes) }
    /// Free this volume advertises that the container does not currently hold.
    public var reservedForSiblingsBytes: UInt64? { clampedDifference(filesystemFreeBytes, containerFreeBytes) }
    /// Container bytes that no volume's own usage explains: snapshots, metadata, reserves.
    /// Can be negative when per-volume usage counts shared blocks more than once.
    public var unattributedBytes: Int64? {
        guard let total = containerTotalBytes, let free = containerFreeBytes else { return nil }
        let used = volumes.reduce(Int64(0)) { $0 + Int64($1.capacityInUseBytes) }
        return Int64(total) - Int64(free) - used
    }
    public var dataVolumeUsedBytes: UInt64? {
        volumes.first { $0.roles.contains("Data") }.map(\.capacityInUseBytes)
    }

    /// Derived readings are part of the published contract, so they are encoded even though
    /// they are recomputed on decode.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, measuredAt, mountPoint, volumeName, volumeIdentifier, containerIdentifier
        case containerTotalBytes, containerFreeBytes, filesystemTotalBytes, filesystemFreeBytes
        case importantUsageAvailableBytes, opportunisticUsageAvailableBytes, volumes, snapshots, failures
        case purgeableBytes, reservedForSiblingsBytes, unattributedBytes, dataVolumeUsedBytes, nonDataUsedBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.schemaVersion
        measuredAt = try values.decode(Date.self, forKey: .measuredAt)
        mountPoint = try values.decode(String.self, forKey: .mountPoint)
        volumeName = try values.decodeIfPresent(String.self, forKey: .volumeName)
        volumeIdentifier = try values.decodeIfPresent(String.self, forKey: .volumeIdentifier)
        containerIdentifier = try values.decodeIfPresent(String.self, forKey: .containerIdentifier)
        containerTotalBytes = try values.decodeIfPresent(UInt64.self, forKey: .containerTotalBytes)
        containerFreeBytes = try values.decodeIfPresent(UInt64.self, forKey: .containerFreeBytes)
        filesystemTotalBytes = try values.decode(UInt64.self, forKey: .filesystemTotalBytes)
        filesystemFreeBytes = try values.decode(UInt64.self, forKey: .filesystemFreeBytes)
        importantUsageAvailableBytes = try values.decodeIfPresent(UInt64.self, forKey: .importantUsageAvailableBytes)
        opportunisticUsageAvailableBytes = try values.decodeIfPresent(UInt64.self, forKey: .opportunisticUsageAvailableBytes)
        volumes = try values.decodeIfPresent([APFSVolumeUsage].self, forKey: .volumes) ?? []
        snapshots = try values.decodeIfPresent(SnapshotInventory.self, forKey: .snapshots)
        failures = try values.decodeIfPresent([String].self, forKey: .failures) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(measuredAt, forKey: .measuredAt)
        try values.encode(mountPoint, forKey: .mountPoint)
        try values.encodeIfPresent(volumeName, forKey: .volumeName)
        try values.encodeIfPresent(volumeIdentifier, forKey: .volumeIdentifier)
        try values.encodeIfPresent(containerIdentifier, forKey: .containerIdentifier)
        try values.encodeIfPresent(containerTotalBytes, forKey: .containerTotalBytes)
        try values.encodeIfPresent(containerFreeBytes, forKey: .containerFreeBytes)
        try values.encode(filesystemTotalBytes, forKey: .filesystemTotalBytes)
        try values.encode(filesystemFreeBytes, forKey: .filesystemFreeBytes)
        try values.encodeIfPresent(importantUsageAvailableBytes, forKey: .importantUsageAvailableBytes)
        try values.encodeIfPresent(opportunisticUsageAvailableBytes, forKey: .opportunisticUsageAvailableBytes)
        try values.encode(volumes, forKey: .volumes)
        try values.encodeIfPresent(snapshots, forKey: .snapshots)
        try values.encode(failures, forKey: .failures)
        try values.encodeIfPresent(purgeableBytes, forKey: .purgeableBytes)
        try values.encodeIfPresent(reservedForSiblingsBytes, forKey: .reservedForSiblingsBytes)
        try values.encodeIfPresent(unattributedBytes, forKey: .unattributedBytes)
        try values.encodeIfPresent(dataVolumeUsedBytes, forKey: .dataVolumeUsedBytes)
        try values.encode(nonDataUsedBytes, forKey: .nonDataUsedBytes)
    }
    /// Usage on volumes no home-directory folder scan can reach.
    public var nonDataUsedBytes: UInt64 {
        volumes.filter { !$0.roles.contains("Data") }.reduce(UInt64(0)) { $0 + $1.capacityInUseBytes }
    }
}

public struct APFSVolumeUsage: Codable, Sendable, Equatable, Identifiable {
    public var id: String { identifier }
    public let identifier: String
    public let name: String
    public let roles: [String]
    public let capacityInUseBytes: UInt64

    public init(identifier: String, name: String, roles: [String], capacityInUseBytes: UInt64) {
        self.identifier = identifier
        self.name = name
        self.roles = roles
        self.capacityInUseBytes = capacityInUseBytes
    }
}

public struct APFSSnapshot: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case systemUpdate, timeMachine, other }

    public let volumeIdentifier: String
    public let name: String
    public let kind: Kind
    public let isPurgeable: Bool
    public let limitsContainerShrink: Bool

    public init(volumeIdentifier: String, name: String, isPurgeable: Bool, limitsContainerShrink: Bool) {
        self.volumeIdentifier = volumeIdentifier
        self.name = name
        self.isPurgeable = isPurgeable
        self.limitsContainerShrink = limitsContainerShrink
        if name.hasPrefix("com.apple.os.update-") { kind = .systemUpdate }
        else if name.hasPrefix("com.apple.TimeMachine.") { kind = .timeMachine }
        else { kind = .other }
    }
}

public struct SnapshotInventory: Codable, Sendable {
    public let snapshots: [APFSSnapshot]
    public let volumesExamined: Int
    /// Volumes whose snapshot list could not be read. Reported, not assumed empty.
    public let unreadableVolumeIdentifiers: [String]
    /// APFS does not expose a snapshot's block count to an unprivileged process.
    public let byteSizesAvailable: Bool
    public let byteSizeReason: String

    public init(snapshots: [APFSSnapshot], volumesExamined: Int, unreadableVolumeIdentifiers: [String],
                byteSizesAvailable: Bool = false,
                byteSizeReason: String = "APFS snapshot sizes are not exposed to an unprivileged process; "
                    + "diskutil reports names, XIDs and purgeable flags only.") {
        self.snapshots = snapshots
        self.volumesExamined = volumesExamined
        self.unreadableVolumeIdentifiers = unreadableVolumeIdentifiers
        self.byteSizesAvailable = byteSizesAvailable
        self.byteSizeReason = byteSizeReason
    }

    public var count: Int { snapshots.count }
    public var nonPurgeableCount: Int { snapshots.filter { !$0.isPurgeable }.count }
    public var shrinkLimitingCount: Int { snapshots.filter(\.limitsContainerShrink).count }
    public var isComplete: Bool { unreadableVolumeIdentifiers.isEmpty && volumesExamined > 0 }

    private enum CodingKeys: String, CodingKey {
        case snapshots, volumesExamined, unreadableVolumeIdentifiers, byteSizesAvailable, byteSizeReason
        case count, nonPurgeableCount, shrinkLimitingCount, isComplete
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshots = try values.decodeIfPresent([APFSSnapshot].self, forKey: .snapshots) ?? []
        volumesExamined = try values.decodeIfPresent(Int.self, forKey: .volumesExamined) ?? 0
        unreadableVolumeIdentifiers = try values.decodeIfPresent([String].self, forKey: .unreadableVolumeIdentifiers) ?? []
        byteSizesAvailable = try values.decodeIfPresent(Bool.self, forKey: .byteSizesAvailable) ?? false
        byteSizeReason = try values.decodeIfPresent(String.self, forKey: .byteSizeReason) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(snapshots, forKey: .snapshots)
        try values.encode(volumesExamined, forKey: .volumesExamined)
        try values.encode(unreadableVolumeIdentifiers, forKey: .unreadableVolumeIdentifiers)
        try values.encode(byteSizesAvailable, forKey: .byteSizesAvailable)
        try values.encode(byteSizeReason, forKey: .byteSizeReason)
        try values.encode(count, forKey: .count)
        try values.encode(nonPurgeableCount, forKey: .nonPurgeableCount)
        try values.encode(shrinkLimitingCount, forKey: .shrinkLimitingCount)
        try values.encode(isComplete, forKey: .isComplete)
    }
}

private func clampedDifference(_ larger: UInt64?, _ smaller: UInt64?) -> UInt64? {
    guard let larger, let smaller else { return nil }
    return larger > smaller ? larger - smaller : 0
}

/// Reads the numbers above. `diskutil` is invoked by absolute path, read-only, with a deadline
/// per call so a stuck helper cannot hang the caller.
public struct VolumeAccountingProbe: Sendable {
    private let includeSnapshots: Bool
    private let toolDeadline: TimeInterval

    public init(includeSnapshots: Bool = true, toolDeadline: TimeInterval = 8) {
        self.includeSnapshots = includeSnapshots
        self.toolDeadline = max(0.2, toolDeadline)
    }

    public func measure(at url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> VolumeAccounting {
        var failures: [String] = []
        let identity = filesystemIdentity(of: url)
        let mount = identity.mountPoint ?? url.path
        let stat = filesystemCapacity(of: url)
        let hints = capacityHints(of: url)

        var volumeName: String?
        var volumeIdentifier = identity.deviceIdentifier
        var containerIdentifier: String?
        var containerTotal: UInt64?
        var containerFree: UInt64?
        var volumes: [APFSVolumeUsage] = []
        var inventory: SnapshotInventory?

        guard let volumeIdentifier else {
            failures.append("statfs reported no device behind \(mount): the container layout is unavailable.")
            return VolumeAccounting(measuredAt: Date(), mountPoint: mount, volumeName: volumeName,
                                    volumeIdentifier: nil, containerIdentifier: nil, containerTotalBytes: nil,
                                    containerFreeBytes: nil, filesystemTotalBytes: stat.totalBytes,
                                    filesystemFreeBytes: stat.freeBytes,
                                    importantUsageAvailableBytes: hints.important,
                                    opportunisticUsageAvailableBytes: hints.opportunistic,
                                    volumes: volumes, snapshots: nil, failures: failures)
        }
        if let list = DiskutilPlist.run(["apfs", "list", "-plist"], deadline: toolDeadline),
           let container = DiskutilPlist.container(list, containingVolume: volumeIdentifier) {
            containerIdentifier = DiskutilPlist.string(container, "ContainerReference")
            containerTotal = DiskutilPlist.number(container, "CapacityCeiling")
            containerFree = DiskutilPlist.number(container, "CapacityFree")
            volumes = DiskutilPlist.volumes(container)
            volumeName = volumes.first { $0.identifier == volumeIdentifier }?.name
            if includeSnapshots { inventory = snapshotInventory(of: volumes, failures: &failures) }
        } else {
            failures.append("diskutil apfs list failed (\(DiskutilPlist.lastFailure ?? "unknown reason")): "
                + "per-volume usage and snapshots unavailable.")
        }
        return VolumeAccounting(measuredAt: Date(), mountPoint: mount, volumeName: volumeName,
                                volumeIdentifier: volumeIdentifier, containerIdentifier: containerIdentifier,
                                containerTotalBytes: containerTotal, containerFreeBytes: containerFree,
                                filesystemTotalBytes: stat.totalBytes, filesystemFreeBytes: stat.freeBytes,
                                importantUsageAvailableBytes: hints.important,
                                opportunisticUsageAvailableBytes: hints.opportunistic,
                                volumes: volumes, snapshots: inventory, failures: failures)
    }

    /// statfs names the APFS volume behind a path, which is the identifier diskutil expects.
    private func filesystemIdentity(of url: URL) -> (mountPoint: String?, deviceIdentifier: String?) {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return (nil, nil) }
        func name(_ field: UnsafeRawPointer) -> String {
            String(cString: field.assumingMemoryBound(to: CChar.self))
        }
        let mount = withUnsafePointer(to: &info.f_mntonname) { name(UnsafeRawPointer($0)) }
        let device = withUnsafePointer(to: &info.f_mntfromname) { name(UnsafeRawPointer($0)) }
        guard !device.isEmpty, device.hasPrefix("/dev/") else { return (mount.isEmpty ? nil : mount, nil) }
        return (mount.isEmpty ? nil : mount, String(device.dropFirst("/dev/".count)))
    }

    private func filesystemCapacity(of url: URL) -> (totalBytes: UInt64, freeBytes: UInt64) {
        var value = statvfs()
        guard statvfs(url.path, &value) == 0 else { return (0, 0) }
        let block = UInt64(value.f_frsize == 0 ? value.f_bsize : value.f_frsize)
        return (UInt64(value.f_blocks) * block, UInt64(value.f_bavail) * block)
    }

    private func capacityHints(of url: URL) -> (important: UInt64?, opportunistic: UInt64?) {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityForOpportunisticUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (nil, nil) }
        func positive(_ value: Int64?) -> UInt64? {
            guard let value, value >= 0 else { return nil }
            return UInt64(value)
        }
        return (positive(values.volumeAvailableCapacityForImportantUsage),
                positive(values.volumeAvailableCapacityForOpportunisticUsage))
    }

    private func snapshotInventory(of volumes: [APFSVolumeUsage], failures: inout [String]) -> SnapshotInventory {
        var records: [APFSSnapshot] = []
        var unreadable: [String] = []
        for volume in volumes {
            guard let plist = DiskutilPlist.run(["apfs", "listSnapshots", volume.identifier, "-plist"],
                                                 deadline: toolDeadline) else {
                unreadable.append("\(volume.identifier) (\(volume.name))")
                continue
            }
            records.append(contentsOf: DiskutilPlist.snapshots(plist, volumeIdentifier: volume.identifier))
        }
        if !unreadable.isEmpty {
            failures.append("Snapshot lists unreadable for: \(unreadable.joined(separator: ", ")).")
        }
        return SnapshotInventory(snapshots: records, volumesExamined: volumes.count,
                                 unreadableVolumeIdentifiers: unreadable)
    }
}

public enum DiskutilPlist {
    static var lastFailure: String?
    public static let executable = URL(fileURLWithPath: "/usr/sbin/diskutil")

    /// Returns the decoded property list, or nil when the call failed, timed out, or did not
    /// produce a dictionary. Output goes through a temporary file so a large plist cannot
    /// deadlock on a full pipe buffer.
    public static func run(_ arguments: [String], deadline: TimeInterval) -> [String: Any]? {
        lastFailure = nil
        let path = NSTemporaryDirectory() + "spacebar-diskutil-\(UUID().uuidString).plist"
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let output = FileHandle(handleForWritingAtPath: path) else {
            lastFailure = "temp file unavailable"
            return nil
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            lastFailure = "launch failed: \(error.localizedDescription)"
            output.closeFile()
            return nil
        }
        defer { output.closeFile() }
        var waited: TimeInterval = 0
        while process.isRunning {
            if waited >= deadline {
                process.terminate()
                var forced: TimeInterval = 0
                while process.isRunning, forced < 1 { usleep(20_000); forced += 0.02 }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                lastFailure = "timed out after \(Int(deadline))s"
                return nil
            }
            usleep(10_000)
            waited += 0.01
        }
        guard process.terminationStatus == 0 else {
            lastFailure = "exit \(process.terminationStatus)"
            return nil
        }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            lastFailure = data.isEmpty ? "empty output" : "no parsable plist (\(data.count) bytes)"
            return nil
        }
        return dictionary
    }

    public static func string(_ dictionary: [String: Any], _ key: String) -> String? {
        dictionary[key] as? String
    }

    public static func number(_ dictionary: [String: Any], _ key: String) -> UInt64? {
        guard let value = dictionary[key] as? NSNumber else { return nil }
        let signed = value.int64Value
        return signed >= 0 ? UInt64(signed) : nil
    }

    /// Finds the container holding a given volume, so a sibling volume's growth is visible.
    public static func container(_ list: [String: Any], containingVolume identifier: String) -> [String: Any]? {
        guard let containers = list["Containers"] as? [[String: Any]] else { return nil }
        return containers.first { container in
            (container["Volumes"] as? [[String: Any]] ?? [])
                .contains { ($0["DeviceIdentifier"] as? String) == identifier }
        }
    }

    public static func volumes(_ container: [String: Any]) -> [APFSVolumeUsage] {
        (container["Volumes"] as? [[String: Any]] ?? []).compactMap { volume in
            guard let identifier = volume["DeviceIdentifier"] as? String,
                  let inUse = number(volume, "CapacityInUse") else { return nil }
            return APFSVolumeUsage(identifier: identifier, name: volume["Name"] as? String ?? identifier,
                                   roles: volume["Roles"] as? [String] ?? [], capacityInUseBytes: inUse)
        }
    }

    public static func snapshots(_ plist: [String: Any], volumeIdentifier: String) -> [APFSSnapshot] {
        (plist["Snapshots"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let name = entry["SnapshotName"] as? String else { return nil }
            return APFSSnapshot(volumeIdentifier: volumeIdentifier, name: name,
                                isPurgeable: (entry["Purgeable"] as? Bool ?? false),
                                limitsContainerShrink: (entry["LimitingContainerShrink"] as? Bool ?? false))
        }
    }
}

private extension FileHandle {
    /// Existing descriptors only; opening by path would race with another scan's temporary file.
    convenience init?(handleForWritingAtPath path: String) {
        let descriptor = open(path, O_WRONLY | O_TRUNC)
        guard descriptor >= 0 else { return nil }
        self.init(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
