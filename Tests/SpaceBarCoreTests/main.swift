import Foundation
import Darwin
import SpaceBarCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

func fixture() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("SpaceBarTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

func blocks(_ url: URL) throws -> UInt64 {
    var info = stat()
    try expect(lstat(url.path, &info) == 0, "Fixture stat failed")
    return UInt64(max(0, info.st_blocks)) * 512
}

let checks: [(String, () throws -> Void)] = [
    ("CPU delta normalization, zero delta and reset", {
        let old = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let now = CPUTicks(user: 150, system: 100, idle: 950, nice: 0)
        try expect(now.utilization(since: old) == 50, "Expected half busy interval")
        try expect(old.utilization(since: old) == nil, "Zero interval must be unavailable")
        try expect(old.utilization(since: now) == nil, "Reset must be unavailable")
        try expect(CPUTicks(user: 200, system: 100, idle: 850, nice: 0).utilization(since: old) == 100, "Expected fully busy interval")
    }),
    ("Single-filesystem disk capacity", {
        let disk = DiskSnapshot(totalBytes: 1_000, freeBytes: 300)
        try expect(disk.usedBytes == 700 && disk.usedFraction == 0.7, "Capacity arithmetic")
        try expect(DiskSnapshot(totalBytes: 0, freeBytes: 500).usedFraction == 0, "Zero capacity")
        try expect(DiskSnapshot(totalBytes: 100, freeBytes: 500).freeBytes == 100, "Invalid free count must be capped")
    }),
    ("Process parser keeps executable spaces and handles multicore percentages", {
        let input = """
         123 203.5 2048 /Applications/My App.app/Contents/MacOS/My App
         99 0.2 4096 /usr/bin/python3
         0 0.0 0 kernel_task
         3 NaN 10 invalid
         corrupt entry
        """
        let cpu = ProcessSampler.parse(input, sort: .cpu, limit: 5)
        try expect(cpu.count == 2 && cpu.first?.pid == 123, "Invalid row filtering/CPU ordering")
        try expect(cpu.first?.name == "My App", "Executable names with spaces")
        try expect(cpu.first?.memoryBytes == 2_097_152, "RSS KiB conversion")
        try expect(ProcessSampler.parse(input, sort: .memory, limit: 1).first?.pid == 99, "Memory ordering")
        try expect(ProcessSampler.parse(input, sort: .cpu, limit: 0).isEmpty, "Zero limit")
    }),
    ("Hardlink deduplication and symlink exclusion", {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("large.bin")
        try Data(repeating: 0x24, count: 1_048_576).write(to: original)
        try FileManager.default.linkItem(at: original, to: directory.appendingPathComponent("hardlink.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/Applications"))
        let report = FolderScanner().scan(url: root)
        try expect(report.rows.count == 2 && report.skippedSymlinks == 1, "Symlink must remain untraversed")
        try expect(!report.wasCancelled && !report.wasTimeLimited && report.deniedCount == 0, "Fixture coverage")
        let expected = try blocks(original) + blocks(directory)
        try expect(report.rows.first { $0.name == "data" }?.allocatedBytes == expected, "Hardlink bytes counted more than once")
        try expect(report.rows.first { $0.name == "outside" }?.allocatedBytes == 0, "Symlink target data leaked into scan")
    }),
    ("A selected root symlink is not followed", {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data([0x31]).write(to: target.appendingPathComponent("inside"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let report = FolderScanner().scan(url: alias)
        try expect(report.scannedFiles == 0 && report.deniedCount == 1 && report.isPartial, "Selected root symlink was resolved before the no-follow check")
    }),
    ("Directory replacement cannot redirect a scan through a symlink", {
        let fixtureRoot = try fixture()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let root = fixtureRoot.appendingPathComponent("scan")
        let gate = root.appendingPathComponent("gate")
        let outside = fixtureRoot.appendingPathComponent("outside")
        let parked = fixtureRoot.appendingPathComponent("parked")
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 0x5a, count: 1_048_576).write(to: outside.appendingPathComponent("must-not-count.bin"))
        var replaced = false
        var mutationError: Error?
        let report = FolderScanner().scan(url: root, progress: { _, entry in
            guard entry.lastPathComponent == "gate", !replaced else { return }
            do {
                try FileManager.default.moveItem(at: gate, to: parked)
                try FileManager.default.createSymbolicLink(at: gate, withDestinationURL: outside)
                replaced = true
            } catch { mutationError = error }
        })
        if let mutationError { throw mutationError }
        try expect(replaced, "Deterministic replacement fixture did not run")
        try expect(report.scannedFiles == 1, "Replacement followed the outside directory")
        try expect(report.skippedSymlinks == 1 && report.isPartial, "Changed path must be reported as incomplete")
        try expect(report.totalAllocatedBytes < 1_048_576, "Outside payload allocation entered the scan")
    }),
    ("Cancellation during traversal stops promptly with partial coverage", {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        for index in 0..<200 { try Data([0x31]).write(to: tree.appendingPathComponent("file-\(index)")) }
        var stop = false
        let report = FolderScanner().scan(url: root, cancelled: { stop }, progress: { _, _ in stop = true })
        try expect(report.wasCancelled && report.isPartial, "Mid-scan cancellation lost")
        try expect(report.scannedFiles == 1, "Traversal continued after cancellation callback")
    }),
    ("Deep directory coverage is bounded and reported partial", {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var leaf = root
        for _ in 0..<75 {
            leaf.appendPathComponent("d")
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: false)
        }
        try Data([0x31]).write(to: leaf.appendingPathComponent("too-deep"))
        let report = FolderScanner().scan(url: root)
        try expect(report.isPartial && report.deniedCount == 1, "Depth coverage limit was hidden")
        try expect(report.scannedFiles == 64, "Descriptor depth was not bounded")
    }),
    ("Sparse files use allocated blocks", {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sparse.bin")
        try expect(FileManager.default.createFile(atPath: file.path, contents: nil), "Create sparse fixture")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 512 * 1_048_576)
        try handle.close()
        let report = FolderScanner().scan(url: root)
        let allocated = try blocks(file)
        try expect(report.totalAllocatedBytes == allocated, "Sparse allocation mismatch")
        try expect(report.totalAllocatedBytes < 512 * 1_048_576, "Logical bytes were counted as allocated")
    }),
    ("Cancellation and time limit are explicit", {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("one"))
        let cancelled = FolderScanner().scan(url: root, cancelled: { true })
        try expect(cancelled.wasCancelled && cancelled.isPartial && cancelled.scannedFiles == 0, "Cancellation not propagated")
        let timed = FolderScanner(timeLimit: 0).scan(url: root)
        try expect(timed.wasTimeLimited && timed.isPartial, "Time limit not propagated")
    }),
    ("Missing root is unreadable rather than empty success", {
        let result = FolderScanner().scan(url: URL(fileURLWithPath: "/private/tmp/spacebar-no-such-root-\(UUID())"))
        try expect(result.deniedCount == 1 && result.isPartial && result.rows.isEmpty, "Missing root silently succeeded")
    }),
    ("Permission gaps remain visible", {
        guard getuid() != 0 else { throw CheckFailure(description: "Run the permission fixture as an ordinary user") }
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let protected = root.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: protected.appendingPathComponent("inside"))
        try expect(chmod(protected.path, 0) == 0, "Protect fixture")
        defer { chmod(protected.path, 0o700) }
        let result = FolderScanner().scan(url: root)
        try expect(result.deniedCount == 1 && result.isPartial, "Permission gap not reported")
        try expect(result.rows.first?.deniedCount == 1 && result.rows.first?.isPartial == true, "Row coverage should be partial")
    }),
    ("Native snapshot has one real capacity and no invented first CPU sample", {
        let sampler = SystemSampler()
        let first = sampler.sample()
        try expect(first.cpuPercent == nil, "First CPU sample must need a previous reading")
        try expect(first.memoryTotalBytes == ProcessInfo.processInfo.physicalMemory, "Physical memory mismatch")
        try expect(first.disk.totalBytes > 0 && first.disk.freeBytes <= first.disk.totalBytes, "Disk capacity unavailable")
        try expect(first.memoryUsedBytes <= first.memoryTotalBytes, "Memory estimate exceeded physical memory")
        if let gpu = first.gpuPercent { try expect((0...100).contains(gpu), "GPU percentage outside range") }
    }),
] + memoryChecks + trashChecks + accountingChecks + jsonContractChecks + scannerTruthChecks

var failures = 0
for (name, action) in checks {
    do { try action(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
print("\(checks.count - failures)/\(checks.count) SpaceBar core checks passed")
exit(failures == 0 ? 0 : 1)
