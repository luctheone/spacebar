import Foundation

public final class ProcessSampler: Sendable {
    public init() {}

    /// Reads executable names only. Arguments and environment values are never requested.
    public func topProcesses(sort: ProcessSort = .memory, limit: Int = 8) -> [ProcessSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,rss=,comm="]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        return Self.parse(text, sort: sort, limit: limit)
    }

    public static func parse(_ text: String, sort: ProcessSort, limit: Int) -> [ProcessSample] {
        let values = text.split(separator: "\n").compactMap { line -> ProcessSample? in
            let columns = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count == 4, let pid = Int32(columns[0]), pid > 0,
                  let cpu = Double(columns[1]), cpu.isFinite, cpu >= 0,
                  let residentKiB = UInt64(columns[2]), residentKiB <= UInt64.max / 1024 else { return nil }
            let executable = String(columns[3])
            let url = executable.hasPrefix("/") ? URL(fileURLWithPath: executable) : nil
            let name = url?.lastPathComponent ?? executable
            return ProcessSample(pid: pid, name: name, cpuPercent: cpu,
                                 memoryBytes: residentKiB * 1024, executableURL: url)
        }
        return Array(values.sorted {
            let lhs = sort == .memory ? Double($0.memoryBytes) : $0.cpuPercent
            let rhs = sort == .memory ? Double($1.memoryBytes) : $1.cpuPercent
            return lhs == rhs ? $0.pid < $1.pid : lhs > rhs
        }.prefix(max(0, min(limit, 100))))
    }
}
