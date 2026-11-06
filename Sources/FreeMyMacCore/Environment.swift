import Foundation

/// Where the app operates. In normal use this is the real home folder and the
/// whole Data volume. With `FREEMYMAC_HOME` set, everything (scanning, cleaning,
/// the Trash) stays inside that folder, so the UI can be exercised on throwaway
/// files without touching anything real.
public struct FreeMyMacEnv: Sendable {
    public let home: String
    public let isFixture: Bool

    public static let dataVolume = "/System/Volumes/Data"

    public init(home: String, isFixture: Bool) {
        self.home = canonicalDirectory(home)
        self.isFixture = isFixture
    }

    public static func current() -> FreeMyMacEnv {
        if let fixture = ProcessInfo.processInfo.environment["FREEMYMAC_HOME"], !fixture.isEmpty {
            return FreeMyMacEnv(home: fixture, isFixture: true)
        }
        return FreeMyMacEnv(home: NSHomeDirectory(), isFixture: false)
    }

    public var scanRoot: String { isFixture ? home : Self.dataVolume }
    public var trashPath: String { home + "/.Trash" }
    public var logPath: String { home + "/Library/Logs/FreeMyMac/activity.log" }

    public var applicationFolders: [String] {
        isFixture ? [home + "/Applications"] : ["/Applications", home + "/Applications"]
    }

    public func inHome(_ relative: String) -> String { home + "/" + relative }
}

/// The Data volume's paths are visible both as `/System/Volumes/Data/Users/x`
/// and, through firmlinks, as `/Users/x`. The app only ever shows the short form.
public func displayPath(_ path: String) -> String {
    let prefix = FreeMyMacEnv.dataVolume
    if path == prefix { return "/" }
    if path.hasPrefix(prefix + "/") { return String(path.dropFirst(prefix.count)) }
    return path
}

func canonicalDirectory(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

public func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}
