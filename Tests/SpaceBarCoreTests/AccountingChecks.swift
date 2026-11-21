import Foundation
import SpaceBarCore

private let gib: UInt64 = 1_000_000_000

private func syntheticAccounting(total: UInt64 = 500 * gib, free: UInt64 = 40 * gib,
                                containerTotal: UInt64? = 500 * gib, containerFree: UInt64? = 39 * gib,
                                important: UInt64? = 44 * gib, opportunistic: UInt64? = 30 * gib,
                                volumes: [APFSVolumeUsage] = [],
                                snapshots: SnapshotInventory? = nil,
                                failures: [String] = []) -> VolumeAccounting {
    VolumeAccounting(measuredAt: Date(), mountPoint: "/System/Volumes/Data", volumeName: "Data",
                     volumeIdentifier: "disk3s5", containerIdentifier: volumes.isEmpty ? nil : "disk3",
                     containerTotalBytes: containerTotal, containerFreeBytes: containerFree,
                     filesystemTotalBytes: total, filesystemFreeBytes: free,
                     importantUsageAvailableBytes: important, opportunisticUsageAvailableBytes: opportunistic,
                     volumes: volumes, snapshots: snapshots, failures: failures)
}

private func syntheticScan(_ rows: [FolderUsage], scannedFiles: Int = 10, denied: Int = 0,
                           symlinks: Int = 0, placeholders: Int = 0, mounts: Int = 0,
                           cancelled: Bool = false, timed: Bool = false) -> FolderScanResult {
    FolderScanResult(rootURL: URL(fileURLWithPath: "/Users/tester"), rows: rows, scannedFiles: scannedFiles,
                     deniedCount: denied, skippedSymlinks: symlinks, skippedCloudPlaceholders: placeholders,
                     skippedMounts: mounts, wasCancelled: cancelled, wasTimeLimited: timed, date: Date())
}

private func row(_ name: String, allocated: UInt64, apparent: UInt64? = nil, shared: Int = 0,
                 denied: Int = 0, partial: Bool = false) -> FolderUsage {
    FolderUsage(url: URL(fileURLWithPath: "/Users/tester/\(name)"), allocatedBytes: allocated,
                apparentBytes: apparent ?? allocated, sharedBlockFiles: shared, isDirectory: true,
                deniedCount: denied, isPartial: partial)
}

