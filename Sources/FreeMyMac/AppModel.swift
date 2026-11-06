import SwiftUI
import FreeMyMacCore

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    var undo: [TrashRecord] = []
    var failures: [CleanFailure] = []
}

struct CleanRequest: Identifiable {
    let id = UUID()
    let items: [CleanupItem]
    /// Needs a confirmation every time, because it can't be undone or needs a password.
    var alwaysConfirm: Bool { items.contains { $0.action == .emptyTrash || $0.action == .removeAsAdmin } }
}

struct DeleteRequest: Identifiable {
    let path: String
    let size: Int64
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// Set on the whole app, so sheets, menus, and the window's glass all follow.
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let env = FreeMyMacEnv.current()
    let safety: SafetyGuard
    let cleaner: Cleaner
    private let defaults: UserDefaults

    @Published var screen: Screen? = .overview
    @Published var volume: VolumeInfo?
    @Published var hasFullDiskAccess = false
    @Published var running: [RunningApp] = []

    @Published var root: FileNode?
    @Published var exploring: FileNode?
    @Published var largeFiles: [LargeFile] = []
    @Published var blockedFolders: [String] = []
    @Published var isScanning = false
    @Published var scannedFiles = 0

    @Published var catalog: [CleanupItem] = []
    @Published var isLoadingCatalog = false
    @Published var selectedItems: Set<String> = []
    @Published var busyItems: Set<String> = []
    private var userDeselected: Set<String> = []

    @Published var apps: [InstalledApp] = []
    @Published var isLoadingApps = false

    @Published var toast: Toast?
    @Published var pendingClean: CleanRequest?
    @Published var pendingUninstall: InstalledApp?
    @Published var pendingDelete: DeleteRequest?

