import AppKit
import Combine
import Foundation
import SpaceBarCore

enum MonitorTab: String, CaseIterable {
    case overview = "Overview"
    case storage = "Storage"
    case memory = "Memory"
    case processes = "Processes"
}

struct MemoryHistoryPoint {
    let date: Date
    let fraction: Double
}

final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

@MainActor
final class MonitorController: ObservableObject {
    @Published var tab: MonitorTab = .overview
    @Published var snapshot: SystemSnapshot?
    @Published var processes: [ProcessSample] = []
    @Published var processSort: ProcessSort = .memory
    @Published var cpuHistory: [Double] = []
    @Published var memoryHistory: [MemoryHistoryPoint] = []
    @Published var memoryAnalysis: MemoryAnalysis?
    @Published var isAnalysingMemory = false
    @Published var scanRoot = FileManager.default.homeDirectoryForCurrentUser
    @Published var scanResult: FolderScanResult?
    @Published var isScanning = false
    @Published var scanProgress = 0
    @Published var autoRefresh = true
    @Published var isMovingToTrash = false
    @Published var accounting: VolumeAccounting?
    @Published var findings: [StorageFinding] = []
    @Published var isMeasuringContainer = false
    var isVisible = false

    private let sampler = SystemSampler()
    private let processSampler = ProcessSampler()
    private let memoryAnalyzer = MemoryAnalyzer()
    private let queue = DispatchQueue(label: "net.appledore.spacebar.metrics", qos: .utility)
    private var timer: Timer?
    private var refreshPending = false
    private var refreshRequested = false
    private var memoryRefreshRequested = false
    private var ticks = 0
    private var cancellation = ScanCancellation()
    private var scanID = UUID()
    private var containerRemeasureRequested = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ticks += 1
                if self.autoRefresh && (self.isVisible || self.ticks % 15 == 0) { self.refresh() }
            }
        }
    }

    func refresh(forceMemory: Bool = false) {
        guard !refreshPending else {
            refreshRequested = true
            memoryRefreshRequested = memoryRefreshRequested || forceMemory
            return
        }
        refreshPending = true
        let includeProcesses = tab == .processes && isVisible
        let memoryDue = memoryAnalysis.map { Date().timeIntervalSince($0.date) >= 10 } ?? true
        let includeMemory = tab == .memory && isVisible && (forceMemory || memoryDue)
        if includeMemory { isAnalysingMemory = true }
        let sort = processSort
        queue.async { [weak self] in
            guard let self else { return }
            let value = self.sampler.sample()
            let rows = includeProcesses ? self.processSampler.topProcesses(sort: sort, limit: 12) : []
            let analysis = includeMemory ? self.memoryAnalyzer.sample() : nil
            DispatchQueue.main.async {
                self.snapshot = value
                if includeProcesses { self.processes = rows }
                if let analysis { self.memoryAnalysis = analysis }
                if includeMemory { self.isAnalysingMemory = false }
                if value.memoryAvailable {
                    self.memoryHistory.append(MemoryHistoryPoint(date: value.date, fraction: value.memoryFraction))
                    self.memoryHistory.removeAll { value.date.timeIntervalSince($0.date) > 300 }
                    self.memoryHistory = Array(self.memoryHistory.suffix(180))
                }
                if let cpu = value.cpuPercent {
                    self.cpuHistory.append(cpu)
                    self.cpuHistory = Array(self.cpuHistory.suffix(45))
                }
                self.refreshPending = false
                if self.refreshRequested {
                    let force = self.memoryRefreshRequested
                    self.refreshRequested = false
                    self.memoryRefreshRequested = false
                    self.refresh(forceMemory: force)
                }
            }
        }
    }

    func setVisible(_ visible: Bool) { isVisible = visible; if visible { refresh() } }

    /// Reads the container layout. Deliberately on demand: it shells out to read-only diskutil
    /// helpers, which does not belong on the two-second sampling loop.
    func measureContainer() {
        guard !isMeasuringContainer else {
            containerRemeasureRequested = true
            return
        }
        isMeasuringContainer = true
        queue.async { [weak self] in
            let value = VolumeAccountingProbe().measure()
            DispatchQueue.main.async {
                guard let self else { return }
                self.accounting = value
                self.findings = StorageReconciliation.findings(accounting: value, scan: self.scanResult)
                self.isMeasuringContainer = false
                if self.containerRemeasureRequested {
                    self.containerRemeasureRequested = false
                    self.measureContainer()
                }
            }
        }
    }

    func reclaimPlan(limit: Int = 5) -> ReclaimPlan? {
        guard let scanResult else { return nil }
        return StorageReconciliation.plan(from: scanResult, accounting: accounting, limit: limit)
    }

    func copyAgentCommand() {
        let command = "spacebar reclaim \(FileManager.default.homeDirectoryForCurrentUser.path) --json"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func scan(_ url: URL? = nil) {
        guard !isScanning, !isMovingToTrash else { return }
        if let url { scanRoot = url }
        let target = scanRoot
        let flag = ScanCancellation()
        cancellation = flag
        isScanning = true
        scanProgress = 0
        scanResult = nil
        let id = UUID()
        scanID = id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = FolderScanner().scan(url: target, cancelled: { flag.isCancelled }) { count, _ in
                DispatchQueue.main.async {
                    guard let self, self.scanID == id else { return }
                    self.scanProgress = count
                }
            }
            DispatchQueue.main.async {
                guard let self, self.scanID == id else { return }
                self.scanResult = result
                self.isScanning = false
                self.findings = StorageReconciliation.findings(accounting: self.accounting, scan: result)
                self.refresh()
            }
        }
    }

    func cancelScan() { cancellation.cancel() }

    func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "Check folder"
        picker.message = "SpaceBar measures local sizes. Items move to Trash only when you choose and confirm."
        if picker.runModal() == .OK, let url = picker.url { scan(url) }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Trash only; there is intentionally no permanent-delete fallback.
    func canTrash(_ url: URL) -> Bool {
        StorageTrashPolicy.allows(url, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    func moveToTrash(_ row: FolderUsage, completion: @escaping (String) -> Void) {
        guard canTrash(row.url), !isScanning, !isMovingToTrash else {
            completion("This item can’t be moved right now. Finish the current operation and try again.")
            return
        }
        isMovingToTrash = true
        NSWorkspace.shared.recycle([row.url]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isMovingToTrash = false
                if let error {
                    completion("Couldn’t move \(row.name) to Trash. \(error.localizedDescription)")
                } else {
                    completion("Moved \(row.name) to Trash. Storage is reclaimed after you empty Trash in Finder.")
                    self.scan()
                }
            }
        }
    }

    func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

enum Display {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .file)
    }
    static func memory(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .memory)
    }
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", max(0, value))
    }
}