let accountingChecks: [(String, () throws -> Void)] = [
    ("Derived capacity arithmetic clamps and propagates absence", {
        let full = syntheticAccounting()
        try expect(full.purgeableBytes == 4 * gib, "Purgeable is the Finder-minus-statvfs gap")
        try expect(full.reservedForSiblingsBytes == gib, "Volume advertises more than the container holds")
        try expect(full.unattributedBytes == Int64(500 * gib - 39 * gib),
                   "Without per-volume data the whole used pool is unattributed")
        try expect(syntheticAccounting(containerTotal: nil, containerFree: nil).unattributedBytes == nil,
                   "A missing container figure must stay missing")
        let noHint = syntheticAccounting(important: nil, opportunistic: nil)
        try expect(noHint.purgeableBytes == nil, "A missing hint must not become a zero")
        try expect(syntheticAccounting(free: 44 * gib, containerFree: 40 * gib, important: 40 * gib)
            .purgeableBytes == 0, "Purgeable must clamp at zero, not go negative")
        let withVolumes = syntheticAccounting(volumes: [APFSVolumeUsage(identifier: "disk3s5", name: "Data",
                                                                        roles: ["Data"], capacityInUseBytes: 400 * gib),
                                                        APFSVolumeUsage(identifier: "disk3s6", name: "VM",
                                                                        roles: ["VM"], capacityInUseBytes: 20 * gib)])
        try expect(withVolumes.unattributedBytes == Int64(500 * gib - 39 * gib - 420 * gib),
                   "Unattributed is what the volume totals cannot explain")
        try expect(withVolumes.nonDataUsedBytes == 20 * gib && withVolumes.dataVolumeUsedBytes == 400 * gib,
                   "Data and non-Data usage must be separated")
    }),
    ("diskutil plist shapes parse without guessing", {
        let list: [String: Any] = ["Containers": [[
            "ContainerReference": "disk3", "CapacityCeiling": Int64(500_000_000_000),
            "CapacityFree": Int64(39_000_000_000),
            "Volumes": [
                ["DeviceIdentifier": "disk3s5", "Name": "Data", "Roles": ["Data"], "CapacityInUse": Int64(123)],
                ["DeviceIdentifier": "disk3s6", "Name": "VM", "Roles": ["VM"], "CapacityInUse": Int64(-5)],
                ["DeviceIdentifier": "disk3s7", "Name": "NoSize", "Roles": ["Other"]],
            ],
        ]]]
        try expect(DiskutilPlist.container(list, containingVolume: "disk3s5") != nil, "Volume lookup failed")
        try expect(DiskutilPlist.container(list, containingVolume: "disk9s9") == nil, "Unrelated volume matched")
        let volumes = DiskutilPlist.volumes(DiskutilPlist.container(list, containingVolume: "disk3s5")!)
        try expect(volumes.count == 1 && volumes[0].capacityInUseBytes == 123,
                   "Negative or missing sizes must be dropped rather than zeroed")
        let snapshots: [String: Any] = ["Snapshots": [
            ["SnapshotName": "com.apple.os.update-ABC", "Purgeable": false, "LimitingContainerShrink": false],
            ["SnapshotName": "com.apple.TimeMachine.2026-11-20-010203", "Purgeable": true,
             "LimitingContainerShrink": true],
            ["SnapshotName": "user-made", "Purgeable": true],
            ["XID": Int64(1)],
        ]]
        let parsed = DiskutilPlist.snapshots(snapshots, volumeIdentifier: "disk3s5")
        try expect(parsed.count == 3, "Unnamed snapshot entries must be dropped")
        try expect(parsed[0].kind == .systemUpdate && parsed[1].kind == .timeMachine && parsed[2].kind == .other,
                   "Snapshot kinds classify by name")
        try expect(parsed[1].limitsContainerShrink && !parsed[2].limitsContainerShrink,
                   "Missing shrink flag reads as false, present flag reads as true")
    }),
    ("Findings respect thresholds and report gaps instead of zeroes", {
        let small = StorageReconciliation.findings(accounting: syntheticAccounting(free: 40 * gib,
                                                                                   important: 40 * gib + 50_000_000),
                                                   scan: nil)
        try expect(!small.contains { $0.id == "purgeable-space" }, "A 50 MB rounding gap is not a finding")
        let withVolumes = syntheticAccounting(volumes: [
            APFSVolumeUsage(identifier: "disk3s5", name: "Data", roles: ["Data"], capacityInUseBytes: 400 * gib),
            APFSVolumeUsage(identifier: "disk3s6", name: "VM", roles: ["VM"], capacityInUseBytes: 20 * gib)])
        let ids = StorageReconciliation.findings(accounting: withVolumes, scan: nil).map(\.id)
        try expect(ids.contains("purgeable-space") && ids.contains("container-reserve")
                       && ids.contains("outside-home") && !ids.contains("apfs-snapshots"),
                   "Expected findings for the synthetic container")
        try expect(!StorageReconciliation.findings(accounting: syntheticAccounting(), scan: nil).map(\.id)
                .contains("outside-home"), "No volume data means no claim about hidden volumes")
        let broken = StorageReconciliation.findings(accounting: syntheticAccounting(volumes: [
            APFSVolumeUsage(identifier: "disk3s1", name: "Macintosh HD", roles: ["System"],
                            capacityInUseBytes: 18 * gib)],
            snapshots: SnapshotInventory(snapshots: [APFSSnapshot(volumeIdentifier: "disk3s1",
                                                                  name: "com.apple.os.update-X",
                                                                  isPurgeable: false, limitsContainerShrink: false)],
                                         volumesExamined: 1, unreadableVolumeIdentifiers: ["disk3s3"]),
            failures: ["diskutil apfs list failed."]), scan: nil)
        try expect(broken.filter { $0.id == "measurement-failed" }.count == 1, "Each failure gets its own finding")
        try expect(broken.contains { $0.id == "apfs-snapshots" }, "Snapshot presence must be reported")
        try expect(broken.first { $0.id == "apfs-snapshots" }?.bytes == nil,
                   "Snapshot byte size is unavailable and must stay absent, not zero")
        try expect(broken.contains { $0.id == "outside-home" }, "Non-Data usage must be reported")
    }),
    ("Reclaim confidence degrades exactly as the evidence does", {
        let clean = syntheticScan([row("a", allocated: 5 * gib)])
        let plan = StorageReconciliation.plan(from: clean, accounting: nil, limit: 10)
        try expect(plan.candidates.first?.confidence == .measured, "Exclusive blocks and full coverage measure")
        try expect(plan.candidates.first?.deletesAutomatically == false, "A plan must never claim automation")
        try expect(plan.candidates.first?.estimatedFreeBytes == 5 * gib, "Estimate is the allocation")

        let shared = StorageReconciliation.plan(from: syntheticScan([row("a", allocated: 5 * gib, shared: 3)]),
                                                accounting: nil, limit: 10)
        try expect(shared.candidates.first?.confidence == .qualified, "Shared blocks lower confidence")
        let pinned = StorageReconciliation.plan(from: clean, accounting: syntheticAccounting(
            volumes: [APFSVolumeUsage(identifier: "disk3s1", name: "Macintosh HD", roles: ["System"],
                                      capacityInUseBytes: gib)],
            snapshots: SnapshotInventory(snapshots: [APFSSnapshot(volumeIdentifier: "disk3s1",
                                                                  name: "com.apple.TimeMachine.2026",
                                                                  isPurgeable: false, limitsContainerShrink: false)],
                                         volumesExamined: 1, unreadableVolumeIdentifiers: [])), limit: 10)
        try expect(pinned.candidates.first?.confidence == .qualified, "A non-purgeable snapshot lowers confidence")
        let partial = StorageReconciliation.plan(from: syntheticScan([row("a", allocated: 5 * gib, partial: true)]),
                                                 accounting: nil, limit: 10)
        try expect(partial.candidates.first?.confidence == .low, "An unfinished subtree is a floor, not a figure")

        let mixed = syntheticScan([row("small", allocated: 10 * gib), row("tiny", allocated: 1000),
                                   row("mid", allocated: 12 * gib)])
        let ranked = StorageReconciliation.plan(from: mixed, accounting: nil, limit: 2)
        try expect(ranked.candidates.map(\.name) == ["mid", "small"], "Ranking is by allocation, floor applies")
        try expect(ranked.totalEstimatedFreeBytes == 22 * gib, "Total covers only the candidates listed")

        let messy = StorageReconciliation.plan(from: syntheticScan([row("a", allocated: 5 * gib)],
                                                                   symlinks: 4, placeholders: 2, cancelled: true),
                                               accounting: nil, limit: 10)
        try expect(messy.limits.contains { $0.contains("floors") }, "Cancellation must appear in limits")
        try expect(messy.limits.contains { $0.contains("4 symbolic links") }, "Skipped links must appear in limits")
        try expect(messy.limits.contains { $0.contains("2 cloud-only placeholders") },
                   "Skipped placeholders must appear in limits")
        try expect(messy.guarantees == ReclaimPlan.guarantees, "Guarantees are the published constant")
    }),
]

