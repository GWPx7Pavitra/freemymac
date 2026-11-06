import SwiftUI
import FreeMyMacCore

// MARK: - Explore

struct ExploreView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let node = model.exploring {
                VStack(spacing: 0) {
                    Breadcrumbs(node: node)
                    Divider()
                    List {
                        if node.isBlocked {
                            blockedNotice
                        }
                        ForEach(node.children) { child in
                            ExploreRow(node: child, parentSize: node.size)
                        }
                        if node.smallCount > 0 {
                            HStack {
                                Image(systemName: "ellipsis.circle").frame(width: 20).foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                                Text("\(node.smallCount.formatted()) smaller items").foregroundStyle(.secondary)
                                Spacer()
                                Text(formatBytes(node.smallSize)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            } else {
                ContentUnavailableView {
                    Label("Scanning your disk", systemImage: "internaldrive")
                } description: {
                    Text("\(model.scannedFiles.formatted()) files so far").monospacedDigit()
                }
            }
        }
        .navigationTitle("Explore Disk")
        .toolbar {
            ToolbarItem {
                Button { model.scanDisk() } label: {
                    if model.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isScanning)
                .help("Scan the disk again")
            }
        }
    }

    private var blockedNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("macOS won't let FreeMyMac read this folder", systemImage: "lock")
                .font(.headline)
            if model.hasFullDiskAccess {
                Text("It's reserved for macOS or an administrator.").foregroundStyle(.secondary)
            } else {
                Text("Turning on Full Disk Access usually fixes this.").foregroundStyle(.secondary)
                Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct Breadcrumbs: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    private var chain: [FileNode] {
        var nodes: [FileNode] = []
        var current: FileNode? = node
        while let item = current {
            nodes.insert(item, at: 0)
            current = item.parent
        }
        return nodes
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.exploring = node.parent
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(node.parent == nil)
            .accessibilityLabel("Go up one folder")
            .keyboardShortcut(.upArrow, modifiers: .command)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(chain.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        Button(item.parent == nil ? "Macintosh HD" : item.name) {
                            model.exploring = item
                        }
                        .buttonStyle(.plain)
                        .fontWeight(item === node ? .semibold : .regular)
                        .foregroundStyle(item === node ? .primary : .secondary)
                    }
                }
            }
            Spacer()
            Text(formatBytes(node.size)).monospacedDigit().fontWeight(.semibold)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct ExploreRow: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode
    let parentSize: Int64

    private var verdict: SafetyGuard.Verdict { model.safety.check(node.path) }
    private var canOpen: Bool { node.isDirectory && (!node.children.isEmpty || node.smallCount > 0 || node.isBlocked) }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if canOpen { model.exploring = node }
            } label: {
                HStack(spacing: 10) {
                    PathIcon(path: node.path)
                    HStack(spacing: 5) {
                        Text(node.name).lineLimit(1).truncationMode(.middle)
                        if node.isBlocked {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("Can't be read")
                        }
                    }
                    Spacer(minLength: 12)
                    SizeBar(fraction: parentSize > 0 ? Double(node.size) / Double(parentSize) : 0)
                        .frame(width: 120)
                    Text(node.isBlocked && node.size == 0 ? "Hidden" : formatBytes(node.size))
                        .monospacedDigit()
                        .frame(width: 76, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .opacity(canOpen ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.discard(path: node.path)
            } label: {
                Image(systemName: verdict.isAllowed ? "trash" : "lock")
            }
            .buttonStyle(.borderless)
            .disabled(!verdict.isAllowed)
            .help(verdict.reason ?? model.deleteVerb)
            .accessibilityLabel(verdict.isAllowed ? "\(model.deleteVerb): \(node.name)" : "\(node.name) is protected")
        }
        .revealButton(node.path)
    }
}

private struct SizeBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(Palette.series1)
                    .frame(width: max(2, geometry.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Large files

struct LargeFilesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.largeFiles.isEmpty {
                ContentUnavailableView {
                    Label(model.isScanning ? "Looking for large files" : "No files over 100 MB",
                          systemImage: "doc.richtext")
                } description: {
                    Text(model.isScanning ? "\(model.scannedFiles.formatted()) files checked so far" : "Files macOS protects aren't listed.")
                        .monospacedDigit()
                }
            } else {
                List {
                    Section {
                        ForEach(model.largeFiles) { LargeFileRow(file: $0) }
                    } header: {
                        Text("\(model.largeFiles.count) files over 100 MB, totaling \(formatBytes(model.largeFiles.reduce(0) { $0 + $1.size })). Files macOS protects aren't listed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
                    .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Large Files")
    }
}

private struct LargeFileRow: View {
    @EnvironmentObject var model: AppModel
    let file: LargeFile

    var body: some View {
        HStack(spacing: 10) {
            PathIcon(path: file.path)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text((file.path as NSString).deletingLastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let modified = file.modified {
                Text(modified, format: .dateTime.day().month(.abbreviated).year())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(formatBytes(file.size))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
            Button {
                model.discard(path: file.path)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(model.deleteVerb)
            .accessibilityLabel("\(model.deleteVerb): \(file.name)")
        }
        .revealButton(file.path)
    }
}

// MARK: - Apps

struct AppsView: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var sortByLastUsed = false

    private var sorted: [InstalledApp] {
        guard sortByLastUsed else { return model.apps }
        return model.apps.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
    }

    var body: some View {
        Group {
            if model.apps.isEmpty {
                if model.isLoadingApps {
                    ProgressView("Measuring your apps…")
                } else {
                    ContentUnavailableView("No apps found", systemImage: "square.grid.2x2")
                }
            } else {
                List(sorted) { AppRow(app: $0) }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Apps")
        .toolbar {
            ToolbarItem {
                Picker("Sort", selection: $sortByLastUsed) {
                    Text("Largest").tag(false)
                    Text("Least Used").tag(true)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

private struct AppRow: View {
    @EnvironmentObject var model: AppModel
    let app: InstalledApp

    private var verdict: SafetyGuard.Verdict { model.safety.check(app.path) }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(usage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatBytes(app.size)).monospacedDigit().frame(width: 76, alignment: .trailing)
            Button("Uninstall…") { model.pendingUninstall = app }
                .disabled(!verdict.isAllowed || model.isRunning(app))
                .help(model.isRunning(app) ? "Quit \(app.name) first" : (verdict.reason ?? "Choose what to remove"))
        }
        .padding(.vertical, 2)
        .revealButton(app.path)
    }

    private var usage: String {
        if model.isRunning(app) { return "Open now" }
        guard let date = app.lastUsed else { return "No usage recorded" }
        return "Last opened \(date.formatted(.relative(presentation: .named)))"
    }
}

struct UninstallSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let app: InstalledApp
    let leftovers: [AppLeftover]
    @LocalState private var chosen: Set<AppLeftover>

    init(app: InstalledApp, leftovers: [AppLeftover]) {
        self.app = app
        self.leftovers = leftovers
        _chosen = LocalState(wrappedValue: Set(leftovers.filter { !$0.isUserData }))
    }

    private var total: Int64 { app.size + chosen.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall \(app.name)?").font(.title2.weight(.semibold))
                    Text(model.deletePermanently ? "This is permanent, and the space comes back right away." : "Everything goes to the Trash, so you can put it back.").foregroundStyle(.secondary)
                }
            }
            if !leftovers.isEmpty {
                Text("Also remove").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(leftovers) { leftover in
                            Toggle(isOn: Binding(
                                get: { chosen.contains(leftover) },
                                set: { isOn in
                                    if isOn { chosen.insert(leftover) } else { chosen.remove(leftover) }
                                }
                            )) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(leftover.label)
                                        Text(leftover.isUserData ? "Your settings and documents for this app" : "Disposable")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(formatBytes(leftover.size)).monospacedDigit()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A set height: a sheet doesn't grow to fit a ScrollView by itself.
                .frame(height: min(220, CGFloat(leftovers.count) * 42))
            }
            HStack {
                Text(formatBytes(total)).font(.headline).monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.deletePermanently ? "Uninstall" : "Move to Trash") {
                    let selected = Array(chosen)
                    dismiss()
                    model.uninstall(app, leftovers: selected)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}
