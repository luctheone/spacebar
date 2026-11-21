import Foundation
import Darwin

public enum MemoryFootprintError: String, Sendable {
    case accessDenied, exited, unavailable
}

public struct MemoryProcessSample: Identifiable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let parentPID: Int32
    public let name: String
    public let executableURL: URL?
    /// ps RSS: resident mappings, including potentially shared/reclaimable pages.
    public let residentBytes: UInt64
    /// macOS's process footprint ledger, not additional memory on top of RSS.
    public let footprintBytes: UInt64?
    public let footprintError: MemoryFootprintError?

    public init(pid: Int32, parentPID: Int32, name: String, executableURL: URL?,
                residentBytes: UInt64, footprintBytes: UInt64?, footprintError: MemoryFootprintError? = nil) {
        self.pid = pid; self.parentPID = parentPID; self.name = name
        self.executableURL = executableURL; self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.footprintError = footprintBytes == nil ? footprintError : nil
    }
}

public struct MemoryAppGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// The outer app bundle evidenced by an executable path, never an invented owner.
    public let appURL: URL?
    public let executableURL: URL?
    public var iconURL: URL? { appURL ?? executableURL }
    public let processes: [MemoryProcessSample]
    /// Subtotal of readable process ledgers. nil means none could be read.
    /// When isPartial, this is a lower bound rather than a complete group total.
    public let footprintBytes: UInt64?
    public let residentBytes: UInt64
    public var measuredProcessCount: Int { processes.filter { $0.footprintBytes != nil }.count }
    /// Missing ledger readings, including exited or permission-limited processes.
    public var inaccessibleProcessCount: Int { processes.count - measuredProcessCount }
    public var isPartial: Bool { inaccessibleProcessCount > 0 }
}

public struct MemoryAnalysis: Sendable {
    public let date: Date
    public let groups: [MemoryAppGroup]
    public let enumeratedProcessCount: Int
    public let measuredProcessCount: Int
    public var inaccessibleProcessCount: Int { enumeratedProcessCount - measuredProcessCount }
    /// false is a failed enumeration, not an empty Mac with no memory use.
    public let enumerationAvailable: Bool
    public let malformedLineCount: Int
    public var isPartial: Bool { !enumerationAvailable || malformedLineCount > 0 || inaccessibleProcessCount > 0 }
    /// Known process-ledger subtotal only; not a replacement for system RAM use.
    public var measuredFootprintBytes: UInt64? {
        let values = groups.compactMap(\.footprintBytes)
        return values.isEmpty ? nil : MemoryAnalyzer.sum(values)
    }
    /// Shared resident mappings can be represented in more than one process.
    public var residentBytes: UInt64 { MemoryAnalyzer.sum(groups.map(\.residentBytes)) }

    public init(date: Date, groups: [MemoryAppGroup], enumeratedProcessCount: Int,
                measuredProcessCount: Int, enumerationAvailable: Bool, malformedLineCount: Int = 0) {
        self.date = date; self.groups = groups
        self.enumeratedProcessCount = enumeratedProcessCount
        self.measuredProcessCount = measuredProcessCount
        self.enumerationAvailable = enumerationAvailable
        self.malformedLineCount = malformedLineCount
    }
}

/// Read-only metadata sampling. No argv, environment inspection, memory-region
/// scan, process control, elevation request or external service is used.
public final class MemoryAnalyzer: Sendable {
    public init() {}

    public func sample() -> MemoryAnalysis {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -ww prevents executable paths being truncated to the terminal width.
        process.arguments = ["-ww", "-axo", "pid=,ppid=,rss=,comm="]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { return Self.analyze([], date: started, enumerationAvailable: false) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return Self.analyze([], date: started, enumerationAvailable: false)
        }
        let listing = Self.parse(text)
        let rows = listing.processes.map { row -> MemoryProcessSample in
            let reading = Self.physicalFootprint(pid: row.pid)
            return MemoryProcessSample(pid: row.pid, parentPID: row.parentPID, name: row.name,
                                       executableURL: row.executableURL, residentBytes: row.residentBytes,
                                       footprintBytes: reading.bytes, footprintError: reading.error)
        }
        return Self.analyze(rows, date: started, malformedLineCount: listing.malformedLineCount)
    }

    /// RUSAGE_INFO_V0 and ri_phys_footprint are defined by the macOS SDK's
    /// sys/resource.h; libproc.h declares proc_pid_rusage (available since10.9).
    /// Apple describes footprint as dirty + compressed/swapped memory; it can
    /// differ markedly from resident size. Never add the two measurements.
    /// https://developer.apple.com/videos/play/wwdc2022/10106/
    public static func physicalFootprint(pid: Int32) -> (bytes: UInt64?, error: MemoryFootprintError?) {
        guard pid > 0 else { return (nil, .unavailable) }
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        guard result == 0 else {
            switch errno {
            case EACCES, EPERM: return (nil, .accessDenied)
            case ESRCH: return (nil, .exited)
            default: return (nil, .unavailable)
            }
        }
        return (info.ri_phys_footprint, nil)
    }

