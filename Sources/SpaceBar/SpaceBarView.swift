import AppKit
import SwiftUI
import SpaceBarCore

struct SpaceBarView: View {
    @ObservedObject var controller: MonitorController
    @State private var trashCandidate: FolderUsage?
    @State private var trashMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header.padding(18)
            Divider()
            Picker("View", selection: $controller.tab) {
                ForEach(MonitorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 12)
            Group {
                switch controller.tab {
                case .overview: overview
                case .storage: storage
                case .memory: MemoryAnalysisView(controller: controller)
                case .processes: processes
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            Divider()
            footer.padding(.horizontal, 14).padding(.vertical, 11)
        }
        .frame(width: 372, height: 590)
        .background(.ultraThinMaterial)
        .onChange(of: controller.tab) { _ in
            controller.refresh(forceMemory: true)
            if controller.tab == .storage, controller.accounting == nil { controller.measureContainer() }
        }
        .onChange(of: controller.processSort) { _ in controller.refresh() }
        .alert("Move to Trash?", isPresented: Binding(get: { trashCandidate != nil }, set: { if !$0 { trashCandidate = nil } }), presenting: trashCandidate) { row in
            Button("Cancel", role: .cancel) { trashCandidate = nil }
            Button("Move to Trash", role: .destructive) { controller.moveToTrash(row) { trashMessage = $0 } }
        } message: { row in
            Text("\(row.url.path)\n\n\(Display.bytes(row.allocatedBytes)) measured on disk\(row.isPartial ? " (partial scan)" : ""). Move this \(row.isDirectory ? "folder and its contents" : "file") to Trash? You can restore it in Finder. SpaceBar never empties Trash.")
        }
        .alert("Storage", isPresented: Binding(get: { trashMessage != nil }, set: { if !$0 { trashMessage = nil } })) {
            Button("OK", role: .cancel) { trashMessage = nil }
        } message: { Text(trashMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.14))
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 21, weight: .semibold)).foregroundStyle(.blue)
            }.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("SpaceBar").font(.headline)
                Text("System overview").font(.subheadline.weight(.medium))
                Text("Storage, memory & what’s using them.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var overview: some View {
        VStack(spacing: 12) {
            storageCard
            containerCard
            memoryCard
            computeCard
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text(controller.autoRefresh ? "Live while open · light checks when closed" : "Live updates paused")
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var storageCard: some View {
        MetricCard(icon: "internaldrive.fill", tint: .blue, title: "Storage") {
            if let disk = controller.snapshot?.disk, disk.totalBytes > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Display.bytes(disk.freeBytes)).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("available").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                CapacityBar(fraction: fraction(disk.usedBytes, disk.totalBytes), color: .blue)
                HStack {
                    Text("\(Display.bytes(disk.usedBytes)) of \(Display.bytes(disk.totalBytes))")
                    Spacer()
                    Button("Find large folders") { controller.tab = .storage }
                        .buttonStyle(.plain).foregroundStyle(.blue)
                }.font(.caption)
            } else if controller.snapshot != nil {
                Text("Storage information unavailable").font(.caption).foregroundStyle(.secondary)
            } else { loading }
        }
    }

    private var memoryCard: some View {
        MetricCard(icon: "memorychip.fill", tint: .indigo, title: "Memory") {
            if let value = controller.snapshot, value.memoryAvailable {
                HStack {
                    Text(Display.memory(value.memoryUsedBytes)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text("of \(Display.memory(value.memoryTotalBytes))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(pressureColor).frame(width: 6, height: 6)
                        Text(pressureLabel).font(.caption.weight(.medium))
                    }
                }
                CapacityBar(fraction: fraction(value.memoryUsedBytes, value.memoryTotalBytes), color: pressureColor)
                HStack {
                    Text(value.swapAvailable ? "Swap \(Display.memory(value.swapUsedBytes))" : "Swap unavailable")
                    Spacer()
                    Text("Compressed \(Display.memory(value.compressedBytes))")
                }.font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Active, wired & compressed estimate.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Button("Analyse") { controller.tab = .memory }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.indigo)
                }
            } else if controller.snapshot != nil {
                Text("Memory information unavailable").font(.caption).foregroundStyle(.secondary)
            } else { loading }
        }
    }

    private var computeCard: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("CPU", systemImage: "cpu").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .center) {
                    Text(Display.percent(controller.snapshot?.cpuPercent)).font(.title3.weight(.semibold)).monospacedDigit()
                    Sparkline(values: controller.cpuHistory).stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 70, height: 22)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Divider().frame(height: 48).padding(.horizontal, 13)
            VStack(alignment: .leading, spacing: 8) {
                Label("GPU", systemImage: "square.3.layers.3d").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(Display.percent(controller.snapshot?.gpuPercent)).font(.title3.weight(.semibold)).monospacedDigit()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13).cardBackground()
        .help("CPU is a whole-system average across cores. GPU is the aggregate device counter, when available.")
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu {
                    Button("Home") { controller.scan(FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Documents") { controller.scan(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")) }
                    Button("Library") { controller.scan(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")) }
                    Button("Codex") { controller.scan(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) }
                    Divider()
                    Button("Choose folder…") { controller.chooseFolder() }
                } label: {
                    Label(folderLabel, systemImage: "folder").font(.subheadline.weight(.semibold))
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if controller.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { controller.cancelScan() }.buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    Button(controller.scanResult == nil ? "Scan sizes" : "Rescan") { controller.scan() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            if controller.isScanning {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.blue)
                    Text("Checking \(controller.scanProgress.formatted()) items…").font(.caption)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).cardBackground()
            }
            if let result = controller.scanResult {
                HStack {
                    Button { controller.scan(controller.scanRoot.deletingLastPathComponent()) } label: { Label("Up", systemImage: "chevron.left") }
                        .buttonStyle(.plain).disabled(controller.isScanning || controller.scanRoot.path == "/")
                    Spacer()
                    Text("Size on disk").foregroundStyle(.secondary)
                }.font(.caption)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(result.rows.prefix(30)), id: \.url.path) { row in
                            FolderRow(row: row, largest: result.rows.first?.allocatedBytes ?? 1, open: {
                                if row.isDirectory { controller.scan(row.url) } else { controller.reveal(row.url) }
                            }, reveal: { controller.reveal(row.url) }, trash: { trashCandidate = row }, canTrash: controller.canTrash(row.url) && !controller.isScanning && !controller.isMovingToTrash)
                            if row.url != result.rows.prefix(30).last?.url { Divider().padding(.leading, 43) }
                        }
                    }.padding(.horizontal, 10).cardBackground()
                }
                if result.rows.isEmpty {
                    Text(result.deniedCount > 0 ? "This folder could not be read. Choose it through the folder picker to grant access." : "No local items found.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let plan = controller.reclaimPlan() { reclaimCard(plan) }
                findingsCard
                scanFootnote(result).font(.caption2).foregroundStyle(.secondary)
                Text(controller.isMovingToTrash ? "Moving to Trash…" : "Use an item’s ••• menu to move it to Trash.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if !controller.isScanning {
                VStack(spacing: 11) {
                    Image(systemName: "folder.badge.magnifyingglass").font(.system(size: 31, weight: .light)).foregroundStyle(.blue.opacity(0.7))
                    Text("See where the space goes.").font(.subheadline.weight(.medium))
                    Text("Choose a folder, then scan its local sizes.\nMove individual items to Trash from their menu.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
    }

    private var processes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Using your Mac").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Sort processes", selection: $controller.processSort) {
                    Text("Memory").tag(ProcessSort.memory)
                    Text("CPU").tag(ProcessSort.cpu)
                }.labelsHidden().frame(width: 108)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(controller.processes, id: \.pid) { process in
                        HStack(spacing: 9) {
                            ProcessIcon(process: process).frame(width: 25, height: 25)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(process.name).font(.caption.weight(.medium)).lineLimit(1)
                                Text("PID \(process.pid)").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(controller.processSort == .memory ? Display.memory(process.memoryBytes) : Display.percent(process.cpuPercent))
                                    .font(.caption.weight(.medium)).monospacedDigit()
                                Text(controller.processSort == .memory ? Display.percent(process.cpuPercent) + " CPU" : Display.memory(process.memoryBytes))
                                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }.padding(.vertical, 8)
                        if process.pid != controller.processes.last?.pid { Divider().padding(.leading, 34) }
                    }
                }.padding(.horizontal, 11).cardBackground()
            }
            Text("Memory is resident RAM. A process can use more than 100% CPU across multiple cores.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Open Activity Monitor") { controller.openActivityMonitor() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.blue)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { controller.refresh(forceMemory: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.plain)
            Spacer()
            Menu {
                Toggle("Live updates", isOn: $controller.autoRefresh)
                Button("Open in a window") { (NSApp.delegate as? SpaceBarDelegate)?.showWindow() }
                Button("Choose a folder…") { controller.chooseFolder(); controller.tab = .storage }
                Divider()
                Button("Quit SpaceBar") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }.font(.caption).foregroundStyle(.secondary)
    }


    // MARK: - APFS reconciliation

    private var containerCard: some View {
        MetricCard(icon: "square.3.stack.3d.fill", tint: .teal, title: "Container truth") {
            if controller.isMeasuringContainer {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the APFS container…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let accounting = controller.accounting {
                VStack(alignment: .leading, spacing: 7) {
                    fact("Finder calls it", Display.bytes(accounting.importantUsageAvailableBytes ?? accounting.filesystemFreeBytes),
                         note: accounting.purgeableBytes.map { "\(Display.bytes($0)) of that is purgeable, not used." })
                    fact("A plain write can take", Display.bytes(accounting.filesystemFreeBytes),
                         note: accounting.reservedForSiblingsBytes.map { "\(Display.bytes($0)) is space the container has not released yet." })
                    fact("Outside any folder scan", Display.bytes(accounting.nonDataUsedBytes),
                         note: accounting.snapshots.map { "\($0.count) APFS snapshot(s) may pin blocks; \($0.nonPurgeableCount) are not purgeable." })
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(accounting.volumes.filter { !$0.roles.contains("Data") }
                            .sorted { $0.capacityInUseBytes > $1.capacityInUseBytes }
                            .prefix(3)) { volume in
                        HStack(spacing: 6) {
                            Text(volume.name).font(.system(size: 10)).foregroundStyle(.secondary)
                            CapacityBar(fraction: volume.capacityInUseBytes > 0 && accounting.filesystemTotalBytes > 0
                                        ? Double(volume.capacityInUseBytes) / Double(accounting.filesystemTotalBytes) : 0,
                                        color: .teal.opacity(0.6))
                                .frame(height: 4)
                            Text(Display.bytes(volume.capacityInUseBytes)).font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !accounting.failures.isEmpty {
                    Text(accounting.failures.first ?? "").font(.system(size: 10)).foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    Button("Re-measure") { controller.measureContainer() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.teal)
                    Spacer()
                    Button("Copy agent command") { controller.copyAgentCommand() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.teal)
                        .help("Copies: spacebar reclaim <home> --json")
                }
            } else {
                Text("One “available” number hides three different measurements. Spacebar reads them separately.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Measure the container") { controller.measureContainer() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .help("statvfs free bytes, the APFS container's own free bytes, macOS's eviction hints, per-volume usage and snapshot flags. Read-only, no administrator rights.")
    }

    private func fact(_ label: String, _ value: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            if let note { Text(note).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }

    private var findingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.findings.isEmpty {
                Text("No reconciliation findings yet.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(controller.findings.prefix(3), id: \.id) { finding in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: finding.severity == .important ? "exclamationmark.triangle.fill"
                                    : finding.severity == .caution ? "info.circle.fill" : "checklist")
                                .font(.system(size: 10))
                                .foregroundStyle(finding.severity == .important ? .red
                                    : finding.severity == .caution ? .orange : .teal)
                            Text(finding.title).font(.caption.weight(.medium))
                            Spacer(minLength: 4)
                        }
                        Text(finding.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(3)
                    }.padding(.vertical, 4)
                    if finding.id != controller.findings.prefix(3).last?.id { Divider() }
                }
            }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading).cardBackground()
    }

    private func reclaimCard(_ plan: ReclaimPlan) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Reclaim estimate", systemImage: "scalemass").font(.caption.weight(.semibold))
                Spacer()
                Text(Display.bytes(plan.totalEstimatedFreeBytes)).font(.caption.weight(.semibold)).monospacedDigit()
            }
            ForEach(plan.candidates.prefix(3), id: \.path) { candidate in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(candidate.name).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Display.bytes(candidate.estimatedFreeBytes)).font(.caption).monospacedDigit()
                        Text(candidate.confidence.rawValue)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(candidate.confidence == .measured ? Color.green.opacity(0.16)
                                    : candidate.confidence == .qualified ? Color.orange.opacity(0.16)
                                    : Color.red.opacity(0.16)))
                    }
                    Text(candidate.reasons.joined(separator: " ")).font(.system(size: 10))
                        .foregroundStyle(.secondary).lineLimit(2)
                }.padding(.vertical, 2)
            }
            Text(plan.limits.first ?? "").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading).cardBackground()
    }

    private var loading: some View { HStack { ProgressView().controlSize(.small); Text("Reading your Mac…").font(.caption).foregroundStyle(.secondary) } }
    private var folderLabel: String {
        controller.scanRoot == FileManager.default.homeDirectoryForCurrentUser ? "Home" : (controller.scanRoot.lastPathComponent.isEmpty ? "/" : controller.scanRoot.lastPathComponent)
    }
    private var pressureLabel: String {
        guard let value = controller.snapshot else { return "—" }
        switch value.pressure {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "High pressure"
        case .unknown: return "Unknown"
        }
    }
    private var pressureColor: Color {
        switch controller.snapshot?.pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        default: return .secondary
        }
    }
    private func fraction(_ part: UInt64, _ total: UInt64) -> Double { total > 0 ? min(1, Double(part) / Double(total)) : 0 }
    private func scanFootnote(_ value: FolderScanResult) -> Text {
        var parts = ["\(value.scannedFiles.formatted()) items"]
        if value.deniedCount > 0 { parts.append("\(value.deniedCount) unreadable") }
        if value.skippedCloudPlaceholders > 0 { parts.append("\(value.skippedCloudPlaceholders) cloud-only") }
        if value.wasCancelled { parts.append("Stopped · partial sizes") }
        if value.wasTimeLimited { parts.append("Time limit · partial sizes") }
        parts.append("Shared APFS blocks can affect totals")
        return Text(parts.joined(separator: " · "))
    }
}

