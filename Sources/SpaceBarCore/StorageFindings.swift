import Foundation

/// The plain-English conclusions a reader acts on, each tied to the measurement that produced it.
public struct StorageFinding: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable { case note, caution, important }

    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    /// The byte count the finding is about, when the finding has one.
    public let bytes: UInt64?
    /// What actually changes the number. Omitted when nothing user-facing does.
    public let action: String?

    public init(id: String, severity: Severity, title: String, detail: String,
                bytes: UInt64?, action: String?) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.bytes = bytes
        self.action = action
    }
}

public enum ReclaimConfidence: String, Codable, Sendable {
    /// Blocks are counted once, coverage was complete, and nothing shares them elsewhere.
    case measured
    /// The number is right but returning it is uncertain: shared blocks or live snapshots.
    case qualified
    /// The scan did not finish, so the total is a floor rather than a figure.
    case low
}

/// One line of a dry-run plan: what deleting here would return, and how far to trust it.
public struct ReclaimCandidate: Codable, Sendable {
    public let path: String
    public let name: String
    public let allocatedBytes: UInt64
    public let apparentBytes: UInt64
    public let estimatedFreeBytes: UInt64
    public let sharedBlockFiles: Int
    public let confidence: ReclaimConfidence
    public let reasons: [String]
    /// Always the manual route. Spacebar has no permanent delete and no empty-trash action.
    public let action: String
    public let deletesAutomatically: Bool

    public init(path: String, name: String, allocatedBytes: UInt64, apparentBytes: UInt64,
                estimatedFreeBytes: UInt64, sharedBlockFiles: Int, confidence: ReclaimConfidence,
                reasons: [String], action: String, deletesAutomatically: Bool) {
        self.path = path
        self.name = name
        self.allocatedBytes = allocatedBytes
        self.apparentBytes = apparentBytes
        self.estimatedFreeBytes = estimatedFreeBytes
        self.sharedBlockFiles = sharedBlockFiles
        self.confidence = confidence
        self.reasons = reasons
        self.action = action
        self.deletesAutomatically = deletesAutomatically
    }
}

public struct ReclaimPlan: Codable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let rootPath: String
    public let scannedRows: Int
    public let candidates: [ReclaimCandidate]
    public let totalEstimatedFreeBytes: UInt64
    /// Statements an agent can rely on when deciding whether to act.
    public let guarantees: [String]
    public let limits: [String]

    public init(generatedAt: Date, rootPath: String, scannedRows: Int, candidates: [ReclaimCandidate],
                totalEstimatedFreeBytes: UInt64, guarantees: [String], limits: [String]) {
        self.schemaVersion = ReclaimPlan.schemaVersion
        self.generatedAt = generatedAt
        self.rootPath = rootPath
        self.scannedRows = scannedRows
        self.candidates = candidates
        self.totalEstimatedFreeBytes = totalEstimatedFreeBytes
        self.guarantees = guarantees
        self.limits = limits
    }

    public static let guarantees = [
        "Nothing here is deleted by Spacebar; every action is a confirmed move to Trash that you trigger.",
        "estimated_free_bytes counts filesystem blocks, measured once per inode.",
        "Sizes use decimal units (1 GB = 1_000_000_000 bytes).",
    ]
}

/// Turns raw measurements into findings and into a dry-run reclaim plan.
public enum StorageReconciliation {
    private static let reportFloor: UInt64 = 100_000_000

    public static func findings(accounting: VolumeAccounting?, scan: FolderScanResult?) -> [StorageFinding] {
        var found: [StorageFinding] = []
        if let accounting { accountingFindings(accounting, into: &found) }
        if let scan { scanFindings(scan, into: &found) }
        return found
    }

