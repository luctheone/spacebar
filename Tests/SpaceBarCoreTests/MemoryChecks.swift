import Foundation
import Darwin
import SpaceBarCore

private func memoryProcess(_ pid: Int32, _ parent: Int32, _ path: String,
                           rss: UInt64 = 100, footprint: UInt64? = 50,
                           error: MemoryFootprintError? = nil) -> MemoryProcessSample {
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    return MemoryProcessSample(pid: pid, parentPID: parent, name: url?.lastPathComponent ?? path,
                               executableURL: url, residentBytes: rss, footprintBytes: footprint, footprintError: error)
}

let memoryChecks: [(String, () throws -> Void)] = [
    ("Memory parser preserves full executable paths and reports malformed coverage", {
        let input = """
        42 1 1024 /Applications/Example App.app/Contents/MacOS/Example App
        43 42 2048 /Applications/Example App.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper
        44 1 1 (idle child)
        0 0 0 kernel_task
        42 1 10 duplicate
        corrupt row
        9 -1 10 bad-parent
        10 1 18446744073709551615 overflow
        11 1 -1 bad-rss
        """
        let listing = MemoryAnalyzer.parse(input)
        try expect(listing.processes.count == 3 && listing.malformedLineCount == 5, "Malformed/duplicate rows or kernel exclusion lost")
        try expect(listing.processes[0].name == "Example App", "Executable spaces were split")
        try expect(listing.processes[0].residentBytes == 1_048_576, "Resident KiB conversion wrong")
        try expect(listing.processes[2].executableURL == nil && listing.processes[2].name == "(idle child)", "Non-path executable metadata invented a file")
    }),
    ("Memory groups nested app helpers and external children by observed ownership", {
        let rows = [
            memoryProcess(10,1,"/Applications/Example App.app/Contents/MacOS/Example App",rss:100,footprint:500),
            memoryProcess(11,1,"/Applications/Example App.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",rss:50,footprint:900),
            memoryProcess(12,10,"/usr/local/bin/python3",rss:60,footprint:100),
            memoryProcess(13,12,"/usr/local/bin/worker",rss:20,footprint:0),
        ]
        let snapshot = MemoryAnalyzer.analyze(rows)
        try expect(snapshot.groups.count == 1, "Nested helper or external Python child escaped its owning app")
        let group = snapshot.groups[0]
        try expect(group.name == "Example App" && group.appURL?.path == "/Applications/Example App.app", "Outer owning app was not selected")
        try expect(group.executableURL?.path == rows[0].executableURL?.path && group.iconURL == group.appURL, "App icon/main executable metadata wrong")
        try expect(group.footprintBytes == 1500 && group.residentBytes == 230, "RSS was mixed with physical footprint")
        try expect(group.processes.map(\.pid) == [11,10,12,13], "Breakdown not sorted by measured footprint")
        try expect(!group.isPartial && group.measuredProcessCount == 4, "Zero footprint must count as a successful measurement")
    }),
    ("Memory keeps independent apps and standalone services separate from launchd", {
        let rows = [
            memoryProcess(1,0,"/sbin/launchd"),
            memoryProcess(20,1,"/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            memoryProcess(21,20,"/Applications/Browser.app/Contents/MacOS/Browser"),
            memoryProcess(30,1,"/opt/homebrew/bin/ollama"),
            memoryProcess(31,30,"/opt/homebrew/libexec/ollama-runner"),
            memoryProcess(32,1,"/opt/homebrew/bin/ollama"),
            memoryProcess(40,1,"/usr/libexec/standalone-daemon"),
        ]
        let snapshot = MemoryAnalyzer.analyze(rows)
        try expect(snapshot.groups.count == 6, "launchd or executable-name coincidence merged independent services/apps")
        let service = snapshot.groups.first { $0.processes.contains { $0.pid == 30 } }!
        try expect(service.appURL == nil && Set(service.processes.map(\.pid)) == Set([30,31]), "Runner ancestry was not preserved")
        let browser = snapshot.groups.first { $0.processes.contains { $0.pid == 21 } }!
        try expect(browser.name == "Browser" && browser.processes.count == 1, "A launched app was swallowed by Terminal")
    }),
    ("Memory missing ledgers stay nil/partial and never fall back to RSS silently", {
        let rows = [
            memoryProcess(10,1,"/Applications/Example.app/Contents/MacOS/Example",rss:500,footprint:50),
            memoryProcess(11,10,"/usr/local/bin/worker",rss:5000,footprint:nil,error:.accessDenied),
            memoryProcess(12,1,"/usr/libexec/other",rss:800,footprint:nil,error:.exited),
        ]
        let snapshot = MemoryAnalyzer.analyze(rows)
        let app = snapshot.groups.first { $0.appURL != nil }!
        let other = snapshot.groups.first { $0.appURL == nil }!
        try expect(app.footprintBytes == 50 && app.residentBytes == 5500 && app.isPartial, "Partial app subtotal or RSS incorrect")
        try expect(app.measuredProcessCount == 1 && app.inaccessibleProcessCount == 1, "Partial app coverage not reported")
        try expect(other.footprintBytes == nil && other.processes[0].footprintError == .exited, "Exited process looked measured")
        try expect(snapshot.enumeratedProcessCount == 3 && snapshot.measuredProcessCount == 1 && snapshot.inaccessibleProcessCount == 2, "Snapshot coverage wrong")
        try expect(snapshot.measuredFootprintBytes == 50 && snapshot.residentBytes == 6300 && snapshot.isPartial, "Unknown metrics were added or hidden")
    }),
    ("Memory parent cycles, self-parenting and missing ancestors terminate deterministically", {
        let rows = [
            memoryProcess(100,101,"/usr/bin/cycle-a"),
            memoryProcess(101,100,"/usr/bin/cycle-b"),
            memoryProcess(102,100,"/usr/bin/cycle-child"),
            memoryProcess(103,103,"/usr/bin/self"),
            memoryProcess(104,999,"/usr/bin/orphan"),
            memoryProcess(1,0,"/sbin/launchd"),
        ]
        let first = MemoryAnalyzer.analyze(rows), second = MemoryAnalyzer.analyze(rows.reversed())
        let identity: (MemoryAnalysis) -> [String: Set<Int32>] = { snapshot in
            Dictionary(uniqueKeysWithValues: snapshot.groups.map { ($0.id,Set($0.processes.map(\.pid))) })
        }
        try expect(first.groups.count == 4 && identity(first) == identity(second), "Cycle grouping depended on enumeration order")
        try expect(first.groups.first { $0.id == "process:100" }?.processes.count == 3, "Cycle root or child association wrong")
    }),
    ("Memory failed enumeration and app-like filenames remain honest", {
        let failed = MemoryAnalyzer.analyze([],enumerationAvailable:false)
        try expect(!failed.enumerationAvailable && failed.isPartial && failed.measuredFootprintBytes == nil, "Failed ps enumeration looked like complete zero usage")
        let rows = [memoryProcess(70,1,"/usr/local/bin/example.app"),memoryProcess(71,1,"/tmp/not.app/data/worker")]
        let snapshot = MemoryAnalyzer.analyze(rows,malformedLineCount:1)
        try expect(snapshot.groups.allSatisfy { $0.appURL == nil } && snapshot.isPartial, "An .app filename or non-bundle directory was promoted into an app owner")
    }),
    ("Native process footprint reads its own ledger without a memory scan", {
        let reading = MemoryAnalyzer.physicalFootprint(pid:getpid())
        try expect(reading.bytes != nil && reading.bytes! > 0 && reading.error == nil, "Own native footprint unavailable")
        let missing = MemoryAnalyzer.physicalFootprint(pid:Int32.max)
        try expect(missing.bytes == nil && missing.error != nil, "Missing process became zero/success")
        try expect(MemoryAnalyzer.physicalFootprint(pid:-1).bytes == nil, "Invalid PID was queried as a real process")
    }),
]
