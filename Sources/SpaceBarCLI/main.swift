import Foundation
import SpaceBarCore

/// Machine-facing entry point. Every command answers as JSON on stdout so an agent can read the
/// same numbers the app shows; progress and errors go to stderr and never mix into the payload.
let cli = CLISurface(arguments: Array(CommandLine.arguments.dropFirst()))
exit(cli.run())

struct CLISurface {
    static let tool = "spacebar"
    static let schemaVersion = 1

    let arguments: [String]

    func run() -> Int32 {
        let options = Options(arguments)
        switch options.command {
        case "help", "":
            print(Self.usage)
            return 0
        case "schema":
            return emit(Self.contract, json: true)
        case "status":
            return status(options)
        case "volume":
            return volume(options)
        case "scan":
            return scan(options)
        case "reclaim":
            return reclaim(options)
        case "explain":
            return explain(options)
        default:
            FileHandle.standardError.write("Unknown command: \(options.command)\n\n\(Self.usage)\n".data)
            return 1
        }
    }

    static let usage = """
    spacebar — measure what macOS actually holds, and what deleting would return.

    Commands
      status   System snapshot: CPU, memory, pressure, swap, GPU, capacity.
      volume   APFS reconciliation: statvfs vs container vs Finder's purgeable estimate, per-volume
               usage across the container, snapshot inventory.
      scan     Folder sizes by allocated blocks. Usage: spacebar scan [path]
      reclaim  Dry-run reclaim plan for a scan: measured blocks, confidence, reasons.
      explain  Prose answer to "why is my storage full when I deleted 40 GB?".
      schema   The JSON contract, field by field.
      help     This text.

    Flags
      --json              Machine-readable output (implied for reclaim, scan and volume too when set).
      --limit N           Rows kept (default 12).
      --seconds N         Scan time limit (default 120).
      --no-snapshots      Skip the per-volume snapshot calls (faster, less complete).

    Exit codes
      0  Measurement complete.
      2  Partial coverage: see coverage_notes / findings before acting on the numbers.
      1  The measurement failed outright; nothing was invented in its place.

    Spacebar never deletes, empties Trash, terminates processes, uploads, or runs privileged helpers.
    """

    static let contract: [String: Any] = [
        "tool": tool,
        "schema_version": schemaVersion,
        "commands": ["status", "volume", "scan", "reclaim", "explain", "schema"],
        "exit_codes": ["0": "complete", "2": "partial coverage", "1": "measurement failed"],
        "units": "decimal bytes (1 GB = 1_000_000_000); all_*_bytes fields are integers",
        "document": [
            "ok": "false only when the measurement itself failed",
            "coverage": "complete | partial | failed",
            "measured_at": "ISO 8601",
            "accounting.filesystem_free_bytes": "statvfs blocks a plain write can take now",
            "accounting.important_usage_available_bytes": "what Finder calls available; equals free + purgeable",
            "accounting.purgeable_bytes": "derived: important_usage_available_bytes - filesystem_free_bytes",
            "accounting.opportunistic_usage_available_bytes": "space an app may claim without forcing eviction",
            "accounting.container_free_bytes": "the shared APFS pool, not this volume alone",
            "accounting.reserved_for_siblings_bytes": "derived: filesystem_free_bytes - container_free_bytes",
            "accounting.volumes[]": "every volume in the container with capacity_in_use_bytes and roles",
            "accounting.non_data_used_bytes": "usage on volumes a home-directory scan cannot reach",
            "accounting.unattributed_bytes": "container_total - container_free - sum(per-volume in use); may be negative",
            "accounting.snapshots[]": "name, kind, is_purgeable, limits_container_shrink; sizes are not exposed unprivileged",
            "findings[]": "id, severity (note|caution|important), title, detail, bytes, action",
            "scan.rows[]": "allocated_bytes (blocks, once per inode), apparent_bytes (file lengths), shared_block_files",
            "plan.candidates[]": "path, estimated_free_bytes, confidence (measured|qualified|low), reasons[], action",
            "plan.guarantees[]": "what an agent may rely on",
            "plan.limits[]": "why a total may be a floor rather than a sum",
        ],
        "guarantees": ReclaimPlan.guarantees,
        "limits": [
            "APFS clone extents and snapshot byte sizes are not exposed to an unprivileged process; "
                + "shared sizes are reported as estimates with lower confidence, never as guarantees.",
            "Cloud-only placeholders and other filesystems are skipped rather than counted.",
            "Scan totals count each inode once, so attribution can differ between sibling scans.",
        ],
    ]