    private static func accountingFindings(_ accounting: VolumeAccounting, into found: inout [StorageFinding]) {
        if accounting.filesystemTotalBytes > 0 {
            let usedFraction = Double(accounting.filesystemTotalBytes - accounting.filesystemFreeBytes)
                / Double(accounting.filesystemTotalBytes)
            if usedFraction >= 0.95 {
                found.append(StorageFinding(id: "nearly-full", severity: .important,
                    title: "The volume is within 5% of full.",
                    detail: "macOS starts evicting caches on its own at this level, and Time Machine, "
                        + "Xcode and model downloads can fail before a manual cleanup finishes.",
                    bytes: accounting.filesystemFreeBytes,
                    action: "Free space first, then re-measure; purgeable caches may clear themselves."))
            }
        }
        if let purgeable = accounting.purgeableBytes, purgeable >= reportFloor {
            found.append(StorageFinding(id: "purgeable-space", severity: .note,
                title: "\(bytes(purgeable)) is purgeable, not used.",
                detail: "Finder counts this as available; statvfs does not. It is caches, thin iCloud "
                    + "placeholders and system data macOS evicts the moment something important needs room, "
                    + "so deleting files is not how that space comes back.",
                bytes: purgeable,
                action: "No action needed unless a write actually fails."))
        }
        if let reserve = accounting.reservedForSiblingsBytes, reserve >= reportFloor {
            found.append(StorageFinding(id: "container-reserve", severity: .caution,
                title: "This volume advertises \(bytes(reserve)) more free than the container holds.",
                detail: "APFS volumes share one block pool. The System, Update and VM volumes can take that "
                    + "space, so a write can fail while the volume still reports room.",
                bytes: reserve,
                action: "Compare container free space before sizing a large download."))
        }
        if accounting.nonDataUsedBytes >= reportFloor, !accounting.volumes.isEmpty {
            let ranked = accounting.volumes.filter { !$0.roles.contains("Data") }
                .sorted { $0.capacityInUseBytes > $1.capacityInUseBytes }
            let listed = ranked.prefix(3).map { "\($0.name) \(bytes($0.capacityInUseBytes))" }
                .joined(separator: ", ")
            found.append(StorageFinding(id: "outside-home", severity: .note,
                title: "\(bytes(accounting.nonDataUsedBytes)) lives on volumes no folder scan reaches.",
                detail: "Measured per volume: \(listed). Finder's System Data largely comes from here, "
                    + "which is why no home-directory cleanup app can explain it.",
                bytes: accounting.nonDataUsedBytes,
                action: "The VM volume is managed memory (swap) and the Update volume is staged installer data."))
        }
        if let unattributed = accounting.unattributedBytes {
            let magnitude = UInt64(abs(unattributed))
            if magnitude >= reportFloor {
                found.append(StorageFinding(id: unattributed >= 0 ? "container-unattributed" : "shared-block-double-count",
                    severity: .note,
                    title: unattributed >= 0
                        ? "\(bytes(magnitude)) of the container is not attributed to any volume."
                        : "Per-volume usage overlaps by \(bytes(magnitude)).",
                    detail: unattributed >= 0
                        ? "Snapshots, filesystem metadata and reserves sit here. This is the space a "
                            + "\"delete files\" plan cannot see, and it is why freed bytes land late."
                        : "Volumes report their own block counts, and blocks shared by clones are counted "
                            + "in more than one volume. Spacebar keeps the negative instead of hiding it.",
                    bytes: magnitude,
                    action: nil))
            }
        }
        if let snapshots = accounting.snapshots, snapshots.count > 0 {
            let kinds = Set(snapshots.snapshots.map(\.kind))
            found.append(StorageFinding(id: "apfs-snapshots", severity: snapshots.nonPurgeableCount > 0 ? .caution : .note,
                title: "\(snapshots.count) APFS snapshot(s) exist; \(snapshots.nonPurgeableCount) are not marked purgeable.",
                detail: "A snapshot pins the blocks it references, so deleting a file does not always return "
                    + "space immediately. Kinds present: \(kinds.map { $0.rawValue }.sorted().joined(separator: ", ")). "
                    + "\(snapshots.byteSizeReason)",
                bytes: nil,
                action: snapshots.shrinkLimitingCount > 0
                    ? "A snapshot is limiting container shrink; expiring it needs an administrator."
                    : "Local snapshots expire on their own; removing one early needs an administrator."))
        }
        for failure in accounting.failures {
            found.append(StorageFinding(id: "measurement-failed", severity: .caution,
                title: "Part of the container picture is unavailable.", detail: failure,
                bytes: nil, action: "Re-run the measurement; Spacebar never replaces a gap with a zero."))
        }
    }

    private static func scanFindings(_ scan: FolderScanResult, into found: inout [StorageFinding]) {
        let allocated = scan.totalAllocatedBytes
        let apparent = scan.totalApparentBytes
        if apparent > allocated, apparent - allocated >= reportFloor {
            found.append(StorageFinding(id: "sparse-or-thin", severity: .note,
                title: "Files report \(bytes(apparent - allocated)) more than they occupy.",
                detail: "Apparent size is the length a program sees; allocation is the blocks APFS holds. "
                    + "Sparse and preallocated files are the usual cause, and deleting them frees the allocation, "
                    + "not the length.",
                bytes: apparent - allocated, action: nil))
        }
        if allocated > apparent, allocated - apparent >= reportFloor {
            found.append(StorageFinding(id: "block-overhead", severity: .note,
                title: "Allocation exceeds file lengths by \(bytes(allocated - apparent)).",
                detail: "APFS hands out whole blocks, so many small files cost more than their bytes "
                    + "suggest. Directory metadata is included.",
                bytes: allocated - apparent, action: nil))
        }
        if scan.totalSharedBlockFiles > 0 {
            found.append(StorageFinding(id: "shared-blocks", severity: .caution,
                title: "\(scan.totalSharedBlockFiles) files share blocks with another path.",
                detail: "Hardlinks are counted once per scan. APFS clones share blocks while reporting a link "
                    + "count of one, and their shared extents are not exposed to an unprivileged process, "
                    + "so a clone's size is the best available estimate rather than a guarantee.",
                bytes: nil, action: nil))
        }
        if scan.skippedCloudPlaceholders > 0 {
            found.append(StorageFinding(id: "cloud-placeholders", severity: .note,
                title: "\(scan.skippedCloudPlaceholders) cloud-only placeholders were skipped.",
                detail: "Counting them would show space the disk does not hold; downloading one to measure it "
                    + "would use bandwidth and fill the volume.",
                bytes: nil, action: nil))
        }
        if scan.isPartial {
            var pieces: [String] = []
            if scan.deniedCount > 0 { pieces.append("\(scan.deniedCount) unreadable") }
            if scan.skippedMounts > 0 { pieces.append("\(scan.skippedMounts) other filesystems") }
            if scan.wasCancelled { pieces.append("cancelled") }
            if scan.wasTimeLimited { pieces.append("stopped at the time limit") }
            found.append(StorageFinding(id: "coverage-partial", severity: .caution,
                title: "This scan is incomplete: \(pieces.joined(separator: ", ")).",
                detail: "Totals are a floor. Raise the limit or grant access to the denied folders before "
                    + "treating the number as the whole picture.",
                bytes: nil, action: nil))
        }
    }

