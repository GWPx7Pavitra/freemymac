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

/// The live file count while the disk is scanned. Kept apart from `AppModel`
/// so a counter ticking five times a second redraws only the text showing it.
@MainActor
final class ScanStatus: ObservableObject {
    @Published var files = 0
}

/// File icons, looked up once per path. Asking the workspace for an icon on
/// every redraw is slow enough to make scrolling stutter.
@MainActor
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2000
        return cache
    }()

    static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}

@MainActor
final class AppModel: ObservableObject {
    let env = FreeMyMacEnv.current()
    let safety: SafetyGuard
    let cleaner: Cleaner
    let scanStatus = ScanStatus()
    private let defaults: UserDefaults

    @Published var screen: Screen? = .overview
    @Published var volume: VolumeInfo? {
        didSet { if volume != oldValue { recomputeSegments() } }
    }
    @Published var hasFullDiskAccess = false
    @Published var running: [RunningApp] = [] {
        didSet { if running != oldValue { recomputeTotals() } }
    }

    // The scan. Everything derived from it is worked out once per change and
    // stored, so drawing a screen never walks the tree.
    @Published private(set) var tree: SharedTree?
    var root: FileNode? { tree?.root }
    @Published private(set) var exploring: FileNode?
    @Published private(set) var exploreEdge: Edge = .trailing
    @Published private(set) var largeFiles: [LargeFile] = []
    @Published private(set) var blockedFolders: [String] = []
    @Published private(set) var biggestFolders: [FileNode] = []
    @Published private(set) var segments: [StorageSegment] = []
    @Published private(set) var isScanning = false
    /// Replaying what changed on disk since the saved scan.
    @Published private(set) var isCatchingUp = false
    @Published private(set) var lastFullScan: Date?
    /// macOS is reporting changes, so the figures stay current on their own.
    @Published private(set) var isWatching = false

    @Published var catalog: [CleanupItem] = [] {
        didSet { recomputeTotals() }
    }
    @Published var isLoadingCatalog = false
    @Published var selectedItems: Set<String> = [] {
        didSet { if selectedItems != oldValue { recomputeSelection() } }
    }
    @Published var busyItems: Set<String> = []
    @Published private(set) var safeReclaimable: Int64 = 0
    @Published private(set) var reviewReclaimable: Int64 = 0
    @Published private(set) var selectedTotal: Int64 = 0
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
    private var summaryGeneration = 0
    private var catalogGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var toastDismissal: Task<Void, Never>?
    private var verdicts: [String: SafetyGuard.Verdict] = [:]

    // Watching for changes.
    private let historyID: String?
    private var watcher: ChangeWatcher?
    private var watchGeneration = 0
    private var pendingChanges: [DiskChange] = []
    private var pendingEventID: UInt64 = 0
    private var appliedEventID: UInt64 = 0
    private var isApplyingChanges = false
    private var historyCaughtUp = false
    /// The catalog and app sizes are read from the tree, so they wait until a
    /// loaded cache has caught up with the disk.
    private var listsWaitForTree = false
    private var cacheIsStale = false
    private var lastCacheSave = Date.distantPast