    // MARK: commands

    private func status(_ options: Options) -> Int32 {
        let snapshot = SystemSampler().sample()
        let accounting = VolumeAccountingProbe(includeSnapshots: !options.noSnapshots).measure()
        var document: [String: Any] = [
            "ok": true,
            "coverage": accounting.failures.isEmpty ? "complete" : "partial",
            "measured_at": iso(snapshot.date),
            "system": json(of: snapshot),
            "free_space": [
                "filesystem_free_bytes": accounting.filesystemFreeBytes,
                "purgeable_bytes": accounting.purgeableBytes.map(NSNumber.init(value:)),
                "container_free_bytes": accounting.containerFreeBytes.map(NSNumber.init(value:)),
                "important_usage_available_bytes": accounting.importantUsageAvailableBytes.map(NSNumber.init(value:)),
            ],
        ]
        if options.json {
            document["accounting"] = json(of: accounting)
            document["findings"] = json(of: StorageReconciliation.findings(accounting: accounting, scan: nil))
        }
        if !options.json {
            print(summary(snapshot, accounting))
            return 0
        }
        return emit(document, json: true)
    }

    private func volume(_ options: Options) -> Int32 {
        let accounting = VolumeAccountingProbe(includeSnapshots: !options.noSnapshots).measure()
        let findings = StorageReconciliation.findings(accounting: accounting, scan: nil)
        if !options.json {
            print(prettyAccounting(accounting))
            for finding in findings { print("  • \(finding.title)  \(finding.detail)") }
            return accounting.failures.isEmpty ? 0 : 2
        }
        return emit([
            "ok": accounting.failures.isEmpty,
            "coverage": accounting.failures.isEmpty ? "complete" : "partial",
            "measured_at": iso(accounting.measuredAt),
            "accounting": json(of: accounting),
            "findings": json(of: findings),
        ], json: true)
    }

    private func scan(_ options: Options) -> Int32 {
        guard let root = options.pathURL else {
            FileHandle.standardError.write("scan needs a readable directory path.\n".data)
            return 1
        }
        let result = FolderScanner(timeLimit: options.seconds).scan(url: root)
        if result.rows.isEmpty && result.deniedCount > 0 {
            FileHandle.standardError.write("Unreadable root: \(root.path)\n".data)
            if !options.json { return 1 }
            return emit(["ok": false, "coverage": "failed", "root": result.rootURL.path,
                         "failures": ["Root could not be read."]], json: true)
        }
        if !options.json {
            print(prettyScan(result))
            for finding in StorageReconciliation.findings(accounting: nil, scan: result) {
                print("  • \(finding.title)  \(finding.detail)")
            }
            return result.isPartial ? 2 : 0
        }
        return emit([
            "ok": true,
            "coverage": result.isPartial ? "partial" : "complete",
            "measured_at": iso(result.date),
            "scan": json(of: result),
            "findings": json(of: StorageReconciliation.findings(accounting: nil, scan: result)),
        ], json: true)
    }

    private func reclaim(_ options: Options) -> Int32 {
        guard let root = options.pathURL else {
            FileHandle.standardError.write("reclaim needs a readable directory path.\n".data)
            return 1
        }
        let scanResult = FolderScanner(timeLimit: options.seconds).scan(url: root)
        let accounting = VolumeAccountingProbe(includeSnapshots: !options.noSnapshots).measure()
        let plan = StorageReconciliation.plan(from: scanResult, accounting: accounting, limit: options.limit)
        let findings = StorageReconciliation.findings(accounting: accounting, scan: scanResult)
        if !options.json {
            print("Reclaim plan for \(root.path) — dry run, nothing will be deleted.")
            for candidate in plan.candidates {
                print("  \(pad(StorageReconciliation.bytes(candidate.estimatedFreeBytes), 10)) "
                    + "\(candidate.confidence.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) "
                    + "\(candidate.path)")
                for reason in candidate.reasons { print("      - \(reason)") }
            }
            print("Total estimate: \(StorageReconciliation.bytes(plan.totalEstimatedFreeBytes)) across "
                + "\(plan.candidates.count) of \(plan.scannedRows) rows.")
            for limit in plan.limits { print("Limit: \(limit)") }
            return scanResult.isPartial ? 2 : 0
        }
        return emit([
            "ok": true,
            "coverage": scanResult.isPartial || !accounting.failures.isEmpty ? "partial" : "complete",
            "measured_at": iso(plan.generatedAt),
            "plan": json(of: plan),
            "accounting": json(of: accounting),
            "findings": json(of: findings),
        ], json: true)
    }