let jsonContractChecks: [(String, () throws -> Void)] = [
    ("Machine output carries the derived readings and survives a round trip", {
        let volumes = [APFSVolumeUsage(identifier: "disk3s5", name: "Data", roles: ["Data"],
                                       capacityInUseBytes: 400 * gib),
                       APFSVolumeUsage(identifier: "disk3s6", name: "VM", roles: ["VM"],
                                       capacityInUseBytes: 20 * gib)]
        let snapshots = SnapshotInventory(snapshots: [APFSSnapshot(volumeIdentifier: "disk3s1",
                                                                   name: "com.apple.os.update-X",
                                                                   isPurgeable: false, limitsContainerShrink: true)],
                                          volumesExamined: 6, unreadableVolumeIdentifiers: ["disk3s3"])
        let original = syntheticAccounting(volumes: volumes, snapshots: snapshots)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(original)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["\"purgeable_bytes\"", "\"reserved_for_siblings_bytes\"", "\"unattributed_bytes\"",
                    "\"non_data_used_bytes\"", "\"data_volume_used_bytes\"", "\"count\"",
                    "\"non_purgeable_count\"", "\"shrink_limiting_count\"", "\"is_complete\""] {
            try expect(text.contains(key), "Derived reading \(key) is missing from machine output")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(VolumeAccounting.self, from: data)
        try expect(decoded.filesystemFreeBytes == original.filesystemFreeBytes
                       && decoded.volumes.count == 2 && decoded.snapshots?.count == 1,
                   "Round trip lost stored measurements")
        try expect(decoded.purgeableBytes == original.purgeableBytes
                       && decoded.unattributedBytes == original.unattributedBytes,
                   "Recomputed derived readings disagree with the encoded ones")
        try expect(ReclaimPlan.schemaVersion == decoded.schemaVersion, "Schema version must round trip")
    }),
]

let scannerTruthChecks: [(String, () throws -> Void)] = [
    ("Sparse files report allocation and length separately", {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sparse.bin")
        try expect(FileManager.default.createFile(atPath: file.path, contents: nil), "Sparse fixture")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 64 * 1_048_576)
        try handle.close()
        let result = FolderScanner().scan(url: root)
        let entry = result.rows.first { $0.name == "sparse.bin" }
        try expect(entry?.allocatedBytes != nil && entry!.allocatedBytes < 1_000_000, "Sparse allocation leaked")
        try expect(result.totalApparentBytes >= 64 * 1_048_576, "Apparent length was not summed")
        try expect(result.totalApparentBytes > result.totalAllocatedBytes, "The gap is the point of the measurement")
    }),
    ("Shared inodes are counted once but still disclosed", {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.bin")
        try Data(repeating: 0x41, count: 1_048_576).write(to: original)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("second.bin"))
        let result = FolderScanner().scan(url: root)
        try expect(result.scannedFiles == 1, "The second link must be deduplicated, not recounted")
        try expect(result.totalSharedBlockFiles == 1, "A hardlinked file must be disclosed as shared")
        try expect(result.totalAllocatedBytes < 2 * 1_048_576, "Shared blocks were counted twice")
    }),
]