    public static func parse(_ text: String) -> (processes: [MemoryProcessSample], malformedLineCount: Int) {
        var rows: [MemoryProcessSample] = [], seen = Set<Int32>(), malformed = 0
        for line in text.split(separator: "\n") {
            let columns = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
            if columns.isEmpty { continue }
            // pid0 is the kernel, outside this user-process ledger listing.
            if columns.first == "0" { continue }
            guard columns.count == 4, let pid = Int32(columns[0]), pid > 0,
                  let parent = Int32(columns[1]), parent >= 0,
                  let kib = UInt64(columns[2]), kib <= UInt64.max / 1024,
                  seen.insert(pid).inserted else { malformed += 1; continue }
            let executable = String(columns[3])
            let url = executable.hasPrefix("/") ? URL(fileURLWithPath: executable).standardizedFileURL : nil
            rows.append(MemoryProcessSample(pid: pid, parentPID: parent,
                                            name: url?.lastPathComponent ?? executable, executableURL: url,
                                            residentBytes: kib * 1024, footprintBytes: nil))
        }
        return (rows, malformed)
    }

    /// Group only by path/observed ancestry. An independently launched app keeps
    /// its own bundle identity even if another app was its parent. Bare services
    /// stay under their own observed root; pid1/launchd is never a shared owner.
    public static func analyze(_ processes: [MemoryProcessSample], date: Date = Date(),
                               enumerationAvailable: Bool = true, malformedLineCount: Int = 0) -> MemoryAnalysis {
        var byPID: [Int32: MemoryProcessSample] = [:]
        for process in processes where process.pid > 0 {
            if byPID[process.pid] == nil { byPID[process.pid] = process }
        }
        var resolved: [Int32: Owner] = [:], members: [String: [MemoryProcessSample]] = [:], owners: [String: Owner] = [:]
        for process in byPID.values {
            let owner = resolve(process.pid, processes: byPID, cache: &resolved)
            members[owner.id, default: []].append(process); owners[owner.id] = owner
        }
        let groups = members.compactMap { id, rows -> MemoryAppGroup? in
            guard let owner = owners[id] else { return nil }
            let sorted = rows.sorted(by: processOrder)
            let measured = rows.compactMap(\.footprintBytes)
            // Prefer an actually observed main executable over a nested helper.
            let executable = rows.first { row in
                guard let app = owner.appURL, let path = row.executableURL?.path else { return false }
                return path.hasPrefix(app.appendingPathComponent("Contents/MacOS").path + "/")
            }?.executableURL ?? owner.executableURL
            return MemoryAppGroup(id: id, name: owner.name, appURL: owner.appURL,
                                  executableURL: executable, processes: sorted,
                                  footprintBytes: measured.isEmpty ? nil : sum(measured),
                                  residentBytes: sum(rows.map(\.residentBytes)))
        }.sorted { lhs, rhs in
            if (lhs.footprintBytes != nil) != (rhs.footprintBytes != nil) { return lhs.footprintBytes != nil }
            let left = lhs.footprintBytes ?? lhs.residentBytes, right = rhs.footprintBytes ?? rhs.residentBytes
            return left == right ? lhs.id < rhs.id : left > right
        }
        return MemoryAnalysis(date: date, groups: groups, enumeratedProcessCount: byPID.count,
                              measuredProcessCount: byPID.values.filter { $0.footprintBytes != nil }.count,
                              enumerationAvailable: enumerationAvailable, malformedLineCount: malformedLineCount)
    }

    static func sum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { partial, value in
            let (next, overflow) = partial.addingReportingOverflow(value)
            return overflow ? UInt64.max : next
        }
    }

    private struct Owner {
        let id: String
        let name: String
        let appURL: URL?
        let executableURL: URL?
    }

    private static func bundleURL(_ executable: URL?) -> URL? {
        guard let executable else { return nil }
        let components = executable.standardizedFileURL.pathComponents
        guard let index = components.indices.first(where: {
            components[$0].lowercased().hasSuffix(".app") && components[$0].count > 4 &&
                $0 + 1 < components.count && components[$0 + 1] == "Contents"
        }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])), isDirectory: true)
    }

    private static func processOwner(_ process: MemoryProcessSample) -> Owner {
        if let app = bundleURL(process.executableURL) {
            return Owner(id: "app:\(app.path)", name: app.deletingPathExtension().lastPathComponent,
                         appURL: app, executableURL: process.executableURL)
        }
        return Owner(id: "process:\(process.pid)", name: process.name, appURL: nil, executableURL: process.executableURL)
    }

    private static func resolve(_ pid: Int32, processes: [Int32: MemoryProcessSample], cache: inout [Int32: Owner]) -> Owner {
        var walk: [Int32] = [], visited: [Int32: Int] = [:], cursor = pid
        let owner: Owner
        while true {
            if let cached = cache[cursor] { owner = cached; break }
            if let cycleStart = visited[cursor] {
                let root = walk[cycleStart...].min()!
                owner = processOwner(processes[root]!); break
            }
            let process = processes[cursor]!
            visited[cursor] = walk.count; walk.append(cursor)
            if bundleURL(process.executableURL) != nil { owner = processOwner(process); break }
            guard process.parentPID > 1, processes[process.parentPID] != nil else {
                owner = processOwner(process); break
            }
            cursor = process.parentPID
        }
        for member in walk { cache[member] = owner }
        return owner
    }

    private static func processOrder(_ lhs: MemoryProcessSample, _ rhs: MemoryProcessSample) -> Bool {
        if (lhs.footprintBytes != nil) != (rhs.footprintBytes != nil) { return lhs.footprintBytes != nil }
        let left = lhs.footprintBytes ?? lhs.residentBytes, right = rhs.footprintBytes ?? rhs.residentBytes
        return left == right ? lhs.pid < rhs.pid : left > right
    }
}
