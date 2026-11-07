import SwiftUI
import FreeMyMacCore

struct CleanupView: View {
    @EnvironmentObject var model: AppModel

    private var safe: [CleanupItem] { model.catalog.filter { $0.tier == .safe } }
    private var review: [CleanupItem] {
        model.catalog.filter { $0.tier == .review && visible($0) }
    }
    private var admin: [CleanupItem] { model.catalog.filter { $0.tier == .admin } }

    private func visible(_ item: CleanupItem) -> Bool {
        item.action != .emptyTrash || !item.entries.isEmpty || !model.hasFullDiskAccess
    }

    var body: some View {
        List {
            if !safe.isEmpty {
                Section {
                    ForEach(safe) { CleanupRow(item: $0) }
                } header: {
                    SectionHeader(title: "Safe to remove",
                                  detail: "These rebuild themselves, so they're removed outright. The Trash wouldn't free the space.")
                }
            }
            if !review.isEmpty {
                Section {
                    ForEach(review) { CleanupRow(item: $0) }
                } header: {
                    SectionHeader(title: "Check first",
                                  detail: model.deletePermanently
                                      ? "These are yours, and deleting them is permanent. Open a row to see each item."
                                      : "These go to the Trash, so you can put them back. Open a row to see each item.")
                }
            }
            if !admin.isEmpty {
                Section {
                    ForEach(admin) { CleanupRow(item: $0) }
                } header: {
                    SectionHeader(title: "Needs your password",
                                  detail: "These belong to the whole Mac. macOS asks for your password, and FreeMyMac never sees it.")
                }
            }
            if model.catalog.isEmpty && !model.isLoadingCatalog {
                Text("Nothing to clean right now.").foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.catalog.isEmpty && model.isLoadingCatalog {
                ProgressView("Measuring what can be cleaned…")
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("Clean Up")
        .toolbar {
            ToolbarItem {
                Button { model.loadCatalog(fromDisk: true) } label: {
                    Label("Measure Again", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingCatalog)
                .help("Measure everything again")
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(formatBytes(model.selectedTotal)) selected").font(.headline)
                Text("\(model.selectedItems.count) of \(model.catalog.filter(isSelectable).count) rows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clean Selected") { model.cleanSelected() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.selectedTotal == 0 || !model.busyItems.isEmpty)
        }
        .glassCard(cornerRadius: 20, padding: 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func isSelectable(_ item: CleanupItem) -> Bool {
        item.action != .emptyTrash && item.action != .removeAsAdmin
    }
}

private struct SectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(.primary)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

struct CleanupRow: View {
    @EnvironmentObject var model: AppModel
    let item: CleanupItem
    @LocalState private var isExpanded = false

    private var isBusy: Bool { model.busyItems.contains(item.id) }
    private var size: Int64 { item.reclaimable(running: model.running) }
    private var inUse: [String] {
        Array(Set(item.entries.compactMap { CatalogBuilder.runningOwner(of: $0, running: model.running) })).sorted()
    }
    private var needsAccess: Bool { item.action == .emptyTrash && !model.hasFullDiskAccess }
    private var isSelectable: Bool { item.action != .emptyTrash && item.action != .removeAsAdmin }

    // Not a DisclosureGroup: its label swallows the controls inside it, so the
    // Clean button wouldn't reliably receive clicks or reach VoiceOver.
    var body: some View {
        Group {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.entries.isEmpty)
                .opacity(item.entries.isEmpty ? 0 : 1)
                .accessibilityLabel(isExpanded ? "Hide items in \(item.title)" : "Show items in \(item.title)")

                if isSelectable {
                    Toggle("Include \(item.title)", isOn: Binding(
                        get: { model.selectedItems.contains(item.id) },
                        set: { model.setSelected(item, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Color.clear.frame(width: 14, height: 14).accessibilityHidden(true)
                }
                Image(systemName: item.symbol)
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).fontWeight(.medium)
                    Text(item.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !inUse.isEmpty {
                        Text("Skipping while open: \(inUse.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Text(needsAccess ? "Unknown" : formatBytes(size))
                    .monospacedDigit()
                    .frame(minWidth: 70, alignment: .trailing)
                actionButton
            }
            .padding(.vertical, 4)

            if isExpanded {
                ForEach(item.entries) { entry in
                    EntryRow(entry: entry, item: item)
                        .padding(.leading, 26)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isBusy {
            ProgressView().controlSize(.small).frame(width: 96)
        } else if needsAccess {
            Button("Grant Access") { model.openFullDiskAccessSettings() }
                .frame(width: 96)
        } else {
            Button(buttonTitle) { model.cleanRow(item) }
                .frame(width: 96)
                .disabled(size == 0)
                .help(buttonHelp)
        }
    }

    private var buttonTitle: String {
        switch item.action {
        case .moveToTrash: return model.deletePermanently ? "Delete" : "To Trash"
        case .emptyTrash: return "Empty"
        case .removeAsAdmin: return "Clean…"
        default: return "Clean"
        }
    }

    private var buttonHelp: String {
        switch item.action {
        case .moveToTrash: return model.deletePermanently ? "Permanently delete all of this" : "Move all of this to the Trash"
        case .emptyTrash: return "Permanently delete everything in the Trash"
        case .removeAsAdmin: return "Remove these after macOS asks for your password"
        default: return "Remove these now"
        }
    }
}

private struct EntryRow: View {
    @EnvironmentObject var model: AppModel
    let entry: CatalogEntry
    let item: CleanupItem

    private var owner: String? { CatalogBuilder.runningOwner(of: entry, running: model.running) }

    var body: some View {
        HStack(spacing: 8) {
            PathIcon(path: entry.path)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Text(owner.map { "Open now: \($0)" } ?? displayPath(entry.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(formatBytes(entry.size)).monospacedDigit().foregroundStyle(.secondary)
            if item.action == .moveToTrash || item.action == .removePermanently {
                Button {
                    model.cleanEntry(entry, of: item)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(owner != nil)
                .help(item.action == .moveToTrash ? model.deleteVerb : "Remove now")
                .accessibilityLabel(item.action == .moveToTrash ? "\(model.deleteVerb): \(entry.name)" : "Remove \(entry.name)")
            }
        }
        .revealButton(entry.path)
    }
}

struct ConfirmCleanSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: CleanRequest
    @LocalState private var dontAskAgain = false

    private var allSafe: Bool { request.items.allSatisfy { $0.tier == .safe } }
    private var total: Int64 { request.items.reduce(0) { $0 + $1.reclaimable(running: model.running) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(request.items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).frame(width: 20).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                Text(fate(item)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formatBytes(item.reclaimable(running: model.running))).monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: min(240, CGFloat(request.items.count) * 40))
            if !request.alwaysConfirm && (allSafe || model.deletePermanently) {
                Toggle(allSafe ? "Don't ask again for items that rebuild themselves" : "Don't ask again before deleting", isOn: $dontAskAgain)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    if dontAskAgain {
                        model.skipSafeConfirmation = true
                        if !allSafe { model.skipDeleteConfirmation = true }
                    }
                    let items = request.items
                    dismiss()
                    model.perform(items)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var title: String {
        if request.items.count == 1, request.items[0].action == .emptyTrash { return "Empty the Trash?" }
        return !allSafe && model.deletePermanently ? "Delete \(formatBytes(total))?" : "Clean \(formatBytes(total))?"
    }

    private var summary: String {
        if request.items.contains(where: { $0.action == .emptyTrash }) {
            return "Everything in the Trash is permanently deleted. This can't be undone."
        }
        if request.items.contains(where: { $0.action == .removeAsAdmin }) {
            return "macOS will ask for your password. These files are removed permanently, and apps recreate what they need."
        }
        if allSafe { return "Apps rebuild these files when they need them. Some may feel slower the first time. Apps that are open are skipped." }
        return model.deletePermanently ? "This can't be undone. Here's what happens to each row." : "Here's what happens to each row."
    }

    private func fate(_ item: CleanupItem) -> String {
        switch item.action {
        case .moveToTrash: return model.deletePermanently ? "Permanently deleted" : "Moved to the Trash, so you can put it back"
        case .emptyTrash: return "Permanently deleted"
        case .removeAsAdmin: return "Removed after you enter your password"
        case .command: return "Removed by Homebrew"
        case .removePermanently: return "Removed now and rebuilt when needed"
        }
    }

    private var actionTitle: String {
        if request.items.contains(where: { $0.action == .emptyTrash }) { return "Empty Trash" }
        return !allSafe && model.deletePermanently ? "Delete" : "Clean"
    }
}
