import Foundation

/// The last check before anything is removed. Every deletion path in the app
/// goes through this, whichever screen asked for it.
///
/// It is default-deny: a path has to sit under an allowed root and clear every
/// protected location. Comparisons are case-insensitive because APFS is, and
/// the parent directory is resolved so a symlinked parent cannot smuggle a
/// protected path past the check. The final component is deliberately not
/// resolved: removing a symlink removes the link, never what it points at.
public struct SafetyGuard: Sendable {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case blocked(String)

        public var isAllowed: Bool { self == .allowed }
        public var reason: String? {
            if case .blocked(let reason) = self { return reason }
            return nil
        }
    }

    private let exact: [String: String]
    private let subtrees: [(path: String, reason: String)]
    private let allowedRoots: [String]

    public init(env: FreeMyMacEnv, ownBundle: String? = nil) {
        let home = env.home

        var exact: [String: String] = [:]
        let folderReason = "This folder is part of macOS's layout. Remove what's inside it instead."
        for path in ["/", "/Applications", "/Library", "/Users", "/private", "/private/var",
                     "/private/tmp", "/private/var/folders", "/opt", "/usr/local", "/Users/Shared",
                     "/Library/Caches", "/Library/Logs", "/Library/Application Support",
                     home, env.trashPath]
            + ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
               "Applications", "Library", "Library/Application Support", "Library/Caches",
               "Library/Containers", "Library/Group Containers", "Library/Preferences",
               "Library/Logs", "Library/Saved Application State", "Library/Developer"]
                .map({ env.inHome($0) }) {
            exact[Self.key(path)] = folderReason
        }

        var subtrees: [(String, String)] = []
        func protect(_ paths: [String], _ reason: String) {
            subtrees += paths.map { (Self.key($0), reason) }
        }
        protect(["/System", "/usr", "/bin", "/sbin", "/dev", "/etc", "/private/etc", "/Volumes",
                 "/private/var/db", "/private/var/vm", "/private/var/root", "/private/var/protected",
                 "/Library/Apple", "/Library/Extensions", "/Library/SystemExtensions",
                 "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools",
                 "/Library/Preferences", "/Library/Security", "/Library/Keychains", "/nix"],
                "macOS needs this to run.")
        protect(["/opt/homebrew", "/usr/local/Cellar"],
                "Homebrew manages this. Use `brew uninstall`, or the Homebrew row in Clean Up.")
        protect([env.inHome("Library/Keychains"), env.inHome("Library/Accounts"),
                 env.inHome(".ssh"), env.inHome(".gnupg"), env.inHome(".aws"), env.inHome(".kube")],
                "This holds your passwords and keys.")
        protect([env.inHome("Library/Mail"), env.inHome("Library/Messages"),
                 env.inHome("Library/Safari"), env.inHome("Library/Calendars"),
                 env.inHome("Library/Photos"), env.inHome("Library/Application Support/AddressBook"),
                 env.inHome("Pictures/Photos Library.photoslibrary"), env.inHome("Music/Music")],
                "This holds personal data. Remove items from inside its own app.")
        protect([env.inHome("Library/Mobile Documents"), env.inHome("Library/CloudStorage")],
                "This is synced. Deleting here deletes it from the cloud and your other devices.")
        if let ownBundle { protect([ownBundle], "FreeMyMac can't delete itself.") }

        self.exact = exact
        self.subtrees = subtrees
        self.allowedRoots = (env.isFixture
            ? [home]
            : [home, "/Applications", "/Library", "/Users/Shared", "/private/tmp"]).map(Self.key)
    }

    public func check(_ rawPath: String) -> Verdict {
        guard let path = Self.canonicalize(rawPath) else {
            return .blocked("This path can't be resolved, so it's being left alone.")
        }
        let p = Self.key(path)

        if let reason = exact[p] { return .blocked(reason) }
        for (protected, reason) in subtrees {
            if p == protected || p.hasPrefix(protected + "/") { return .blocked(reason) }
        }
        let prefix = p + "/"
        if let hit = subtrees.first(where: { $0.path.hasPrefix(prefix) }) {
            return .blocked("This folder contains a protected location. \(hit.reason)")
        }
        if exact.keys.contains(where: { $0.hasPrefix(prefix) }) {
            return .blocked("This folder contains system or personal folders.")
        }
        if path.split(separator: "/").dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) {
            return .blocked("Deleting inside an app breaks it. Uninstall the whole app instead.")
        }
        guard allowedRoots.contains(where: { p.hasPrefix($0 + "/") }) else {
            return .blocked("This is outside the places FreeMyMac is allowed to clean.")
        }
        return .allowed
    }

    private static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func canonicalize(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.contains("\0") else { return nil }
        var stack: [Substring] = []
        for part in displayPath(raw).split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if stack.isEmpty { return nil }
                stack.removeLast()
                continue
            }
            stack.append(part)
        }
        guard let last = stack.popLast() else { return "/" }
        let parent = "/" + stack.joined(separator: "/")
        guard let resolved = realpath(parent, nil) else { return nil }
        defer { free(resolved) }
        let base = String(cString: resolved)
        return (base == "/" ? "" : base) + "/" + last
    }
}