    private func explain(_ options: Options) -> Int32 {
        let accounting = VolumeAccountingProbe(includeSnapshots: !options.noSnapshots).measure()
        let findings = StorageReconciliation.findings(accounting: accounting, scan: nil)
        if options.json {
            return emit(["ok": true, "measured_at": iso(accounting.measuredAt),
                        "accounting": json(of: accounting), "findings": json(of: findings)], json: true)
        }
        print("Free \(StorageReconciliation.bytes(accounting.filesystemFreeBytes)) on "
            + "\(accounting.volumeName ?? "this volume") "
            + "(total \(StorageReconciliation.bytes(accounting.filesystemTotalBytes))).")
        if let purgeable = accounting.purgeableBytes {
            print("Finder counts \(StorageReconciliation.bytes(purgeable)) more as available because macOS "
                + "will evict purgeable caches, thin iCloud files and system data before it reports full.")
        }
        if let reserve = accounting.reservedForSiblingsBytes, reserve >= 100_000_000 {
            print("\(StorageReconciliation.bytes(reserve)) of that is space the container does not hold yet: "
                + "the System, VM and Update volumes can take it before this volume looks full.")
        }
        if !accounting.volumes.isEmpty {
            print("Outside your home directory the container holds "
                + "\(StorageReconciliation.bytes(accounting.nonDataUsedBytes)): "
                + accounting.volumes.filter { !$0.roles.contains("Data") }
                    .sorted { $0.capacityInUseBytes > $1.capacityInUseBytes }
                    .prefix(4).map { "\($0.name) \(StorageReconciliation.bytes($0.capacityInUseBytes))" }
                    .joined(separator: ", ") + ".")
        }
        if let snapshots = accounting.snapshots, snapshots.count > 0 {
            print("\(snapshots.count) APFS snapshot(s) pin blocks; "
                + "\(snapshots.byteSizeReason.lowercased(with: Locale(identifier: "en_US")))")
        }
        print("So deleting files returns block-for-block what the scan measured — minus anything a "
            + "snapshot or a shared clone holds.")
        return accounting.failures.isEmpty ? 0 : 2
    }

    // MARK: human output

    private func summary(_ snapshot: SystemSnapshot, _ accounting: VolumeAccounting) -> String {
        var lines = ["\(iso(snapshot.date))",
                     "Disk free \(StorageReconciliation.bytes(accounting.filesystemFreeBytes)) of "
                        + "\(StorageReconciliation.bytes(accounting.filesystemTotalBytes))"]
        if let purgeable = accounting.purgeableBytes {
            lines.append("  + \(StorageReconciliation.bytes(purgeable)) purgeable per macOS")
        }
        lines.append("CPU \(snapshot.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "pending")")
        lines.append("Memory \(StorageReconciliation.bytes(snapshot.memoryUsedBytes)) of "
            + "\(StorageReconciliation.bytes(snapshot.memoryTotalBytes)), pressure \(snapshot.pressure.rawValue)")
        lines.append("Compressed \(StorageReconciliation.bytes(snapshot.compressedBytes)), swap "
            + "\(StorageReconciliation.bytes(snapshot.swapUsedBytes))")
        if let gpu = snapshot.gpuPercent { lines.append(String(format: "GPU %.0f%%", gpu)) }
        return lines.joined(separator: "\n")
    }

