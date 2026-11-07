import Foundation

public struct RunningApp: Sendable, Equatable {
    public let name: String
    public let bundleID: String

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }
}

public struct CatalogEntry: Identifiable, Sendable, Equatable {
    public let path: String
    public let name: String
    public let size: Int64
    /// Folder or bundle name used to tell whether the owning app is open.
    public let owner: String?
    public var id: String { path }
}

public struct CleanupItem: Identifiable, Sendable {
    public enum Tier: Sendable {
        /// Rebuilds itself. Removed outright, since the Trash wouldn't free the space.
        case safe
        /// Might matter to you. Moved to the Trash so it can be put back.
        case review
        /// Needs an administrator password.
        case admin
    }

    public enum Action: Sendable, Equatable {
        case removePermanently
        case moveToTrash
        case emptyTrash
        case removeAsAdmin
        case command(executable: String, arguments: [String])
    }

    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String
    public let tier: Tier
    public let action: Action
    public var entries: [CatalogEntry]
    /// For items with no paths to add up, such as `brew cleanup`.
    public var estimatedSize: Int64 = 0

    public func available(running: [RunningApp]) -> [CatalogEntry] {
        entries.filter { CatalogBuilder.runningOwner(of: $0, running: running) == nil }
    }

    public func reclaimable(running: [RunningApp]) -> Int64 {
        estimatedSize + available(running: running).reduce(0) { $0 + $1.size }
    }

    public var totalSize: Int64 { estimatedSize + entries.reduce(0) { $0 + $1.size } }
}

public enum CatalogBuilder {
    public struct Input: Sendable {
        public var env: FreeMyMacEnv
        public var safety: SafetyGuard
        public var now = Date()
        public var staleDays = 30
        public var oldDownloadDays = 90
        /// The current scan. Sizes come from it instead of reading each folder
        /// again. Anything it doesn't hold is measured on disk.
        public var tree: SharedTree?

        public init(env: FreeMyMacEnv, safety: SafetyGuard) {
            self.env = env
            self.safety = safety
        }
    }

    /// Cache folders that aren't really disposable, or that have their own row.
    private static let cacheExclusions: Set<String> = [
        "google", "bravesoftware", "firefox", "microsoft edge", "com.operasoftware.opera",
        "company.thebrowser.browser", "homebrew", "pip", "yarn", "cocoapods", "go-build",
        "geoservices", "cloudkit", "familycircle", "ms-playwright", "freemymac", "com.pavitra.freemymac",
    ]

    private static let aliases: [String: [String]] = [
        "google chrome": ["com.google.chrome"],
        "brave browser": ["com.brave.browser"],
        "firefox": ["org.mozilla.firefox"],
        "microsoft edge": ["com.microsoft.edgemac"],
    ]

    public static func runningOwner(of entry: CatalogEntry, running: [RunningApp]) -> String? {
        guard let owner = entry.owner?.lowercased(), !owner.isEmpty else { return nil }
        for app in running {
            let name = app.name.lowercased()
            let bundle = app.bundleID.lowercased()
            if owner == name || owner == bundle { return app.name }
            if name.count >= 4, owner.contains(name) { return app.name }
            if aliases[owner]?.contains(bundle) == true { return app.name }
            if owner.hasPrefix(bundle + ".") { return app.name }
        }
        return nil
    }

    public static func build(_ input: Input) -> [CleanupItem] {
        var items: [CleanupItem] = []
        items += safeItems(input)
        if let brew = homebrewItem(input) { items.append(brew) }
        items += reviewItems(input)
        if !input.env.isFixture { items += adminItems(input) }
        return dedupe(items).filter { !$0.entries.isEmpty || $0.estimatedSize > 0 || $0.action == .emptyTrash }
    }

    // MARK: - Safe

