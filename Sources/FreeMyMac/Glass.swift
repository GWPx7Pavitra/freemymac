import SwiftUI
import FreeMyMacCore

extension View {
    /// A pane of Liquid Glass. Used for groups of content, not for every element,
    /// because glass stacked on glass stops reading as glass and costs legibility.
    func glassCard(cornerRadius: CGFloat = 18, padding: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// The System / Light / Dark switch, styled like a floating iOS tab bar: a glass
/// capsule of icons, where the chosen icon fills in and a highlight springs to it.
struct ThemeBar: View {
    @EnvironmentObject var model: AppModel

    private let height: CGFloat = 44
    private let inset: CGFloat = 4

    var body: some View {
        let modes = Appearance.allCases
        let selected = modes.firstIndex(of: model.appearance) ?? 0

        GeometryReader { geometry in
            let cell = geometry.size.width / CGFloat(modes.count)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.14))
                    .frame(width: cell - inset * 2, height: height - inset * 2)
                    .offset(x: CGFloat(selected) * cell + inset)
                    .animation(.spring(response: 0.32, dampingFraction: 0.72), value: model.appearance)

                HStack(spacing: 0) {
                    ForEach(modes) { mode in
                        button(for: mode, isSelected: mode == model.appearance)
                            .frame(width: cell, height: height)
                    }
                }
            }
        }
        .frame(height: height)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme")
    }

    private func button(for mode: Appearance, isSelected: Bool) -> some View {
        Button {
            model.appearance = mode
        } label: {
            Image(systemName: isSelected && mode != .system ? mode.symbol + ".fill" : mode.symbol)
                .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The round button that sits beside the theme bar.
struct SettingsBubble: View {
    var body: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent("Theme") {
                    ThemeBar()
                        .frame(width: 170)
                }
            }
            Section {
                Picker("When you delete a file", selection: $model.deletePermanently) {
                    Text("Delete it permanently").tag(true)
                    Text("Move it to the Trash").tag(false)
                }
                if model.deletePermanently {
                    Toggle("Ask before deleting my files", isOn: Binding(
                        get: { !model.skipDeleteConfirmation },
                        set: { model.skipDeleteConfirmation = !$0 }
                    ))
                }
                Toggle("Ask before cleaning caches", isOn: Binding(
                    get: { !model.skipSafeConfirmation },
                    set: { model.skipSafeConfirmation = !$0 }
                ))
            } header: {
                Text("Deleting")
            } footer: {
                Text(model.deletePermanently
                     ? "Space comes back right away, but there's no Undo. System files, keychains, and iCloud are always protected."
                     : "You can put things back, but they keep using space until you empty the Trash.")
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    if model.hasFullDiskAccess {
                        Label("On", systemImage: "checkmark.circle.fill")
                    } else {
                        Button("Turn On…") { model.openFullDiskAccessSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .containerBackground(.ultraThinMaterial, for: .window)
    }
}

struct ConfirmDeleteSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: DeleteRequest
    @LocalState private var dontAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: request.path))
                    .resizable()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete \(request.name) permanently?")
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text("\(formatBytes(request.size)) comes back right away. This can't be undone.")
                        .foregroundStyle(.secondary)
                }
            }
            Text(request.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Toggle("Don't ask again", isOn: $dontAskAgain)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    if dontAskAgain { model.skipDeleteConfirmation = true }
                    let path = request.path
                    dismiss()
                    model.deleteNow(path: path)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