    private func prettyAccounting(_ accounting: VolumeAccounting) -> String {
        var lines = ["Volume \(accounting.volumeName ?? accounting.mountPoint) "
            + "(\(accounting.volumeIdentifier ?? "?")) in container \(accounting.containerIdentifier ?? "?")",
            "  filesystem free  \(StorageReconciliation.bytes(accounting.filesystemFreeBytes)) of "
                + "\(StorageReconciliation.bytes(accounting.filesystemTotalBytes))"]
        if let free = accounting.containerFreeBytes {
            lines.append("  container free   \(StorageReconciliation.bytes(free))")
        }
        if let important = accounting.importantUsageAvailableBytes {
            lines.append("  Finder available \(StorageReconciliation.bytes(important))")
        }
        if let purgeable = accounting.purgeableBytes {
            lines.append("  purgeable        \(StorageReconciliation.bytes(purgeable))")
        }
        if let opportunistic = accounting.opportunisticUsageAvailableBytes {
            lines.append("  opportunistic    \(StorageReconciliation.bytes(opportunistic))")
        }
        for volume in accounting.volumes.sorted(by: { $0.capacityInUseBytes > $1.capacityInUseBytes }) {
            lines.append("  \(pad(volume.name, 16)) \(pad(StorageReconciliation.bytes(volume.capacityInUseBytes), 10)) "
                + "\(volume.roles.joined(separator: ","))")
        }
        if let snapshots = accounting.snapshots {
            lines.append("  snapshots        \(snapshots.count) across \(snapshots.volumesExamined) volumes, "
                + "\(snapshots.nonPurgeableCount) not purgeable")
        }
        if let unattributed = accounting.unattributedBytes {
            lines.append("  unattributed     \(unattributed >= 0 ? "+" : "-")"
                + "\(StorageReconciliation.bytes(UInt64(abs(unattributed))))")
        }
        return lines.joined(separator: "\n")
    }

    private func prettyScan(_ result: FolderScanResult) -> String {
        var lines = ["Scan of \(result.rootURL.path): \(result.rows.count) rows, "
            + "\(result.scannedFiles) entries, allocated "
            + "\(StorageReconciliation.bytes(result.totalAllocatedBytes)), apparent "
            + "\(StorageReconciliation.bytes(result.totalApparentBytes))"]
        for row in result.rows.prefix(25) {
            lines.append("  \(pad(StorageReconciliation.bytes(row.allocatedBytes), 10)) "
                + "\(pad(row.sharedBlockFiles > 0 ? "shared:\(row.sharedBlockFiles)" : "", 12)) \(row.url.path)")
        }
        return lines.joined(separator: "\n")
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    // MARK: encoding

    private func emit(_ document: [String: Any], json: Bool) -> Int32 {
        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(withJSONObject: document,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            FileHandle.standardError.write("Internal encoding failure.\n".data)
            return 1
        }
        FileHandle.standardOutput.write(data + Data([0x0A]))
        return document["coverage"] as? String == "partial" ? 2 : 0
    }

    private func json(of value: Encodable) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [String: Any]() }
        return object
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    struct Options {
        let command: String
        let json: Bool
        let limit: Int
        let seconds: TimeInterval
        let noSnapshots: Bool
        let pathURL: URL?

        private static let commands: Set<String> =
            ["status", "volume", "scan", "reclaim", "explain", "schema", "help"]

        init(_ arguments: [String]) {
            var command = "status"
            var json = false
            var limit = 12
            var seconds = 120.0
            var noSnapshots = false
            var path: String?
            var index = 0
            var expects: String?
            while index < arguments.count {
                let token = arguments[index]
                if let pending = expects {
                    switch pending {
                    case "limit": if let value = Int(token), value >= 0 { limit = value }
                    case "seconds": if let value = Double(token), value >= 1 { seconds = value }
                    case "path": path = token
                    default: break
                    }
                    expects = nil
                    index += 1
                    continue
                }
                switch token {
                case "--json": json = true
                case "--no-snapshots": noSnapshots = true
                case "--limit": expects = "limit"
                case "--seconds": expects = "seconds"
                case "--path": expects = "path"
                default:
                    if token.hasPrefix("-") {
                        FileHandle.standardError.write(Data("Ignoring unknown flag: \(token)\n".utf8))
                    } else if Self.commands.contains(token) {
                        command = token
                    } else if path == nil {
                        path = token
                    }
                }
                index += 1
            }
            self.command = command
            self.json = json
            self.limit = limit
            self.seconds = seconds
            self.noSnapshots = noSnapshots
            if let path {
                pathURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            } else if command == "scan" || command == "reclaim" {
                pathURL = URL(fileURLWithPath: NSHomeDirectory())
            } else {
                pathURL = nil
            }
        }
    }
}

private extension String {
    var data: Data { Data(utf8) }
}