    private static func safeItems(_ input: Input) -> [CleanupItem] {
        let env = input.env
        var items: [CleanupItem] = []

        let caches = children(of: env.inHome("Library/Caches")).filter { path in
            let name = (path as NSString).lastPathComponent.lowercased()
            return !name.hasPrefix("com.apple.") && !cacheExclusions.contains(name)
        }
        items.append(item(input, id: "app-caches", title: "App caches",
                          detail: "Temporary files apps keep to load faster. They rebuild as you use each app. Apps that are open are skipped.",
                          symbol: "square.stack.3d.up", tier: .safe, action: .removePermanently,
                          paths: caches, owner: { ($0 as NSString).lastPathComponent }))

        let browsers: [(String, String)] = [
            ("Library/Caches/Google/Chrome", "Google Chrome"),
            ("Library/Application Support/Google/Chrome/Default/Code Cache", "Google Chrome"),
            ("Library/Application Support/Google/Chrome/Default/GPUCache", "Google Chrome"),
            ("Library/Caches/BraveSoftware/Brave-Browser", "Brave Browser"),
            ("Library/Application Support/BraveSoftware/Brave-Browser/Default/Code Cache", "Brave Browser"),
            ("Library/Caches/Firefox", "Firefox"),
            ("Library/Caches/Microsoft Edge", "Microsoft Edge"),
            ("Library/Caches/com.operasoftware.Opera", "Opera"),
            ("Library/Caches/company.thebrowser.Browser", "Arc"),
        ]
        let browserOwners = Dictionary(browsers.map { (env.inHome($0.0), $0.1) }, uniquingKeysWith: { first, _ in first })
        items.append(item(input, id: "browser-caches", title: "Browser caches",
                          detail: "Saved copies of web pages and images. Logins, history, and bookmarks aren't touched. Open browsers are skipped.",
                          symbol: "globe", tier: .safe, action: .removePermanently,
                          paths: browsers.map { env.inHome($0.0) }.filter(isRealDirectory),
                          owner: { browserOwners[$0] },
                          label: { browserOwners[$0] ?? ($0 as NSString).lastPathComponent }))

        items.append(item(input, id: "electron-caches", title: "Desktop app web caches",
                          detail: "Apps built on web technology, like Slack or VS Code, keep a browser cache of their own. Open apps are skipped.",
                          symbol: "macwindow", tier: .safe, action: .removePermanently,
                          paths: electronCaches(env), owner: ownerFromApplicationSupport(env),
                          label: { path in
                              let parts = path.components(separatedBy: "/")
                              return parts.suffix(2).joined(separator: " – ")
                          }))

        let developer = [
            "npm cache": [".npm/_cacache", ".npm/_npx", ".npm/_logs"],
            "pnpm store": ["Library/pnpm/store"],
            "Yarn cache": ["Library/Caches/Yarn"],
            "Bun cache": [".bun/install/cache"],
            "pip cache": ["Library/Caches/pip"],
            "uv cache": [".cache/uv"],
            "Gradle caches": [".gradle/caches"],
            "Go module cache": ["go/pkg/mod"],
            "Go build cache": ["Library/Caches/go-build"],
            "CocoaPods cache": ["Library/Caches/CocoaPods"],
            "Xcode build data": ["Library/Developer/Xcode/DerivedData"],
            "Cargo download cache": [".cargo/registry/cache"],
        ]
        var developerLabels: [String: String] = [:]
        var developerPaths: [String] = []
        for (label, relatives) in developer {
            for relative in relatives {
                let path = env.inHome(relative)
                guard isRealDirectory(path) else { continue }
                developerPaths.append(path)
                developerLabels[path] = relatives.count > 1 ? "\(label) (\((relative as NSString).lastPathComponent))" : label
            }
        }
        let labels = developerLabels
        items.append(item(input, id: "developer-caches", title: "Developer tool caches",
                          detail: "Downloaded packages and build output. Your next install or build fetches what it needs, and may run slower once.",
                          symbol: "hammer", tier: .safe, action: .removePermanently,
                          paths: developerPaths.sorted(), owner: { _ in nil },
                          label: { labels[$0] ?? ($0 as NSString).lastPathComponent }))

        let logs = children(of: env.inHome("Library/Logs")).filter { ($0 as NSString).lastPathComponent != "FreeMyMac" }
        items.append(item(input, id: "logs", title: "App logs",
                          detail: "Diagnostic text files apps write as they run. Only useful when troubleshooting.",
                          symbol: "doc.text", tier: .safe, action: .removePermanently,
                          paths: logs, owner: { _ in nil }))
        return items
    }