private struct MetricCard<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(tint)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13).cardBackground()
    }
}

private struct CapacityBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Color.primary.opacity(0.07))
            Capsule().fill(color.opacity(0.8)).frame(width: geometry.size.width * min(1, max(0, fraction)))
        }.frame(height: 5)
    }
}

private struct Sparkline: Shape {
    let values: [Double]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.width * Double(index) / Double(values.count - 1), y: rect.height * (1 - min(100, max(0, value)) / 100))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

private struct ProcessIcon: View {
    let process: ProcessSample
    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: process.pid)?.icon {
            Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
        } else { Image(systemName: "terminal").font(.system(size: 17)).foregroundStyle(.secondary) }
    }
}

private struct FolderRow: View {
    let row: FolderUsage
    let largest: UInt64
    let open: () -> Void
    let reveal: () -> Void
    let trash: () -> Void
    let canTrash: Bool
    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 9) {
                    Image(systemName: row.isDirectory ? "folder.fill" : "doc.fill").font(.system(size: 18)).foregroundStyle(row.isDirectory ? .blue.opacity(0.7) : .secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.name).font(.caption.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(row.isPartial && row.allocatedBytes == 0 ? "Unreadable" : Display.bytes(row.allocatedBytes))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        CapacityBar(fraction: largest > 0 ? Double(row.allocatedBytes) / Double(largest) : 0, color: .blue.opacity(0.65))
                    }
                }
            }.buttonStyle(.plain)
            Button(action: reveal) { Image(systemName: "arrow.up.forward.square").font(.system(size: 11)).foregroundStyle(.tertiary) }
                .buttonStyle(.plain).help("Show in Finder")
            Menu {
                Button("Show in Finder", action: reveal)
                Divider()
                Button("Move to Trash…", role: .destructive, action: trash).disabled(!canTrash)
            } label: { Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).fixedSize().help("Item actions")
        }.padding(.vertical, 11)
    }
}

private extension View {
    func cardBackground() -> some View {
        background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}