    @Published var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            appearance.apply()
        }
    }
    /// On: files are deleted outright. Off: they go to the Trash, with Undo.
    @Published var deletePermanently: Bool {
        didSet { defaults.set(deletePermanently, forKey: "deletePermanently") }
    }
    @Published var skipSafeConfirmation: Bool {
        didSet { defaults.set(skipSafeConfirmation, forKey: "skipSafeConfirmation") }
    }
    @Published var skipDeleteConfirmation: Bool {
        didSet { defaults.set(skipDeleteConfirmation, forKey: "skipDeleteConfirmation") }
    }

    var deleteVerb: String { deletePermanently ? "Delete permanently" : "Move to the Trash" }

    private var scanProgress: ScanProgress?
    private var scanGeneration = 0
    private var catalogGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var toastDismissal: Task<Void, Never>?

    init() {
        let env = FreeMyMacEnv.current()
        let safety = SafetyGuard(env: env, ownBundle: Bundle.main.bundlePath)
        self.safety = safety
        self.cleaner = Cleaner(env: env, safety: safety)

        // Test mode keeps its own settings, so trying things can't change real ones.
        let defaults = env.isFixture ? (UserDefaults(suiteName: "com.pavitra.freemymac.test") ?? .standard) : .standard
        self.defaults = defaults
        self.appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        self.deletePermanently = defaults.object(forKey: "deletePermanently") as? Bool ?? true
        self.skipSafeConfirmation = defaults.bool(forKey: "skipSafeConfirmation")
        self.skipDeleteConfirmation = defaults.bool(forKey: "skipDeleteConfirmation")
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        appearance.apply()
        refreshStatus()
        refreshRunningApps()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunningApps() }
            })
        }
        // Coming back from System Settings is the moment Full Disk Access may have changed.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleBecameActive() }
        })
        rescanEverything()
    }

    private func handleBecameActive() {
        let previous = hasFullDiskAccess
        refreshStatus()
        if hasFullDiskAccess != previous { rescanEverything() }
    }

    func rescanEverything() {
        scanDisk()
        loadCatalog()
        loadApps()
    }

    func refreshStatus() {
        volume = VolumeInfo.current()
        hasFullDiskAccess = Permissions.hasFullDiskAccess(env: env)
    }

    func refreshRunningApps() {
        let own = Bundle.main.bundleIdentifier
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != own }
            .map { RunningApp(name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier ?? "") }
    }

    // MARK: - Scanning

    func scanDisk() {
        scanProgress?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let progress = ScanProgress()
        scanProgress = progress
        isScanning = true
        let scanRoot = env.scanRoot

        Task { [weak self] in
            while let self, self.scanGeneration == generation, self.isScanning {
                self.scannedFiles = progress.files
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        Task.detached(priority: .utility) { [weak self] in
            let result = DiskScanner.scan(root: scanRoot, progress: progress)
            await self?.finishScan(result, generation: generation)
        }
    }

    private func finishScan(_ result: ScanResult, generation: Int) {
        guard generation == scanGeneration else { return }
        let previous = exploring?.path
        root = result.root
        exploring = previous.flatMap { result.root.node(at: $0) } ?? result.root
        let trashPrefix = env.trashPath + "/"
        largeFiles = result.largeFiles.filter { !$0.path.hasPrefix(trashPrefix) && safety.check($0.path).isAllowed }
        blockedFolders = result.blocked
        isScanning = false
        refreshStatus()
    }

    func loadCatalog() {
        catalogGeneration += 1
        let generation = catalogGeneration
        isLoadingCatalog = true
        let input = CatalogBuilder.Input(env: env, safety: safety)
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = CatalogBuilder.build(input)
            await self?.finishCatalog(items, generation: generation)
        }
    }

    private func finishCatalog(_ items: [CleanupItem], generation: Int) {
        guard generation == catalogGeneration else { return }
        catalog = items
        isLoadingCatalog = false
        // Safe rows start ticked. Rows that could matter to you never do.
        selectedItems = Set(items.filter { $0.tier == .safe && !userDeselected.contains($0.id) }.map(\.id))
            .union(selectedItems.intersection(items.map(\.id)))
    }

    func loadApps() {
        isLoadingApps = true
        let env = env
        Task.detached(priority: .utility) { [weak self] in
            let found = AppInventory.installedApps(env: env)
            await self?.finishApps(found)
        }
    }

    private func finishApps(_ found: [InstalledApp]) {
        apps = found
        isLoadingApps = false
    }

    // MARK: - Figures

    var segments: [StorageSegment] {
        guard let volume else { return [] }
        return StorageBreakdown.segments(volume: volume, root: root, env: env)
    }

    var hiddenBytes: Int64 { segments.first { $0.kind == .hidden }?.size ?? 0 }
    var safeItems: [CleanupItem] { catalog.filter { $0.tier == .safe } }
    var safeReclaimable: Int64 { safeItems.reduce(0) { $0 + $1.reclaimable(running: running) } }
    var reviewReclaimable: Int64 { catalog.filter { $0.tier != .safe }.reduce(0) { $0 + $1.reclaimable(running: running) } }
    var totalReclaimable: Int64 { safeReclaimable + reviewReclaimable }

    var selectedTotal: Int64 {
        catalog.filter { selectedItems.contains($0.id) }.reduce(0) { $0 + $1.reclaimable(running: running) }
    }

    func setSelected(_ item: CleanupItem, _ selected: Bool) {
        if selected {
            selectedItems.insert(item.id)
            userDeselected.remove(item.id)
        } else {
            selectedItems.remove(item.id)
            userDeselected.insert(item.id)
        }
    }

    // MARK: - Cleaning

    /// The big button: everything that rebuilds itself, nothing else.
    func freeUpSafeItems() {
        request(safeItems)
    }

    func cleanSelected() {
        request(catalog.filter { selectedItems.contains($0.id) && $0.action != .emptyTrash && $0.action != .removeAsAdmin })
    }

    func request(_ items: [CleanupItem]) {
        guard !items.isEmpty else { return }
        let request = CleanRequest(items: items)
        let allSafe = items.allSatisfy { $0.tier == .safe }
        let skip = allSafe ? skipSafeConfirmation : (deletePermanently && skipSafeConfirmation && skipDeleteConfirmation)
        if skip && !request.alwaysConfirm {
            perform(items)
        } else {
            pendingClean = request
        }
    }

    /// A single row's own button. Caches rebuild themselves, so they go straight
    /// through. Your own files ask once, unless you've said not to. Emptying the
    /// Trash and anything needing a password always asks.
    func cleanRow(_ item: CleanupItem) {
        let asksAlways = item.action == .emptyTrash || item.action == .removeAsAdmin
        let asksForFiles = item.action == .moveToTrash && deletePermanently && !skipDeleteConfirmation
        if asksAlways || asksForFiles {
            pendingClean = CleanRequest(items: [item])
        } else {
            perform([item])
        }
    }

    func cleanEntry(_ entry: CatalogEntry, of item: CleanupItem) {
        if item.action == .moveToTrash {
            discard(path: entry.path)
        } else {
            perform([item], entries: [item.id: [entry]])
        }
    }

    func perform(_ items: [CleanupItem], entries: [String: [CatalogEntry]] = [:]) {
        let cleaner = cleaner
        busyItems.formUnion(items.map(\.id))
        refreshRunningApps()
        let running = running
        let permanently = deletePermanently
        Task.detached(priority: .userInitiated) { [weak self] in
            var report = CleanReport()
            for item in items {
                report.merge(cleaner.clean(item, entries: entries[item.id], running: running, permanently: permanently))
            }
            await self?.finishClean(report, items: items)
        }
    }

    private func finishClean(_ report: CleanReport, items: [CleanupItem]) {
        busyItems.subtract(items.map(\.id))
        show(report)
        refreshAfterChange()
    }

    private func show(_ report: CleanReport) {
        if report.wasCancelled && report.removed == 0 { return }
        var parts: [String] = []
        if report.bytes > 0 { parts.append("Freed \(formatBytes(report.bytes)).") }
        if report.bytesTrashed > 0 {
            parts.append("Moved \(formatBytes(report.bytesTrashed)) to the Trash. It's still using space until you empty the Trash.")
        }
        if !report.skippedInUse.isEmpty {
            parts.append("Skipped \(report.skippedInUse.joined(separator: ", ")) because they're open.")
        }
        if !report.failures.isEmpty {
            parts.append("\(report.failures.count) item\(report.failures.count == 1 ? "" : "s") couldn't be removed.")
        }
        if parts.isEmpty { parts.append("Nothing to remove.") }
        present(Toast(message: parts.joined(separator: " "), undo: report.trashed, failures: report.failures))
    }

    func present(_ newToast: Toast) {
        withAnimation(.snappy(duration: 0.2)) { toast = newToast }
        toastDismissal?.cancel()
        // A message with problems or an Undo stays until it's dealt with or replaced.
        guard newToast.failures.isEmpty && newToast.undo.isEmpty else { return }
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.2)) { self?.toast = nil }
        }
    }

    private func refreshAfterChange() {
        refreshStatus()
        loadCatalog()
        scanDisk()
        // APFS releases space a moment after a delete returns.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.refreshStatus()
        }
    }

    // MARK: - Removing single items

    /// The trash icon on every row: follows the Delete Permanently setting.
    func discard(path: String) {
        guard deletePermanently else {
            moveToTrash(path: path)
            return
        }
        if skipDeleteConfirmation {
            deleteNow(path: path)
        } else {
            let size = root?.node(at: path)?.size ?? DiskScanner.measure(path)
            pendingDelete = DeleteRequest(path: path, size: size)
        }
    }

    func deleteNow(path: String) {
        let cleaner = cleaner
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = cleaner.deleteFully([path])
            await self?.finishDelete(report, path: path)
        }
    }

    private func finishDelete(_ report: CleanReport, path: String) {
        if report.removed > 0 {
            if let node = root?.node(at: path) {
                if exploring === node { exploring = node.parent }
                node.detach()
            }
            largeFiles.removeAll { $0.path == path }
            objectWillChange.send()
        }
        show(report)
        refreshStatus()
        loadCatalog()
    }

    func moveToTrash(path: String) {
        let cleaner = cleaner
        let size = root?.node(at: path)?.size ?? DiskScanner.measure(path)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let record = try cleaner.moveToTrash(path)
                await self?.finishTrash(record, size: size)
            } catch {
                await self?.present(Toast(message: "Couldn't move this to the Trash.", failures: [CleanFailure(path: path, reason: error.localizedDescription)]))
            }
        }
    }

    private func finishTrash(_ record: TrashRecord, size: Int64) {
        if let node = root?.node(at: record.original) {
            if exploring === node { exploring = node.parent }
            node.detach()
        }
        largeFiles.removeAll { $0.path == record.original }
        objectWillChange.send()
        let name = (record.original as NSString).lastPathComponent
        present(Toast(message: "Moved \(name) to the Trash (\(formatBytes(size))). It's still using space until you empty the Trash.", undo: [record]))
        refreshStatus()
        loadCatalog()
    }

    func undo(_ records: [TrashRecord]) {
        var failures: [CleanFailure] = []
        for record in records {
            do {
                try cleaner.restore(record)
            } catch {
                failures.append(CleanFailure(path: record.original, reason: error.localizedDescription))
            }
        }
        if failures.isEmpty {
            present(Toast(message: "Put back \(records.count) item\(records.count == 1 ? "" : "s")."))
        } else {
            present(Toast(message: "Some items couldn't be put back.", failures: failures))
        }
        refreshAfterChange()
    }

    // MARK: - Apps

    func leftovers(for app: InstalledApp) -> [AppLeftover] {
        AppInventory.leftovers(for: app, env: env, safety: safety)
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        running.contains { $0.bundleID == app.bundleID }
    }

    func uninstall(_ app: InstalledApp, leftovers: [AppLeftover]) {
        let cleaner = cleaner
        refreshRunningApps()
        guard !isRunning(app) else {
            present(Toast(message: "Quit \(app.name) first, then uninstall it."))
            return
        }
        let paths = [app.path] + leftovers.map(\.path)
        if deletePermanently {
            Task.detached(priority: .userInitiated) { [weak self] in
                let report = cleaner.deleteFully(paths)
                await self?.finishPermanentUninstall(app, report: report)
            }
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            var records: [TrashRecord] = []
            var failures: [CleanFailure] = []
            for path in paths {
                do {
                    records.append(try cleaner.moveToTrash(path))
                } catch {
                    failures.append(CleanFailure(path: path, reason: error.localizedDescription))
                }
            }
            await self?.finishUninstall(app, records: records, failures: failures)
        }
    }

    private func finishPermanentUninstall(_ app: InstalledApp, report: CleanReport) {
        if report.wasCancelled && report.removed == 0 { return }
        let isGone = !FileManager.default.fileExists(atPath: app.path)
        let message = isGone ? "Uninstalled \(app.name) and freed \(formatBytes(report.bytes))." : "Couldn't uninstall \(app.name)."
        present(Toast(message: message, failures: report.failures))
        loadApps()
        refreshAfterChange()
    }

    private func finishUninstall(_ app: InstalledApp, records: [TrashRecord], failures: [CleanFailure]) {
        let message = records.contains { $0.original == app.path }
            ? "Moved \(app.name) to the Trash. Empty the Trash to get the space back."
            : "Couldn't uninstall \(app.name)."
        present(Toast(message: message, undo: records, failures: failures))
        loadApps()
        refreshAfterChange()
    }

    // MARK: - System

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL)
    }

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func revealActivityLog() {
        let url = URL(fileURLWithPath: env.logPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            present(Toast(message: "Nothing has been removed yet, so the log is empty."))
        }
    }
}
