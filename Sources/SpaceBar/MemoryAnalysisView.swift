import AppKit
import SwiftUI
import SpaceBarCore

struct MemoryAnalysisView: View {
    @ObservedObject var controller: MonitorController
    @State private var search = ""

    private var groups: [MemoryAppGroup] {
        guard let analysis = controller.memoryAnalysis else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? analysis.groups : analysis.groups.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.processes.contains {
                $0.name.localizedCaseInsensitiveContains(query) || String($0.pid) == query
            }
        }
    }

    var body: some View {
        let displayedGroups = groups
        let largest = controller.memoryAnalysis?.groups.compactMap(\.footprintBytes).max() ?? 1
        VStack(alignment: .leading, spacing: 10) {
            summary
            HStack(spacing: 8) {
                Text("Apps & services").font(.caption.weight(.semibold)).fixedSize()
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Find app or PID", text: $search)
                        .textFieldStyle(.plain).font(.caption)
                        .accessibilityLabel("Find app or PID")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear memory search")
                    }
                }.font(.caption).padding(.horizontal, 7).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    .frame(width: 156)
            }
            if let analysis = controller.memoryAnalysis {
                if !analysis.enumerationAvailable {
                    emptyState("Couldn’t read the process list.", detail: "Use Refresh to try again.")
                } else if displayedGroups.isEmpty {
                    emptyState("No matching apps or processes.", detail: "Try another name or process ID.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(displayedGroups, id: \.id) { group in
                                MemoryAppRow(group: group, largest: largest)
                                if group.id != displayedGroups.last?.id { Divider().padding(.leading, 45) }
                            }
                        }.padding(.horizontal, 10).memorySurface()
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if controller.isAnalysingMemory { ProgressView().controlSize(.mini) }
                        Text(controller.autoRefresh ? "Apps refresh every 10s while this view is open" : "Live updates paused")
                    }
                    Text("\(analysis.measuredProcessCount) measured · \(analysis.inaccessibleProcessCount) unavailable · click an app for details")
                    Text("Footprints include compressed/swapped data, not just RAM.")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Unavailable processes may be protected or may have exited during the sample. Physical footprints are process ledger charges, including compressed and some graphics memory. They are not a partition of system RAM. RSS is shown separately in each app’s details.")
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring apps and their helpers…").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                if let value = controller.snapshot, value.memoryAvailable {
                    Text(Display.memory(value.memoryUsedBytes))
                        .font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("/ \(Display.memory(value.memoryTotalBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("RAM unavailable").font(.subheadline)
                }
                Spacer(minLength: 5)
                HStack(spacing: 4) {
                    Circle().fill(pressureColor).frame(width: 6, height: 6)
                    Text(pressureTitle).font(.system(size: 10, weight: .medium))
                }
            }
            HStack(spacing: 12) {
                Text("Recent RAM use").font(.system(size: 10)).foregroundStyle(.secondary)
                MemoryTrend(points: controller.memoryHistory, color: pressureColor)
                    .frame(height: 24)
                    .accessibilityLabel("Recent RAM use, up to five minutes in this session")
            }
            HStack {
                Text("Swap \(swapLabel)")
                Spacer()
                Text("Compressed \(compressedLabel)")
            }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            Text(pressureExplanation).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).memorySurface()
            .help("System RAM is an estimate of active, wired and physical compressor pages. The line shows recent samples with their actual timing, up to five minutes; it is not a pressure graph. Pressure is reported separately by macOS. Swap can remain allocated after pressure falls.")
    }

    private var pressureTitle: String {
        switch controller.snapshot?.pressure {
        case .normal: return "Normal pressure"
        case .warning: return "Elevated pressure"
        case .critical: return "High pressure"
        default: return "Pressure unknown"
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

    private var pressureExplanation: String {
        switch controller.snapshot?.pressure {
        case .normal: return "macOS reports normal pressure, even if RAM looks full."
        case .warning: return "macOS reports pressure. Start with the largest apps below."
        case .critical: return "macOS reports high pressure. Large apps are worth reviewing."
        default: return "Pressure isn’t available; RAM use alone can’t diagnose a shortage."
        }
    }

    private var swapLabel: String {
        guard let value = controller.snapshot, value.swapAvailable else { return "—" }
        return Display.memory(value.swapUsedBytes)
    }

    private var compressedLabel: String {
        guard let value = controller.snapshot, value.memoryAvailable else { return "—" }
        return Display.memory(value.compressedBytes)
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MemoryAppRow: View {
    let group: MemoryAppGroup
    let largest: UInt64
    @State private var expanded = false

    private var amount: String {
        guard let footprint = group.footprintBytes else { return "Unavailable" }
        return (group.isPartial ? "≥ " : "") + Display.memory(footprint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                HStack(spacing: 9) {
                    appIcon.frame(width: 27, height: 27)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(group.name).font(.caption.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 3)
                            Text(amount).font(.caption.weight(.medium)).monospacedDigit()
                                .foregroundStyle(group.footprintBytes == nil ? Color.secondary : Color.primary)
                        }
                        HStack(spacing: 6) {
                            Text("\(group.processes.count) \(group.processes.count == 1 ? "process" : "processes")")
                            if group.isPartial { Text("Partial").foregroundStyle(.orange) }
                            Spacer()
                            Text("Footprint")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                        GeometryReader { geometry in
                            Capsule().fill(Color.indigo.opacity(0.09))
                            Capsule().fill(Color.indigo.opacity(0.55))
                                .frame(width: geometry.size.width * min(1, Double(group.footprintBytes ?? 0) / Double(max(1, largest))))
                        }.frame(height: 3)
                    }
                }.padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(group.name), \(amount) footprint, \(group.processes.count) processes")
                .accessibilityHint(expanded ? "Collapse process details" : "Expand process details")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("PROCESS / PID")
                        Spacer()
                        Text("FOOTPRINT")
                    }.font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    ForEach(group.processes, id: \.pid) { process in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(process.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                Text("PID \(process.pid)").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 3)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(process.footprintBytes.map(Display.memory) ?? "Unavailable")
                                    .font(.system(size: 10)).monospacedDigit()
                                Text("RSS \(Display.memory(process.residentBytes))")
                                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }.help(process.executableURL?.path ?? process.name)
                    }
                    Text("Helpers are grouped by app bundle and parent process. Footprint and RSS are different measurements; don’t add them together.")
                        .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(9).background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
                    .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder private var appIcon: some View {
        if let url = group.iconURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "terminal").font(.system(size: 19)).foregroundStyle(.secondary)
        }
    }
}

private struct MemoryTrend: View {
    let points: [MemoryHistoryPoint]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let first = points.first?.date ?? Date()
            let duration = max(1, points.last?.date.timeIntervalSince(first) ?? 1)
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                Path { path in
                    for (index, sample) in points.enumerated() {
                        let point = CGPoint(x: geometry.size.width * sample.date.timeIntervalSince(first) / duration,
                                            y: geometry.size.height * (1 - min(1, max(0, sample.fraction))))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }.stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private extension View {
    func memorySurface() -> some View {
        background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}