    /// Ranks scanned rows by blocks that deleting would plausibly return. Dry run only.
    public static func plan(from scan: FolderScanResult, accounting: VolumeAccounting?,
                            limit: Int, minimumBytes: UInt64 = 100_000_000) -> ReclaimPlan {
        let snapshotPinning = accounting.map { ($0.snapshots?.nonPurgeableCount ?? 0) > 0 } ?? false
        let candidates = scan.rows
            .filter { $0.allocatedBytes >= minimumBytes }
            .sorted { $0.allocatedBytes == $1.allocatedBytes ? $0.name < $1.name : $0.allocatedBytes > $1.allocatedBytes }
            .prefix(max(0, limit))
            .map { candidate(for: $0, snapshotPinning: snapshotPinning) }
        var limits: [String] = []
        if scan.isPartial {
            limits.append("Scan coverage was incomplete, so totals are floors, not sums.")
        }
        if scan.skippedSymlinks > 0 {
            limits.append("\(scan.skippedSymlinks) symbolic links were not followed; their targets are outside these totals.")
        }
        if scan.skippedMounts > 0 {
            limits.append("\(scan.skippedMounts) entries live on other filesystems and were excluded.")
        }
        if scan.skippedCloudPlaceholders > 0 {
            limits.append("\(scan.skippedCloudPlaceholders) cloud-only placeholders were excluded, not downloaded.")
        }
        if accounting?.snapshots != nil {
            limits.append("Snapshot block sizes are not exposed without administrator access, so a pinned "
                + "snapshot can delay, but not fake, the bytes listed here.")
        }
        if limits.isEmpty { limits.append("No coverage limits hit this scan.") }
        return ReclaimPlan(generatedAt: scan.date, rootPath: scan.rootURL.path, scannedRows: scan.rows.count,
                           candidates: candidates,
                           totalEstimatedFreeBytes: candidates.reduce(UInt64(0)) { $0 + $1.estimatedFreeBytes },
                           guarantees: ReclaimPlan.guarantees, limits: limits)
    }

    private static func candidate(for row: FolderUsage, snapshotPinning: Bool) -> ReclaimCandidate {
        var reasons: [String] = []
        var confidence: ReclaimConfidence = .measured
        let larger = max(row.allocatedBytes, row.apparentBytes)
        let smaller = min(row.allocatedBytes, row.apparentBytes)
        if larger - smaller >= StorageReconciliation.reportFloor {
            reasons.append(row.apparentBytes > row.allocatedBytes
                ? "File lengths total \(bytes(row.apparentBytes)) but only \(bytes(row.allocatedBytes)) in "
                    + "blocks: sparse or preallocated."
                : "Blocks total \(bytes(row.allocatedBytes)) against \(bytes(row.apparentBytes)) of file "
                    + "length: block overhead from many small files.")
        }
        if row.sharedBlockFiles > 0 {
            reasons.append("\(row.sharedBlockFiles) files share blocks with paths outside this scan.")
            confidence = .qualified
        }
        if snapshotPinning {
            reasons.append("A non-purgeable APFS snapshot may pin blocks this scan counted.")
            if confidence == .measured { confidence = .qualified }
        }
        if row.isPartial {
            reasons.append("This subtree was not fully readable, so its total is a floor.")
            confidence = .low
        }
        if reasons.isEmpty { reasons.append("Every counted inode was exclusive to this subtree.") }
        return ReclaimCandidate(path: row.url.path, name: row.name, allocatedBytes: row.allocatedBytes,
                                apparentBytes: row.apparentBytes, estimatedFreeBytes: row.allocatedBytes,
                                sharedBlockFiles: row.sharedBlockFiles, confidence: confidence, reasons: reasons,
                                action: "Move to Trash from SpaceBar's Storage view, then empty Trash in Finder.",
                                deletesAutomatically: false)
    }

    public static func bytes(_ value: UInt64) -> String {
        value.formatted(.byteCount(style: .decimal))
    }
}
