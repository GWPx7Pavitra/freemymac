import Foundation
import CoreServices

public struct InstalledApp: Identifiable, Sendable {
    public let path: String
    public let name: String
    public let bundleID: String
    public let size: Int64
    public let lastUsed: Date?
    public var id: String { path }
}

public struct AppLeftover: Identifiable, Sendable, Hashable {
    public let path: String
    public let size: Int64
    /// Documents and settings you might want if you reinstall, rather than
    /// disposable caches. These start unticked in the uninstall sheet.
    public let isUserData: Bool
    public var id: String { path }

    public var label: String {
        (path as NSString).deletingLastPathComponent.components(separatedBy: "/Library/").last ?? path
    }
}

public enum AppInventory {
    public static func installedApps(env: FreeMyMacEnv, tree: SharedTree? = nil) -> [InstalledApp] {
        var bundles: [String] = []
        func collect(_ folder: String, descend: Bool) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
            for name in names {
                let path = folder + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
                if name.hasSuffix(".app") {
                    bundles.append(path)
                } else if descend, !name.hasPrefix(".") {
                    collect(path, descend: false)
                }
            }
        }
        env.applicationFolders.forEach { collect($0, descend: true) }

        var apps = [InstalledApp?](repeating: nil, count: bundles.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: bundles.count) { index in
            let path = bundles[index]
            let bundle = Bundle(path: path)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let app = InstalledApp(path: path, name: name, bundleID: bundle?.bundleIdentifier ?? "",
                                   size: tree?.size(of: path) ?? DiskScanner.measure(path), lastUsed: lastUsed(path))
            lock.withLock { apps[index] = app }
        }
        return apps.compactMap { $0 }.sorted { $0.size > $1.size }
    }

    /// Only exact matches on the app's bundle ID or name count, so uninstalling
    /// "Notes Pro" can't sweep up anything belonging to another app.
    public static func leftovers(for app: InstalledApp, env: FreeMyMacEnv, safety: SafetyGuard) -> [AppLeftover] {
        var candidates: [(String, Bool)] = []
        let id = app.bundleID
        if !id.isEmpty {
            candidates += [
                ("Library/Caches/\(id)", false),
                ("Library/HTTPStorages/\(id)", false),
                ("Library/WebKit/\(id)", false),
                ("Library/Saved Application State/\(id).savedState", false),
                ("Library/Preferences/\(id).plist", true),
                ("Library/Containers/\(id)", true),
                ("Library/Application Support/\(id)", true),
            ]
        }
        candidates += [
            ("Library/Caches/\(app.name)", false),
            ("Library/Logs/\(app.name)", false),
            ("Library/Application Support/\(app.name)", true),
        ]

        var seen = Set<String>()
        return candidates.compactMap { relative, isUserData in
            let path = env.inHome(relative)
            guard seen.insert(path.lowercased()).inserted,
                  FileManager.default.fileExists(atPath: path),
                  safety.check(path).isAllowed else { return nil }
            return AppLeftover(path: path, size: DiskScanner.measure(path), isUserData: isUserData)
        }
    }

    private static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