    init() {
        let env = FreeMyMacEnv.current()
        let safety = SafetyGuard(env: env, ownBundle: Bundle.main.bundlePath)
        self.safety = safety
        self.cleaner = Cleaner(env: env, safety: safety)
        self.historyID = ChangeWatcher.historyID(for: env.scanRoot)

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
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveCacheNow() }
        })
        loadSavedScan()
    }

    private func handleBecameActive() {
        let previous = hasFullDiskAccess
        refreshStatus()
        if hasFullDiskAccess != previous { rescanEverything() }
    }

    /// The Rescan button: reads the whole disk again, from scratch.
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

    /// Safety verdicts don't change while the app runs, and rows ask for them on every redraw.
    func verdict(for path: String) -> SafetyGuard.Verdict {
        if let known = verdicts[path] { return known }
        let verdict = safety.check(path)
        verdicts[path] = verdict
        return verdict
    }

    // MARK: - Saved scan

    /// Shows the last scan right away, then asks macOS what changed since and
    /// reads only those folders. A full scan happens only without a usable cache.
    private func loadSavedScan() {
        isCatchingUp = true
        let path = env.scanCachePath
        Task.detached(priority: .userInitiated) { [weak self] in
            let saved = ScanCache.read(from: path)
            await self?.finishLoadingSavedScan(saved)
        }
    }

    private func finishLoadingSavedScan(_ saved: (root: FileNode, header: ScanCache.Header)?) {
        guard let saved, let historyID,
              saved.header.scanRoot == env.scanRoot,
              saved.header.volumeID == historyID,
              saved.header.hadFullDiskAccess == hasFullDiskAccess else {
            isCatchingUp = false
            rescanEverything()
            return
        }
        install(SharedTree(root: saved.root), fullScanAt: saved.header.scannedAt)
        appliedEventID = saved.header.eventID
        listsWaitForTree = true
        startWatching(since: saved.header.eventID)
    }

    private func saveCache() {
        guard let tree, let historyID, !isScanning, !isCatchingUp else { return }
        let header = cacheHeader(historyID)
        let path = env.scanCachePath
        cacheIsStale = false
        lastCacheSave = Date()
        Task.detached(priority: .background) {
            let data = tree.read { ScanCache.encode($0, header: header) }
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// At quit, there's no time to hand the work to the background.
    private func saveCacheNow() {
        guard cacheIsStale, let tree, let historyID, !isScanning else { return }
        try? ScanCache.write(tree.root, header: cacheHeader(historyID), to: env.scanCachePath)
    }

    private func cacheHeader(_ historyID: String) -> ScanCache.Header {
        ScanCache.Header(scanRoot: env.scanRoot, volumeID: historyID, eventID: appliedEventID,
                         scannedAt: lastFullScan ?? Date(), hadFullDiskAccess: hasFullDiskAccess)
    }

    // MARK: - Scanning

    func scanDisk() {
        stopWatching()
        scanProgress?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let progress = ScanProgress()
        scanProgress = progress
        isScanning = true
        scanStatus.files = 0
        let scanRoot = env.scanRoot
        // Anything that changes during the scan is replayed from here afterwards.
        let since = ChangeWatcher.currentEventID

        Task { [weak self] in
            while let self, self.scanGeneration == generation, self.isScanning {
                self.scanStatus.files = progress.files
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        Task.detached(priority: .utility) { [weak self] in
            let result = DiskScanner.scan(root: scanRoot, progress: progress)
            await self?.finishScan(result, generation: generation, since: since)
        }
    }

    private func finishScan(_ result: ScanResult, generation: Int, since: UInt64) {
        guard generation == scanGeneration else { return }
        isScanning = false
        install(SharedTree(root: result.root), fullScanAt: Date())
        appliedEventID = since
        cacheIsStale = true
        refreshStatus()
        startWatching(since: since)
    }

    private func install(_ newTree: SharedTree, fullScanAt date: Date) {
        let previous = exploring?.path
        tree = newTree
        exploring = previous.flatMap { newTree.root.node(at: $0) } ?? newTree.root
        lastFullScan = date
        verdicts = [:]
        treeDidChange()
    }

    /// Works out everything the screens show from the tree, off the main thread.
    private func treeDidChange() {
        guard let tree else { return }
        recomputeSegments()
        summaryGeneration += 1
        let generation = summaryGeneration
        let trashPrefix = env.trashPath + "/"
        let safety = safety
        Task.detached(priority: .userInitiated) { [weak self] in
            let (summary, heaviest) = tree.read { root in
                (DiskScanner.summarize(root), root.heaviest(limit: 8, minimum: 256 << 20))
            }
            let large = summary.largeFiles.filter { !$0.path.hasPrefix(trashPrefix) && safety.check($0.path).isAllowed }
            await self?.finishSummary(large: large, blocked: summary.blocked, heaviest: heaviest, generation: generation)
        }
    }

    private func finishSummary(large: [LargeFile], blocked: [String], heaviest: [FileNode], generation: Int) {
        guard generation == summaryGeneration else { return }
        if large.map(\.id) != largeFiles.map(\.id) || large.map(\.size) != largeFiles.map(\.size) { largeFiles = large }
        if blocked != blockedFolders { blockedFolders = blocked }
        biggestFolders = heaviest
    }

    // MARK: - Watching for changes

    private func startWatching(since eventID: UInt64) {
        stopWatching()
        watchGeneration += 1
        let generation = watchGeneration
        historyCaughtUp = false
        isCatchingUp = true
        watcher = ChangeWatcher(path: env.scanRoot, since: eventID) { [weak self] signal in
            Task { @MainActor in self?.handle(signal, generation: generation) }
        }
        isWatching = watcher != nil
        if watcher == nil {
            // Without change reports, the scan is as current as it gets.
            historyCaughtUp = true
            finishCatchingUp()
        }
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        watchGeneration += 1
        isWatching = false
        pendingChanges = []
        pendingEventID = 0
    }

    private func handle(_ signal: ChangeWatcher.Signal, generation: Int) {
        guard generation == watchGeneration else { return }
        switch signal {
        case .changes(let changes, let lastEventID):
            pendingChanges += changes
            pendingEventID = max(pendingEventID, lastEventID)
            applyPendingChanges()
        case .caughtUp(let lastEventID):
            pendingEventID = max(pendingEventID, lastEventID)
            historyCaughtUp = true
            applyPendingChanges()
        case .lostTrack:
            scanDisk()
        }
    }

    private func applyPendingChanges() {
        guard !isApplyingChanges, let tree else { return }
        guard !pendingChanges.isEmpty else {
            appliedEventID = max(appliedEventID, pendingEventID)
            finishCatchingUp()
            return
        }
        let changes = pendingChanges
        let eventID = pendingEventID
        pendingChanges = []
        guard case .refresh(let targets) = TreeRefresher.plan(changes, root: tree.root, rootDiskPath: env.scanRoot) else {
            scanDisk()
            return
        }
        guard !targets.isEmpty else {
            appliedEventID = max(appliedEventID, eventID)
            finishCatchingUp()
            return
        }
        isApplyingChanges = true
        Task.detached(priority: .utility) { [weak self] in
            let listings = TreeRefresher.list(targets)
            await self?.finishApplying(listings, to: tree, eventID: eventID)
        }
    }

    private func finishApplying(_ listings: [TreeRefresher.Listing], to changedTree: SharedTree, eventID: UInt64) {
        isApplyingChanges = false
        // A full scan replaced the tree while this was being read.
        guard changedTree === tree else { return }
        var retries: [DiskChange] = []
        changedTree.write { root in
            for listing in listings {
                if case .retry(let change) = TreeRefresher.apply(listing, to: root) { retries.append(change) }
            }
        }
        if retries.isEmpty {
            appliedEventID = max(appliedEventID, eventID)
        } else {
            pendingChanges += retries
        }
        cacheIsStale = true
        keepExploringValid()
        objectWillChange.send()
        treeDidChange()
        if !pendingChanges.isEmpty {
            applyPendingChanges()
        } else {
            finishCatchingUp()
            if Date().timeIntervalSince(lastCacheSave) > 10 * 60 { saveCache() }
        }
    }

    private func finishCatchingUp() {
        guard historyCaughtUp, isCatchingUp, pendingChanges.isEmpty, !isApplyingChanges else { return }
        isCatchingUp = false
        if listsWaitForTree {
            listsWaitForTree = false
            loadCatalog()
            loadApps()
        }
        if cacheIsStale { saveCache() }
    }

    /// The folder on screen may have been deleted. Show the nearest folder left.
    private func keepExploringValid() {
        guard let tree, let current = exploring else { return }
        if tree.root.node(at: current.path) === current { return }
        var path = current.path
        while path != tree.root.path, path != "/" {
            path = (path as NSString).deletingLastPathComponent
            if let node = tree.root.node(at: path) {
                exploring = node
                return
            }
        }
        exploring = tree.root
    }

    /// Takes removed items out of the tree straight away, rather than waiting
    /// a couple of seconds for macOS to report them.
    private func forgetRemoved(_ paths: [String]) {
        guard let tree, !paths.isEmpty else { return }
        var changed = false
        tree.write { root in
            for path in paths {
                var st = stat()
                guard lstat(path, &st) != 0 else { continue }
                guard let node = root.node(at: displayPath(path)), node !== root else { continue }
                node.detach()
                changed = true
            }
        }
        guard changed else { return }
        cacheIsStale = true
        keepExploringValid()
        objectWillChange.send()
        treeDidChange()
    }

    // MARK: - Exploring

    func explore(_ node: FileNode?) {
        guard let node, node !== exploring else { return }
        let deeper = node.path.split(separator: "/").count >= (exploring?.path.split(separator: "/").count ?? 0)
        exploreEdge = deeper ? .trailing : .leading
        withAnimation(.smooth(duration: 0.3)) { exploring = node }
    }

    func showInExplorer(_ node: FileNode) {
        exploreEdge = .trailing
        exploring = node.isDirectory ? node : node.parent
        screen = .explore
    }

    // MARK: - Lists

    /// - Parameter fromDisk: Measure every folder again instead of using the scan.
    func loadCatalog(fromDisk: Bool = false) {
        catalogGeneration += 1
        let generation = catalogGeneration
        isLoadingCatalog = true
        var input = CatalogBuilder.Input(env: env, safety: safety)
        input.tree = fromDisk ? nil : tree
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
        let tree = tree
        Task.detached(priority: .utility) { [weak self] in
            let found = AppInventory.installedApps(env: env, tree: tree)
            await self?.finishApps(found)
        }
    }

    private func finishApps(_ found: [InstalledApp]) {
        apps = found
        isLoadingApps = false
    }

    // MARK: - Figures

    private func recomputeSegments() {
        guard let volume else {
            segments = []
            return
        }
        let updated = StorageBreakdown.segments(volume: volume, root: root, env: env)
        if updated != segments { segments = updated }
    }

    private func recomputeTotals() {
        var safe: Int64 = 0
        var review: Int64 = 0
        for item in catalog {
            let size = item.reclaimable(running: running)
            if item.tier == .safe { safe += size } else { review += size }
        }
        if safe != safeReclaimable { safeReclaimable = safe }
        if review != reviewReclaimable { reviewReclaimable = review }
        recomputeSelection()
    }

    private func recomputeSelection() {
        let total = catalog.filter { selectedItems.contains($0.id) }.reduce(0) { $0 + $1.reclaimable(running: running) }
        if total != selectedTotal { selectedTotal = total }
    }

    var hiddenBytes: Int64 { segments.first { $0.kind == .hidden }?.size ?? 0 }
    var safeItems: [CleanupItem] { catalog.filter { $0.tier == .safe } }
    var totalReclaimable: Int64 { safeReclaimable + reviewReclaimable }

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
            await self?.finishClean(report, items: items, entries: entries)
        }
    }

    private func finishClean(_ report: CleanReport, items: [CleanupItem], entries: [String: [CatalogEntry]]) {
        busyItems.subtract(items.map(\.id))
        show(report)
        if items.contains(where: { if case .command = $0.action { return true } else { return false } }) {
            CatalogBuilder.forgetHomebrewEstimate()
        }
        let touched = items.flatMap { (entries[$0.id] ?? $0.entries).map(\.path) }
        refreshAfterChange(removed: touched)
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

    /// No rescan: removed paths leave the tree now, and macOS reports anything
    /// else that changed, which updates the tree in the background.
    private func refreshAfterChange(removed paths: [String] = []) {
        refreshStatus()
        forgetRemoved(paths)
        loadCatalog()
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
        show(report)
        refreshAfterChange(removed: [path])
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
        let name = (record.original as NSString).lastPathComponent
        present(Toast(message: "Moved \(name) to the Trash (\(formatBytes(size))). It's still using space until you empty the Trash.", undo: [record]))
        refreshAfterChange(removed: [record.original])
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
                await self?.finishPermanentUninstall(app, leftovers: leftovers, report: report)
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

    private func finishPermanentUninstall(_ app: InstalledApp, leftovers: [AppLeftover], report: CleanReport) {
        if report.wasCancelled && report.removed == 0 { return }
        let isGone = !FileManager.default.fileExists(atPath: app.path)
        let message = isGone ? "Uninstalled \(app.name) and freed \(formatBytes(report.bytes))." : "Couldn't uninstall \(app.name)."
        present(Toast(message: message, failures: report.failures))
        refreshAfterChange(removed: [app.path] + leftovers.map(\.path))
        loadApps()
    }

    private func finishUninstall(_ app: InstalledApp, records: [TrashRecord], failures: [CleanFailure]) {
        let message = records.contains { $0.original == app.path }
            ? "Moved \(app.name) to the Trash. Empty the Trash to get the space back."
            : "Couldn't uninstall \(app.name)."
        present(Toast(message: message, undo: records, failures: failures))
        refreshAfterChange(removed: records.map(\.original))
        loadApps()
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