    // MARK: - Homebrew

    /// `brew cleanup --dry-run` takes seconds, so its answer is kept for a while.
    private static let brewLock = NSLock()
    nonisolated(unsafe) private static var brewEstimate: (value: Int64, at: Date)?

    /// Call after running `brew cleanup`, so the next catalog asks Homebrew again.
    public static func forgetHomebrewEstimate() {
        brewLock.withLock { brewEstimate = nil }
    }

    private static func homebrewItem(_ input: Input) -> CleanupItem? {
        guard !input.env.isFixture else { return nil }
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) else { return nil }
        let arguments = ["cleanup", "-s", "--prune=all"]
        let estimate: Int64
        if let cached = brewLock.withLock({ brewEstimate }), input.now.timeIntervalSince(cached.at) < 30 * 60 {
            estimate = cached.value
        } else {
            guard let output = CommandRunner.run(brew, arguments + ["--dry-run"]) else { return nil }
            estimate = parseBrewEstimate(output)
            brewLock.withLock { brewEstimate = (estimate, input.now) }
        }
        guard estimate > 0 else { return nil }
        var result = CleanupItem(id: "homebrew", title: "Old Homebrew versions",
                                 detail: "Outdated package versions and downloads. Runs `brew cleanup`, so current packages keep working.",
                                 symbol: "shippingbox", tier: .safe,
                                 action: .command(executable: brew, arguments: arguments), entries: [])
        result.estimatedSize = estimate
        return result
    }

    public static func parseBrewEstimate(_ output: String) -> Int64 {
        let pattern = #"free approximately ([0-9.]+)\s*(B|KB|MB|GB|TB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let numberRange = Range(match.range(at: 1), in: output),
              let unitRange = Range(match.range(at: 2), in: output),
              let number = Double(output[numberRange]) else { return 0 }
        let multipliers: [Substring: Double] = ["B": 1, "KB": 1_024, "MB": 1_048_576, "GB": 1_073_741_824, "TB": 1_099_511_627_776]
        return Int64(number * (multipliers[output[unitRange]] ?? 0))
    }

    // MARK: - Review

    private static func reviewItems(_ input: Input) -> [CleanupItem] {
        let env = input.env
        var items: [CleanupItem] = []

        var trash = item(input, id: "trash", title: "Trash",
                         detail: "Files you've already deleted still use space until the Trash is emptied. This is permanent.",
                         symbol: "trash", tier: .review, action: .emptyTrash,
                         paths: children(of: env.trashPath), owner: { _ in nil },
                         guardPaths: false)
        trash.entries.sort { $0.size > $1.size }
        items.append(trash)

        let downloads = children(of: env.inHome("Downloads"))
        let installerTypes: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
        let installers = downloads.filter { installerTypes.contains(($0 as NSString).pathExtension.lowercased()) }
        items.append(item(input, id: "installers", title: "Installers in Downloads",
                          detail: "Disk images and packages. Once an app is installed, you don't need its installer.",
                          symbol: "externaldrive.badge.checkmark", tier: .review, action: .moveToTrash,
                          paths: installers, owner: { _ in nil }))

        let cutoff = input.now.addingTimeInterval(-Double(input.oldDownloadDays) * 86_400)
        let oldDownloads = downloads.filter { path in
            !installerTypes.contains((path as NSString).pathExtension.lowercased())
                && (lastActivity(of: path) ?? input.now) < cutoff
        }
        items.append(item(input, id: "old-downloads", title: "Old downloads",
                          detail: "Files in Downloads with no activity for \(input.oldDownloadDays) days or more.",
                          symbol: "clock.arrow.circlepath", tier: .review, action: .moveToTrash,
                          paths: oldDownloads, owner: { _ in nil }))

        items.append(item(input, id: "project-deps", title: "Dependencies in idle projects",
                          detail: "node_modules, virtual environments, and build output in projects untouched for \(input.staleDays) days. Reinstall them when you return to the project.",
                          symbol: "folder.badge.gearshape", tier: .review, action: .moveToTrash,
                          paths: staleDependencies(input), owner: { _ in nil },
                          label: { path in
                              let parts = path.components(separatedBy: "/")
                              return parts.suffix(2).joined(separator: "/")
                          }))

        let managedExclusions: Set<String> = ["uv"]
        let toolCaches = children(of: env.inHome(".cache")).filter { !managedExclusions.contains(($0 as NSString).lastPathComponent) }
        items.append(item(input, id: "tool-caches", title: "AI models and tool downloads",
                          detail: "Contents of ~/.cache, such as downloaded models. Tools fetch them again when needed, which can take a while.",
                          symbol: "brain", tier: .review, action: .moveToTrash,
                          paths: toolCaches, owner: { _ in nil }))

        items.append(item(input, id: "ios-backups", title: "iPhone and iPad backups",
                          detail: "Local device backups. Delete only if the device backs up somewhere else, like iCloud.",
                          symbol: "iphone", tier: .review, action: .moveToTrash,
                          paths: children(of: env.inHome("Library/Application Support/MobileSync/Backup")), owner: { _ in nil }))

        let xcode = ["Library/Developer/Xcode/Archives", "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport"]
            .flatMap { children(of: env.inHome($0)) }
        items.append(item(input, id: "xcode", title: "Xcode archives and device support",
                          detail: "Archived app builds and debug symbols for devices. Archives can't be rebuilt exactly, so check before emptying the Trash.",
                          symbol: "hammer.circle", tier: .review, action: .moveToTrash,
                          paths: xcode, owner: { _ in nil }))
        return items
    }

    private static func adminItems(_ input: Input) -> [CleanupItem] {
        let systemCaches = children(of: "/Library/Caches").filter { !($0 as NSString).lastPathComponent.hasPrefix("com.apple.") }
        let reports = children(of: "/Library/Logs/DiagnosticReports")
        return [item(input, id: "system-caches", title: "System-wide caches and crash reports",
                     detail: "Files shared by every user on this Mac. macOS asks for your password before they're removed.",
                     symbol: "lock.shield", tier: .admin, action: .removeAsAdmin,
                     paths: systemCaches + reports, owner: { _ in nil })]
    }

    // MARK: - Finding things

    private static func electronCaches(_ env: FreeMyMacEnv) -> [String] {
        let names = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "ShaderCache"]
        var found: [String] = []
        for app in children(of: env.inHome("Library/Application Support")) {
            let appName = (app as NSString).lastPathComponent.lowercased()
            if appName.hasPrefix("com.apple") || ["google", "bravesoftware"].contains(appName) { continue }
            // "Local State" is what marks a folder as Chromium's. A folder named
            // "Cache" alone isn't enough to assume its contents are disposable.
            guard FileManager.default.fileExists(atPath: app + "/Local State")
                    || FileManager.default.fileExists(atPath: app + "/Code Cache") else { continue }
            for name in names {
                let candidate = app + "/" + name
                if isRealDirectory(candidate) { found.append(candidate) }
            }
        }
        return found
    }

    private static func ownerFromApplicationSupport(_ env: FreeMyMacEnv) -> @Sendable (String) -> String? {
        let base = env.inHome("Library/Application Support") + "/"
        return { path in
            guard path.hasPrefix(base) else { return nil }
            return path.dropFirst(base.count).split(separator: "/").first.map(String.init)
        }
    }

    private static func staleDependencies(_ input: Input) -> [String] {
        let env = input.env
        let cutoff = input.now.addingTimeInterval(-Double(input.staleDays) * 86_400)
        let skipTop: Set<String> = ["library", "applications", "music", "pictures", "movies", "public", "orbstack"]
        var found: [String] = []
        var homeStat = stat()
        guard lstat(env.home, &homeStat) == 0 else { return [] }

        func isDependencyFolder(_ name: String, in parent: String) -> Bool {
            let fm = FileManager.default
            switch name {
            case "node_modules", ".next", ".turbo", "Pods":
                return true
            case ".venv", "venv":
                return fm.fileExists(atPath: "\(parent)/\(name)/pyvenv.cfg")
            case "target":
                return fm.fileExists(atPath: "\(parent)/Cargo.toml")
            default:
                return false
            }
        }

        func visit(_ directory: String, depth: Int) {
            guard depth <= 7 else { return }
            for path in children(of: directory) {
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_dev == homeStat.st_dev else { continue }
                let name = (path as NSString).lastPathComponent
                if isDependencyFolder(name, in: directory) {
                    if projectLastTouched(directory, excluding: name) < cutoff { found.append(path) }
                    continue
                }
                if name.hasPrefix(".") || name.hasSuffix(".app") { continue }
                visit(path, depth: depth + 1)
            }
        }

        // With a scan to hand, its folders are walked in memory instead of on disk.
        // It holds every folder of 1 MiB or more, which is every one worth listing.
        if let tree = input.tree, let tops = tree.folders(in: env.home) {
            func visitTree(_ directory: String, depth: Int) {
                guard depth <= 7 else { return }
                for path in tree.folders(in: directory) ?? [] {
                    let name = (path as NSString).lastPathComponent
                    if isDependencyFolder(name, in: directory) {
                        if projectLastTouched(directory, excluding: name) < cutoff { found.append(path) }
                        continue
                    }
                    if name.hasPrefix(".") || name.hasSuffix(".app") { continue }
                    visitTree(path, depth: depth + 1)
                }
            }
            for top in tops {
                let name = (top as NSString).lastPathComponent
                guard !name.hasPrefix("."), !skipTop.contains(name.lowercased()) else { continue }
                visitTree(top, depth: 1)
            }
            return found
        }

        for top in children(of: env.home) {
            let name = (top as NSString).lastPathComponent
            var st = stat()
            guard !name.hasPrefix("."), !skipTop.contains(name.lowercased()),
                  lstat(top, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_dev == homeStat.st_dev else { continue }
            visit(top, depth: 1)
        }
        return found
    }

    private static func projectLastTouched(_ project: String, excluding dependencyFolder: String) -> Date {
        var newest = Date.distantPast
        for path in children(of: project) where (path as NSString).lastPathComponent != dependencyFolder {
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if modified > newest { newest = modified }
        }
        return newest
    }

    private static func lastActivity(of path: String) -> Date? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey])
        return [values?.contentModificationDate, values?.addedToDirectoryDate].compactMap { $0 }.max()
    }

    private static func children(of directory: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0 != ".DS_Store" && $0 != ".localized" }.map { directory + "/" + $0 }
    }

    /// False for a symlink, even one pointing at a directory: a "cache" that
    /// links elsewhere might point at something that isn't a cache at all.
    static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: - Assembly

    private static func item(_ input: Input, id: String, title: String, detail: String, symbol: String,
                             tier: CleanupItem.Tier, action: CleanupItem.Action, paths: [String],
                             owner: @escaping @Sendable (String) -> String?,
                             label: @escaping @Sendable (String) -> String = { ($0 as NSString).lastPathComponent },
                             guardPaths: Bool = true) -> CleanupItem {
        let allowed = paths.filter { path in
            // The Trash's contents are checked again when it's emptied.
            !guardPaths || input.safety.check(path).isAllowed
        }
        var sized = [CatalogEntry?](repeating: nil, count: allowed.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: allowed.count) { index in
            let path = allowed[index]
            let size = input.tree?.size(of: path) ?? DiskScanner.measure(path)
            let entry = CatalogEntry(path: path, name: label(path), size: size, owner: owner(path))
            lock.withLock { sized[index] = entry }
        }
        let entries = sized.compactMap { $0 }.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        return CleanupItem(id: id, title: title, detail: detail, symbol: symbol, tier: tier, action: action, entries: entries)
    }

    /// A path listed under two rows would be counted twice and inflate the
    /// promised total, so the first row to claim a path keeps it.
    private static func dedupe(_ items: [CleanupItem]) -> [CleanupItem] {
        var seen = Set<String>()
        return items.map { original in
            var item = original
            item.entries = item.entries.filter { seen.insert($0.path).inserted }
            return item
        }
    }
}

public enum CommandRunner {
    /// Runs a tool with no shell involved, so nothing in the arguments is interpreted.
    public static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
