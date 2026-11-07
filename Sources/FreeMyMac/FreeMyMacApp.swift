import SwiftUI
import FreeMyMacCore

@main
struct FreeMyMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("FreeMyMac") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.scanStatus)
                .frame(minWidth: 680, minHeight: 460)
                .containerBackground(.ultraThinMaterial, for: .window)
                .task { model.start() }
        }
        .defaultSize(width: 1080, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Storage") {
                Button("Rescan Disk") { model.rescanEverything() }
                    .keyboardShortcut("r")
                Divider()
                Button("Show Activity Log") { model.revealActivityLog() }
                Divider()
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Delete Permanently", isOn: $model.deletePermanently)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case overview, cleanup, explore, largeFiles, apps
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .cleanup: return "Clean Up"
        case .explore: return "Explore Disk"
        case .largeFiles: return "Large Files"
        case .apps: return "Apps"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "internaldrive"
        case .cleanup: return "sparkles"
        case .explore: return "folder"
        case .largeFiles: return "doc.richtext"
        case .apps: return "square.grid.2x2"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $model.screen) { screen in
                Label(screen.title, systemImage: screen.symbol)
                    .badge(screen == .cleanup && model.totalReclaimable > 0 ? Text(formatBytes(model.totalReclaimable)) : nil)
                    .tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            ZStack {
                Group {
                    switch model.screen ?? .overview {
                    case .overview: OverviewView()
                    case .cleanup: CleanupView()
                    case .explore: ExploreView()
                    case .largeFiles: LargeFilesView()
                    case .apps: AppsView()
                    }
                }
                .id(model.screen)
                .transition(.opacity)
            }
            .animation(.smooth(duration: 0.2), value: model.screen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { ToastView() }
        }
        .sheet(item: $model.pendingClean) { request in
            ConfirmCleanSheet(request: request)
        }
        .sheet(item: $model.pendingDelete) { request in
            ConfirmDeleteSheet(request: request)
        }
        .sheet(item: $model.pendingUninstall) { app in
            UninstallSheet(app: app, leftovers: model.leftovers(for: app))
        }
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.env.isFixture {
                Label("Test mode: only the test folder is touched", systemImage: "testtube.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.hasFullDiskAccess {
                Button {
                    model.openFullDiskAccessSettings()
                } label: {
                    Label("Full Disk Access is off", systemImage: "lock")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
            if let volume = model.volume {
                Text("\(formatBytes(volume.free)) free")
                    .font(.callout.weight(.medium))
                ProgressView(value: volume.usedFraction)
                    .progressViewStyle(.linear)
                    .tint(volume.usedFraction > 0.9 ? Palette.critical : Palette.series1)
                    .accessibilityLabel("Disk \(Int(volume.usedFraction * 100)) percent full")
            }
            HStack(spacing: 8) {
                ThemeBar()
                SettingsBubble()
            }
            .padding(.top, 6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bottom-of-window result message. Offers Undo when something went to the Trash.
struct ToastView: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var showingFailures = false

    var body: some View {
        if let toast = model.toast {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: toast.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(toast.failures.isEmpty ? Palette.good : Palette.serious)
                        .accessibilityHidden(true)
                    Text(toast.message)
                        .lineLimit(3)
                    Spacer(minLength: 12)
                    if !toast.failures.isEmpty {
                        Button(showingFailures ? "Hide Details" : "Details") { showingFailures.toggle() }
                    }
                    if !toast.undo.isEmpty {
                        Button("Undo") { model.undo(toast.undo) }
                    }
                    Button {
                        model.toast = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
                }
                if showingFailures {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(toast.failures) { failure in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(failure.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
            .glassCard(cornerRadius: 18, padding: 12)
            .frame(maxWidth: 640)
            .padding(.horizontal, 16)
            // Clears the Clean Selected bar on that screen.
            .padding(.bottom, model.screen == .cleanup ? 88 : 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

extension View {
    func revealButton(_ path: String) -> some View {
        contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }
}

struct PathIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: IconCache.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

/// The live file count. Only this text observes the counter, so the rest of the
/// window doesn't redraw while a scan runs.
struct ScannedFilesText: View {
    @EnvironmentObject var status: ScanStatus
    let format: (String) -> String

    var body: some View {
        Text(format(status.files.formatted()))
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}
