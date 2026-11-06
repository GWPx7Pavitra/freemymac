import SwiftUI
import FreeMyMacCore

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                if let volume = model.volume {
                    VStack(alignment: .leading, spacing: 18) {
                        CapacityBar(segments: model.segments, total: volume.total)
                        BreakdownTable(segments: model.segments, total: volume.total)
                    }
                    .glassCard()
                }
                actions
                if !model.hasFullDiskAccess { permissionCard }
                else if model.hiddenBytes > 5 << 30, !model.isScanning { hiddenNote }
                biggestFolders
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem {
                Button { model.rescanEverything() } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
                .help("Scan the disk again")
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let volume = model.volume {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(formatBytes(volume.free))
                        .font(.system(size: 52, weight: .semibold))
                    Text("free of \(formatBytes(volume.total))")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if volume.usedFraction >= 0.9 {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.critical)
                            .accessibilityHidden(true)
                        Text("Storage is low. macOS and apps start misbehaving below about 10% free.")
                    } else if volume.usedFraction >= 0.8 {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.serious)
                            .accessibilityHidden(true)
                        Text("Getting full.")
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.good)
                            .accessibilityHidden(true)
                        Text("Plenty of room.")
                    }
                }
                .foregroundStyle(.secondary)
            }
            if model.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning the disk: \(model.scannedFiles.formatted()) files so far")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.top, 4)
            }
        }
    }

    private var freeUpTitle: String {
        if model.isLoadingCatalog && model.catalog.isEmpty { return "Measuring caches…" }
        return model.safeReclaimable > 0 ? "Free Up \(formatBytes(model.safeReclaimable))" : "Caches Are Clean"
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    model.freeUpSafeItems()
                } label: {
                    Text(freeUpTitle)
                        .frame(minWidth: 170)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.safeReclaimable == 0 || !model.busyItems.isEmpty)

                Button("Review \(formatBytes(model.reviewReclaimable)) More") {
                    model.screen = .cleanup
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(model.reviewReclaimable == 0)
            }
            Text("Free Up removes caches, logs, and old package versions that rebuild themselves. Your documents and anything in open apps stay as they are.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.isScanning
                  ? "macOS is hiding part of your disk from FreeMyMac"
                  : "macOS is hiding \(formatBytes(model.hiddenBytes)) from FreeMyMac",
                  systemImage: "lock.fill")
                .font(.headline)
            Text("Without Full Disk Access, FreeMyMac can't measure Mail, Messages, Photos, the Trash, or the files apps keep in their private containers. This is often where the mystery space is. FreeMyMac only uses this access to measure files and remove the ones you choose.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Click the button, turn on FreeMyMac in the list, then come back. If FreeMyMac isn't listed, click + and choose it. macOS may ask you to reopen the app.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
                    .controlSize(.large)
                Button("Show FreeMyMac in Finder") { model.revealApp() }
                    .controlSize(.large)
            }
        }
        .glassCard()
    }

    private var hiddenNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(formatBytes(model.hiddenBytes)) can't be read by any app", systemImage: "lock")
                .font(.headline)
            Text("Full Disk Access is on, so what's left is usually locked to macOS itself: its Spotlight index, Time Machine snapshots, and system databases. It isn't safe to remove by hand.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()
    }

    @ViewBuilder
    private var biggestFolders: some View {
        let folders = model.root?.heaviest(limit: 8, minimum: 256 << 20) ?? []
        if !folders.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Biggest folders").font(.headline)
                VStack(spacing: 0) {
                    ForEach(folders) { node in
                        Button {
                            model.exploring = node.isDirectory ? node : node.parent
                            model.screen = .explore
                        } label: {
                            HStack(spacing: 10) {
                                PathIcon(path: node.path)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(node.name).lineLimit(1)
                                    Text(node.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(formatBytes(node.size)).monospacedDigit().foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .revealButton(node.path)
                        if node.id != folders.last?.id { Divider() }
                    }
                }
            }
            .glassCard()
        }
    }
}

/// The whole disk as one segmented bar. Sizes appear inside any block wide
/// enough to hold them. Every block also has a tooltip and an accessible name.
struct CapacityBar: View {
    let segments: [StorageSegment]
    let total: Int64
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let visible = segments.filter { $0.size > 0 }
            let gapTotal = CGFloat(max(0, visible.count - 1)) * 2
            let usable = max(0, geometry.size.width - gapTotal)
            HStack(spacing: 2) {
                ForEach(visible) { segment in
                    let width = max(2, usable * CGFloat(segment.size) / CGFloat(max(1, total)))
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Palette.color(for: segment.kind))
                        if width >= 62 {
                            Text(formatBytes(segment.size))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Palette.labelColor(for: segment.kind, scheme: scheme))
                                .lineLimit(1)
                                .padding(.leading, 7)
                        }
                    }
                    .frame(width: width)
                    .help(description(segment))
                    .accessibilityElement()
                    .accessibilityLabel(description(segment))
                }
            }
        }
        .frame(height: 28)
    }

    private func description(_ segment: StorageSegment) -> String {
        "\(segment.title): \(formatBytes(segment.size)), \(percent(segment.size, of: total))"
    }
}

/// Doubles as the bar's legend and its table view, in the same order as the bar.
struct BreakdownTable: View {
    let segments: [StorageSegment]
    let total: Int64

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            ForEach(segments) { segment in
                GridRow {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Palette.color(for: segment.kind))
                        .frame(width: 12, height: 12)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
                        .accessibilityHidden(true)
                    Text(segment.title)
                    Text(formatBytes(segment.size))
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                    Text(percent(segment.size, of: total))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(explanation(segment.kind))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func explanation(_ kind: StorageSegment.Kind) -> String {
        switch kind {
        case .files: return "Documents, Downloads, Desktop, and other folders"
        case .apps: return "Everything in Applications"
        case .appData: return "Your Library folder"
        case .developer: return "Hidden tool folders and Homebrew"
        case .system: return "Files shared by all users, and small files"
        case .hidden: return "Measured by macOS, but unreadable here"
        case .macOS: return "The system itself. Can't be cleaned"
        case .free: return "Available now"
        }
    }
}

func percent(_ part: Int64, of total: Int64) -> String {
    guard total > 0 else { return "0%" }
    let value = Double(part) / Double(total) * 100
    return value < 1 && part > 0 ? "<1%" : "\(Int(value.rounded()))%"
}
